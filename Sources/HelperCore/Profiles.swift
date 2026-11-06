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

    public var isExpired: Bool { sessionExpires.map { $0 < Date() } ?? false }
}

public struct SwitchResult: Sendable {
    public var notes: [String] = []
    public var warnings: [String] = []
    public var loginBackup: URL?
    public var syncBackup: URL?
    public var reopened = false
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
        guard accountId != nil else {
            throw HelperError.message("Claude does not look signed in (no account in config.json). Log in first, then save.")
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

    // MARK: Add another account

    /// Reopen Claude signed out without logging out, so the current login stays valid on the server.
    /// The current login is saved first; the login files are moved into a backup, not deleted.
    public static func prepareFreshLogin(paths: HelperPaths, bundleID: String = ClaudeApp.bundleID,
                                         step: @escaping @Sendable (String) -> Void) async throws -> SwitchResult {
        var result = SwitchResult()
        var quitByUs = false
        if paths.isLiveClaudeDir, ClaudeApp.isRunning(bundleID: bundleID) {
            step("Quitting Claude")
            try await ClaudeApp.quit(bundleID: bundleID)
            quitByUs = true
        }
        do {
            let current = currentAccountId(paths: paths)
            if var cur = profile(forAccount: current, paths: paths) {
                step("Saving the current login (\(cur.name))")
                try writeSnapshot(into: &cur, paths: paths)
                result.notes.append("Saved the current login to \(cur.name).")
            } else if current != nil {
                step("Saving the current login")
                let p = try saveCurrent(name: "Account " + String(current!.prefix(8)), paths: paths)
                result.notes.append("Saved the current login as \(p.name).")
            }
            step("Moving the login files aside")
            let backup = try makeLoginBackupDir(paths: paths, suffix: "add-account")
            result.loginBackup = backup
            let configData = try Data(contentsOf: paths.claudeConfig)
            try fm.copyItem(at: paths.claudeConfig, to: backup.appendingPathComponent("config.json"))
            for name in ["Cookies", "Cookies-journal"] {
                let src = paths.claudeDir.appendingPathComponent(name)
                if fm.fileExists(atPath: src.path) { try fm.moveItem(at: src, to: backup.appendingPathComponent(name)) }
            }
            let stripped = try TopLevelJSON.remove(configData, keys: configKeys)
            let perms = (try? fm.attributesOfItem(atPath: paths.claudeConfig.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
            let tmp = paths.claudeDir.appendingPathComponent(".config.json.claudehelper-tmp")
            try stripped.write(to: tmp)
            try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path)
            guard Darwin.rename(tmp.path, paths.claudeConfig.path) == 0 else {
                throw HelperError.message("Could not update config.json. The previous files are in \(backup.path).")
            }
            result.notes.append("Claude is signed out. Log in to the other account, then save it in Claude Helper.")
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

    // MARK: Switch

    /// Quit Claude, re-save the current login, optionally sync chats, back up the login files,
    /// put the chosen profile's login in place and reopen Claude.
    public static func switchTo(_ target: LoginProfile, syncFolderIds: [String]?, paths: HelperPaths,
                                bundleID: String = ClaudeApp.bundleID,
                                step: @escaping @Sendable (String) -> Void) async throws -> SwitchResult {
        var result = SwitchResult()
        let d = dir(target, paths)
        guard fm.fileExists(atPath: d.appendingPathComponent("Cookies").path),
              let authData = try? Data(contentsOf: d.appendingPathComponent("auth.json")),
              let auth = try JSONSerialization.jsonObject(with: authData) as? [String: Any] else {
            throw HelperError.message("The saved login for \(target.name) is incomplete. Log in to that account once and save it again.")
        }
        if target.isExpired {
            throw HelperError.message("The saved login for \(target.name) expired on \(target.sessionExpires!.formatted(date: .abbreviated, time: .shortened)). Log in to that account in Claude once and save it again.")
        }

        var quitByUs = false
        if paths.isLiveClaudeDir, ClaudeApp.isRunning(bundleID: bundleID) {
            step("Quitting Claude")
            try await ClaudeApp.quit(bundleID: bundleID)
            quitByUs = true
        }
        do {
            // 1. Keep the current account's refreshed tokens.
            let current = currentAccountId(paths: paths)
            if var cur = profile(forAccount: current, paths: paths) {
                step("Saving the current login (\(cur.name))")
                try writeSnapshot(into: &cur, paths: paths)
                result.notes.append("Saved the current login to \(cur.name).")
            } else if current != nil {
                step("Saving the current login")
                let p = try saveCurrent(name: "Account " + String(current!.prefix(8)), paths: paths)
                result.notes.append("The current account had no saved login, so it was saved as \(p.name).")
            }

            // 2. Session sync between the chosen account folders.
            if let ids = syncFolderIds, ids.count >= 2 {
                step("Syncing chats between account folders")
                let plan = Planner.plan(.sync(folderIds: ids), paths: paths)
                if !plan.problems.isEmpty {
                    result.warnings.append("Chat sync skipped: " + plan.problems.map { $0.path.lastPathComponent + ": " + $0.message }.joined(separator: "; "))
                } else if !plan.changes.isEmpty {
                    let r = try Executor.apply(plan, paths: paths)
                    result.syncBackup = r.backup.dir
                    result.notes.append("Synced chats: \(r.written) written, \(r.moved) moved to the backup.")
                }
            }

            // 3. Back up the login files that are about to change.
            step("Backing up the current login files")
            let backup = try makeLoginBackupDir(paths: paths, suffix: "switch-login")
            for name in ["Cookies", "Cookies-journal", "config.json"] {
                let src = paths.claudeDir.appendingPathComponent(name)
                if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: backup.appendingPathComponent(name)) }
            }
            result.loginBackup = backup

            // 4. Put the chosen login in place.
            step("Restoring the login for \(target.name)")
            let configData = try Data(contentsOf: paths.claudeConfig)
            var sets: [(String, Any)] = []
            var removes: [String] = []
            for k in configKeys {
                if let v = auth[k] { sets.append((k, v)) } else { removes.append(k) }
            }
            var newConfig = try TopLevelJSON.patch(configData, set: sets)
            newConfig = try TopLevelJSON.remove(newConfig, keys: removes)
            let configPerms = (try? fm.attributesOfItem(atPath: paths.claudeConfig.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
            let tmpConfig = paths.claudeDir.appendingPathComponent(".config.json.claudehelper-tmp")
            try newConfig.write(to: tmpConfig)
            try fm.setAttributes([.posixPermissions: configPerms], ofItemAtPath: tmpConfig.path)

            let tmpCookies = paths.claudeDir.appendingPathComponent(".Cookies.claudehelper-tmp")
            try? fm.removeItem(at: tmpCookies)
            try fm.copyItem(at: d.appendingPathComponent("Cookies"), to: tmpCookies)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpCookies.path)
            // A leftover journal could roll the swapped database back, so it goes first.
            let journal = paths.claudeDir.appendingPathComponent("Cookies-journal")
            if fm.fileExists(atPath: journal.path) { try fm.removeItem(at: journal) }
            guard Darwin.rename(tmpCookies.path, cookiesURL(paths).path) == 0,
                  Darwin.rename(tmpConfig.path, paths.claudeConfig.path) == 0 else {
                throw HelperError.message("Could not put the login files in place. The previous ones are in \(backup.path).")
            }
            result.notes.append("Switched to \(target.name).")
        } catch {
            if quitByUs { try? await ClaudeApp.open(bundleID: bundleID) }
            throw error
        }

        if quitByUs {
            step("Reopening Claude")
            try? await ClaudeApp.open(bundleID: bundleID)
            result.reopened = true
            // 5. Did Claude keep the login? It clears it when the saved session is no longer valid.
            step("Checking that Claude accepted the login")
            var accepted = false
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if currentAccountId(paths: paths) == target.accountId, hasSessionCookie(cookiesURL(paths)) { accepted = true }
                if accepted { break }
            }
            if !accepted {
                result.warnings.append("Claude did not keep the saved login for \(target.name). It may have expired: log in to that account once and save it again.")
            }
        }
        step("Done")
        return result
    }
}
