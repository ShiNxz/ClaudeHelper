import Foundation
import SQLite3

/// A saved Claude desktop login. Stored in ClaudeHelper/profiles/<id>/ (folder 0700, files 0600):
///   Cookies       copy of Claude's cookie database (values stay encrypted with Claude's own key)
///   auth.json     the login keys copied from Claude's config.json (encrypted blobs, never shown or logged)
///   profile.json  this metadata
public struct LoginProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var accountId: String?
    public var savedAt: Date
    /// When the claude.ai session cookie expires. Read from the cookie's expiry column, never its value.
    public var sessionExpires: Date?
    /// Set when this saved login is known not to work any more (signed out in Claude, or rejected on switch).
    public var problem: String?

    public var isExpired: Bool { sessionExpires.map { $0 < Date() } ?? false }
    public var needsLogin: Bool { problem != nil || isExpired }
}

public struct SwitchResult: Sendable {
    public var notes: [String] = []
    public var warnings: [String] = []
    public var loginBackup: URL?
    public var syncBackup: URL?
    public var carryBackup: URL?
    public var reopened = false
    /// True when Claude ended up on the target account.
    public var switched = false
}

public enum LoginProfiles {
    /// Keys in config.json that make up the login. Everything else in config.json is left alone.
    public static let configKeys = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"]
    static let fm = FileManager.default

    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func cookiesURL(_ paths: HelperPaths) -> URL { paths.claudeDir.appendingPathComponent("Cookies") }
    static func dir(_ p: LoginProfile, _ paths: HelperPaths) -> URL { paths.profilesDir.appendingPathComponent(p.id, isDirectory: true) }

    public static func list(paths: HelperPaths) -> [LoginProfile] {
        let dirs = (try? fm.contentsOfDirectory(at: paths.profilesDir, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("profile.json")) else { return nil }
            return try? jsonDecoder.decode(LoginProfile.self, from: data)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func currentAccountId(paths: HelperPaths) -> String? { paths.activeAccountId() }

    public static func profile(forAccount id: String?, paths: HelperPaths) -> LoginProfile? {
        guard let id else { return nil }
        return list(paths: paths).first { $0.accountId == id }
    }

    static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let s = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return s.isEmpty ? "account" : String(s.prefix(40))
    }

    // MARK: Save

    /// Save Claude's current login under `name`. Works while Claude runs: the cookie database is copied
    /// with SQLite's online backup, which takes a consistent snapshot.
    @discardableResult
    public static func saveCurrent(name: String, paths: HelperPaths) throws -> LoginProfile {
        try paths.ensureDataDirs()
        let accountId = currentAccountId(paths: paths)
        guard accountId != nil, isSignedIn(paths: paths) else {
            throw HelperError.message("Claude does not look signed in. Log in first, then save.")
        }
        // Re-saving the same account updates its profile instead of creating a second one.
        var profile = profile(forAccount: accountId, paths: paths)
            ?? LoginProfile(id: uniqueId(slug(name), paths: paths), name: name, accountId: accountId, savedAt: Date(), sessionExpires: nil)
        profile.name = name
        try writeSnapshot(into: &profile, paths: paths)
        return profile
    }

    static func uniqueId(_ base: String, paths: HelperPaths) -> String {
        var id = base, n = 2
        while fm.fileExists(atPath: paths.profilesDir.appendingPathComponent(id).path) { id = base + "-\(n)"; n += 1 }
        return id
    }

    static func writeSnapshot(into profile: inout LoginProfile, paths: HelperPaths) throws {
        let d = dir(profile, paths)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)

        let configData = try Data(contentsOf: paths.claudeConfig)
        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw HelperError.message("Claude's config.json is not a JSON object.")
        }
        var auth: [String: Any] = [:]
        for k in configKeys { if let v = config[k] { auth[k] = v } }
        guard auth["oauth:tokenCacheV2"] != nil || auth["oauth:tokenCache"] != nil else {
            throw HelperError.message("No saved login found in Claude's config.json. Log in to Claude first, then save.")
        }
        let tmpCookies = d.appendingPathComponent(".Cookies.tmp")
        try? fm.removeItem(at: tmpCookies)
        try sqliteBackup(from: cookiesURL(paths), to: tmpCookies)
        try writePrivate(try JSONSerialization.data(withJSONObject: auth), to: d.appendingPathComponent("auth.json"))
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpCookies.path)
        if Darwin.rename(tmpCookies.path, d.appendingPathComponent("Cookies").path) != 0 {
            throw HelperError.message("Could not store the cookie snapshot.")
        }
        profile.accountId = auth["lastKnownAccountUuid"] as? String ?? profile.accountId
        profile.savedAt = Date()
        profile.sessionExpires = sessionExpiry(d.appendingPathComponent("Cookies"))
        profile.problem = nil
        try writePrivate(try jsonEncoder.encode(profile), to: d.appendingPathComponent("profile.json"))
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".tmp")
        try data.write(to: tmp)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if Darwin.rename(tmp.path, url.path) != 0 { throw HelperError.message("Could not write \(url.lastPathComponent).") }
    }

    /// Consistent copy of a live SQLite database.
    static func sqliteBackup(from src: URL, to dst: URL) throws {
        var source: OpaquePointer?, dest: OpaquePointer?
        guard sqlite3_open_v2(src.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(source)
            throw HelperError.message("Could not open Claude's cookie database.")
        }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 5000)
        guard sqlite3_open_v2(dst.path, &dest, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(dest)
            throw HelperError.message("Could not create the cookie snapshot.")
        }
        defer { sqlite3_close(dest) }
        guard let b = sqlite3_backup_init(dest, "main", source, "main") else {
            throw HelperError.message("Could not copy the cookie database.")
        }
        var rc = SQLITE_OK
        repeat {
            rc = sqlite3_backup_step(b, -1)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED { sqlite3_sleep(100) }
        } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED
        sqlite3_backup_finish(b)
        guard rc == SQLITE_DONE else { throw HelperError.message("Copying the cookie database failed (\(rc)).") }
    }

    /// Latest expiry of the claude.ai session cookies, or nil when there are none. Reads names and expiry only.
    public static func sessionExpiry(_ cookies: URL) -> Date? {
        guard let db = try? SQLiteDB(path: cookies.path, readOnly: true),
              let s = try? db.prepare("SELECT max(expires_utc) FROM cookies WHERE host_key LIKE '%claude.ai' AND name IN ('sessionKey','sessionKeyV3')"),
              (try? s.step()) == true, !s.isNull(0) else { return nil }
        let micros = s.int64(0)
        guard micros > 0 else { return nil }
        // Chromium time: microseconds since 1601-01-01.
        return Date(timeIntervalSince1970: Double(micros) / 1_000_000 - 11_644_473_600)
    }

    public static func hasSessionCookie(_ cookies: URL) -> Bool {
        guard let db = try? SQLiteDB(path: cookies.path, readOnly: true),
              let s = try? db.prepare("SELECT count(*) FROM cookies WHERE host_key LIKE '%claude.ai' AND name IN ('sessionKey','sessionKeyV3')"),
              (try? s.step()) == true else { return false }
        return s.int64(0) > 0
    }

    public static func renameProfile(_ profile: LoginProfile, to name: String, paths: HelperPaths) throws {
        var p = profile
        p.name = name
        try writePrivate(try jsonEncoder.encode(p), to: dir(p, paths).appendingPathComponent("profile.json"))
    }

    public static func delete(_ profile: LoginProfile, paths: HelperPaths) throws {
        try fm.removeItem(at: dir(profile, paths))
    }

    public static func saveMeta(_ p: LoginProfile, paths: HelperPaths) {
        try? writePrivate(try jsonEncoder.encode(p), to: dir(p, paths).appendingPathComponent("profile.json"))
    }

    // MARK: Signed-in state

    /// True when Claude's files and its log say an account is signed in right now.
    public static func isSignedIn(paths: HelperPaths) -> Bool {
        guard let data = try? Data(contentsOf: paths.claudeConfig),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              config["lastKnownAccountUuid"] is String,
              config["oauth:tokenCacheV2"] != nil || config["oauth:tokenCache"] != nil,
              hasSessionCookie(cookiesURL(paths)) else { return false }
        return ClaudeLog.lastStateIsSignedOut(paths: paths) != true
    }

    /// Saved logins only stay valid while that account is not signed in again by hand (Claude revokes the older
    /// sign-in a minute later), so the signed-in account's copy is refreshed regularly. Safe while Claude runs.
    @discardableResult
    public static func refreshActive(paths: HelperPaths, minInterval: TimeInterval = 300) -> LoginProfile? {
        guard let id = currentAccountId(paths: paths), var p = profile(forAccount: id, paths: paths),
              isSignedIn(paths: paths) else { return nil }
        if p.problem == nil, Date().timeIntervalSince(p.savedAt) < minInterval { return nil }
        // Right after a sign-in Claude is still setting up its tokens; wait for it to settle.
        if let last = ClaudeLog.loginEvents(paths: paths, tailBytes: 1 << 20).last, Date().timeIntervalSince(last.date) < 20 { return nil }
        guard (try? writeSnapshot(into: &p, paths: paths)) != nil else { return nil }
        return p
    }

    /// Save the signed-in account under `name` if it has no saved login yet, once Claude has settled
    /// after the sign-in. Used after Log In and Save, so the user does not have to click anything.
    @discardableResult
    public static func saveNewIfSettled(account: String, name: String, paths: HelperPaths) -> LoginProfile? {
        guard currentAccountId(paths: paths) == account, profile(forAccount: account, paths: paths) == nil,
              isSignedIn(paths: paths) else { return nil }
        if let last = ClaudeLog.loginEvents(paths: paths, tailBytes: 1 << 20).last, Date().timeIntervalSince(last.date) < 20 { return nil }
        return try? saveCurrent(name: name, paths: paths)
    }

    /// Flag saved logins that Claude's log shows were signed out after they were saved.
    public static func updateProblems(paths: HelperPaths) {
        let events = ClaudeLog.loginEvents(paths: paths, tailBytes: 2 << 20)
        guard !events.isEmpty else { return }
        for var p in list(paths: paths) where p.problem == nil {
            guard let acc = p.accountId else { continue }
            let signedOut = events.first { e in
                guard e.date > p.savedAt.addingTimeInterval(1), case .signedOut(let from) = e.kind else { return false }
                return from == acc
            }
            if let e = signedOut {
                p.problem = "Signed out inside Claude on \(e.date.formatted(date: .abbreviated, time: .shortened)), which ended this saved login. Use Log In Again."
                saveMeta(p, paths: paths)
            }
        }
    }

    // MARK: Add another account / log in again

    /// Reopen Claude signed out without logging out, so saved logins stay valid on the server.
    /// The current login is saved first; the login files are moved into a backup, not deleted.
    public static func prepareFreshLogin(paths: HelperPaths, syncFolderIds: [String]? = nil, bundleID: String = ClaudeApp.bundleID,
                                         step: @escaping @Sendable (String) -> Void) async throws -> SwitchResult {
        var result = SwitchResult()
        var quitByUs = false
        if paths.isLiveClaudeDir, ClaudeApp.isRunning(bundleID: bundleID) {
            step("Quitting Claude")
            try await ClaudeApp.quit(bundleID: bundleID)
            quitByUs = true
        }
        do {
            _ = try saveOutgoing(paths: paths, result: &result, step: step)
            try mergeChats(syncFolderIds, paths: paths, result: &result, step: step)
            step("Moving the login files aside")
            let backup = try makeLoginBackupDir(paths: paths, suffix: "add-account")
            result.loginBackup = backup
            let configData = try Data(contentsOf: paths.claudeConfig)
            try fm.copyItem(at: paths.claudeConfig, to: backup.appendingPathComponent("config.json"))
            for name in ["Cookies", "Cookies-journal"] {
                let src = paths.claudeDir.appendingPathComponent(name)
                if fm.fileExists(atPath: src.path) { try fm.moveItem(at: src, to: backup.appendingPathComponent(name)) }
            }
            try writeConfig(try TopLevelJSON.remove(configData, keys: configKeys), paths: paths)
            AccountHistory.record(nil, paths: paths)
            result.notes.append("Claude is signed out. Log in to the account there. Relay saves it by itself once you are in.")
        } catch {
            if quitByUs { try? await ClaudeApp.open(bundleID: bundleID) }
            throw error
        }
        if quitByUs {
            step("Reopening Claude")
            try? await ClaudeApp.open(bundleID: bundleID)
            result.reopened = true
        }
        step("Done")
        return result
    }

    static let swapSuffixes = ["switch-login", "switch-back", "add-account"]

    /// When the helper swapped Claude's login files, from the names of its login backups.
    public static func loginSwapDates(paths: HelperPaths) -> [Date] {
        let names = (try? fm.contentsOfDirectory(atPath: paths.backupsDir.path)) ?? []
        return names.compactMap { n in
            guard n.count > 17, swapSuffixes.contains(where: { n.dropFirst(18).hasPrefix($0) }) else { return nil }
            return BackupManager.stampFmt.date(from: String(n.prefix(17)))
        }.sorted()
    }

    static func makeLoginBackupDir(paths: HelperPaths, suffix: String) throws -> URL {
        try paths.ensureDataDirs()
        let stamp = BackupManager.stampFmt.string(from: Date())
        var backup = paths.backupsDir.appendingPathComponent(stamp + "-" + suffix, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: backup.path) {
            backup = paths.backupsDir.appendingPathComponent(stamp + "-" + suffix + "-\(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backup.path)
        return backup
    }

    static func writeConfig(_ data: Data, paths: HelperPaths) throws {
        let perms = (try? fm.attributesOfItem(atPath: paths.claudeConfig.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        let tmp = paths.claudeDir.appendingPathComponent(".config.json.claudehelper-tmp")
        try data.write(to: tmp)
        try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path)
        guard Darwin.rename(tmp.path, paths.claudeConfig.path) == 0 else {
            throw HelperError.message("Could not update Claude's config.json.")
        }
    }

    // MARK: Switch

    /// Re-save the account being left, so its refreshed tokens are kept. A signed-out state is never saved.
    static func saveOutgoing(paths: HelperPaths, result: inout SwitchResult, step: (String) -> Void) throws -> LoginProfile? {
        guard let current = currentAccountId(paths: paths) else { return nil }
        guard isSignedIn(paths: paths) else {
            result.notes.append("Claude was signed out, so there was no login to save first.")
            return nil
        }
        if var cur = profile(forAccount: current, paths: paths) {
            step("Saving the current login (\(cur.name))")
            try writeSnapshot(into: &cur, paths: paths)
            return cur
        }
        step("Saving the current login")
        let p = try saveCurrent(name: "Account " + String(current.prefix(8)), paths: paths)
        result.notes.append("The current account had no saved login, so it was saved as \(p.name).")
        return p
    }

    /// Merge chats between the given folders while Claude is closed, so chats made in the account
    /// being left are not stuck there. Problems skip the merge with a warning instead of failing.
    static func mergeChats(_ ids: [String]?, paths: HelperPaths, result: inout SwitchResult, step: (String) -> Void) throws {
        guard let ids, ids.count >= 2 else { return }
        step("Merging chats between accounts")
        let plan = Planner.plan(.sync(folderIds: ids), paths: paths)
        if !plan.problems.isEmpty {
            result.warnings.append("Chat merge skipped: " + plan.problems.map { $0.path.lastPathComponent + ": " + $0.message }.joined(separator: "; "))
        } else if !plan.changes.isEmpty {
            let r = try Executor.apply(plan, paths: paths)
            result.syncBackup = r.backup.dir
            result.notes.append("Merged chats: \(r.written) written, \(r.moved) moved to the backup.")
        }
    }

    /// Bring chats along to the account being switched to (for example the ones just worked on), while Claude
    /// is closed. Problems skip it with a warning instead of failing the switch.
    static func carryChats(_ intent: WriteIntent?, paths: HelperPaths, result: inout SwitchResult, step: (String) -> Void) throws {
        guard let intent else { return }
        let plan = Planner.plan(intent, paths: paths)
        if !plan.problems.isEmpty {
            result.warnings.append("Chats were not brought along: " + plan.problems.map { $0.path.lastPathComponent + ": " + $0.message }.joined(separator: "; "))
        } else if !plan.changes.isEmpty {
            step("Bringing chats along")
            let r = try Executor.apply(plan, paths: paths)
            result.carryBackup = r.backup.dir
            let chats = Set(plan.changes.filter { $0.kind == .add || $0.kind == .update }.map(\.target.lastPathComponent)).count
            result.notes.append("Brought \(chats) chat\(chats == 1 ? "" : "s") along.")
        }
    }

    /// Put a profile's login files in place, after backing up the current ones. Claude must not be running.
    static func restoreFiles(of profile: LoginProfile, paths: HelperPaths, backupSuffix: String) throws -> URL {
        let d = dir(profile, paths)
        guard fm.fileExists(atPath: d.appendingPathComponent("Cookies").path),
              let authData = try? Data(contentsOf: d.appendingPathComponent("auth.json")),
              let auth = try JSONSerialization.jsonObject(with: authData) as? [String: Any] else {
            throw HelperError.message("The saved login for \(profile.name) is incomplete. Use Log In Again for it.")
        }
        let backup = try makeLoginBackupDir(paths: paths, suffix: backupSuffix)
        for name in ["Cookies", "Cookies-journal", "config.json"] {
            let src = paths.claudeDir.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: backup.appendingPathComponent(name)) }
        }
        var sets: [(String, Any)] = []
        var removes: [String] = []
        for k in configKeys {
            if let v = auth[k] { sets.append((k, v)) } else { removes.append(k) }
        }
        let configData = try Data(contentsOf: paths.claudeConfig)
        let newConfig = try TopLevelJSON.remove(try TopLevelJSON.patch(configData, set: sets), keys: removes)

        let tmpCookies = paths.claudeDir.appendingPathComponent(".Cookies.claudehelper-tmp")
        try? fm.removeItem(at: tmpCookies)
        try fm.copyItem(at: d.appendingPathComponent("Cookies"), to: tmpCookies)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpCookies.path)
        // A leftover journal could roll the swapped database back, so it goes first.
        let journal = paths.claudeDir.appendingPathComponent("Cookies-journal")
        if fm.fileExists(atPath: journal.path) { try fm.removeItem(at: journal) }
        guard Darwin.rename(tmpCookies.path, cookiesURL(paths).path) == 0 else {
            throw HelperError.message("Could not put the cookie database in place. The previous files are in \(backup.path).")
        }
        try writeConfig(newConfig, paths: paths)
        // Claude does not always log a sign-in when it opens on a swapped login, so note it here.
        AccountHistory.record(profile.accountId, at: Date().addingTimeInterval(0.001), paths: paths)
        return backup
    }

    public enum Acceptance: Sendable { case accepted, rejected }

    /// After Claude reopens with a restored login. Rejected when Claude's log shows a sign-out that is not
    /// followed by this account signing in; accepted when the log shows this account signed in, or when
    /// enough time passes without a sign-out and the login files still point to this account.
    public static func waitForAcceptance(of target: LoginProfile, since: Date, paths: HelperPaths,
                                         timeout: Int = 40, quietSeconds: Int = 15) async -> Acceptance {
        var signOutSeenAt: Int?
        for second in 1...timeout {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let events = ClaudeLog.loginEvents(paths: paths, since: since, tailBytes: 1 << 20)
            if let lastOut = events.lastIndex(where: \.isSignOut) {
                let signedInAfter = events[(lastOut + 1)...].contains { e in
                    if case .signedIn(let a, _) = e.kind { return a == target.accountId } else { return false }
                }
                if signedInAfter { return .accepted }
                signOutSeenAt = signOutSeenAt ?? second
                if second - signOutSeenAt! >= 5 { return .rejected }
                continue
            }
            if events.contains(where: { e in if case .signedIn(let a, _) = e.kind { return a == target.accountId } else { return false } }) {
                return .accepted
            }
            if second >= quietSeconds, currentAccountId(paths: paths) == target.accountId, hasSessionCookie(cookiesURL(paths)) {
                return .accepted
            }
        }
        return signOutSeenAt == nil && currentAccountId(paths: paths) == target.accountId ? .accepted : .rejected
    }

    /// Quit Claude, re-save the current login, optionally sync chats, back up and swap the login files,
    /// reopen Claude and check it accepted the login. If Claude rejects it, the previous login is put back.
    /// `verifier` replaces the check against the live Claude (used by the self-test).
    public static func switchTo(_ target: LoginProfile, syncFolderIds: [String]?, carry: WriteIntent? = nil, paths: HelperPaths,
                                bundleID: String = ClaudeApp.bundleID,
                                verifier: ((LoginProfile) async -> Acceptance)? = nil,
                                step: @escaping @Sendable (String) -> Void) async throws -> SwitchResult {
        var result = SwitchResult()
        if target.isExpired {
            throw HelperError.message("The saved login for \(target.name) expired on \(target.sessionExpires!.formatted(date: .abbreviated, time: .shortened)). Use Log In Again for it.")
        }
        if let problem = target.problem {
            throw HelperError.message(target.name + ": " + problem)
        }
        let live = paths.isLiveClaudeDir
        var quitByUs = false
        if live, ClaudeApp.isRunning(bundleID: bundleID) {
            step("Quitting Claude")
            try await ClaudeApp.quit(bundleID: bundleID)
            quitByUs = true
        }
        var outgoing: LoginProfile?
        do {
            outgoing = try saveOutgoing(paths: paths, result: &result, step: step)

            try mergeChats(syncFolderIds, paths: paths, result: &result, step: step)
            try carryChats(carry, paths: paths, result: &result, step: step)

            step("Restoring the login for \(target.name)")
            result.loginBackup = try restoreFiles(of: target, paths: paths, backupSuffix: "switch-login")
        } catch {
            if quitByUs { try? await ClaudeApp.open(bundleID: bundleID) }
            throw error
        }

        let openedAt = Date().addingTimeInterval(-1)
        if live {
            step("Reopening Claude")
            try? await ClaudeApp.open(bundleID: bundleID)
            result.reopened = true
        }
        let verdict: Acceptance
        if let verifier {
            verdict = await verifier(target)
        } else if live {
            step("Checking that Claude accepted the login")
            verdict = await waitForAcceptance(of: target, since: openedAt, paths: paths)
        } else {
            verdict = .accepted
        }

        if verdict == .accepted {
            result.switched = true
            result.notes.append("Switched to \(target.name).")
            step("Done")
            return result
        }

        // Rejected: mark the profile and go back to the account we came from.
        var broken = target
        broken.problem = "Claude did not accept this saved login on \(Date().formatted(date: .abbreviated, time: .shortened)). It was most likely ended by Log out in Claude, or by signing in to this account again by hand. Use Log In Again."
        saveMeta(broken, paths: paths)
        guard let back = outgoing else {
            result.warnings.append("Claude did not accept the saved login for \(target.name) and is now signed out. Use Log In Again for \(target.name), or log in to any account in Claude.")
            step("Done")
            return result
        }
        step("Claude did not accept it. Switching back to \(back.name)")
        if live, ClaudeApp.isRunning(bundleID: bundleID) { try await ClaudeApp.quit(bundleID: bundleID) }
        _ = try restoreFiles(of: back, paths: paths, backupSuffix: "switch-back")
        if live {
            try? await ClaudeApp.open(bundleID: bundleID)
        }
        result.warnings.append("Claude did not accept the saved login for \(target.name), so you are back on \(back.name). That saved login was most likely ended by Log out in Claude or by signing in to it again by hand. Use Log In Again for \(target.name) once, and switching works from then on.")
        step("Done")
        return result
    }
}
