import AppKit
import HelperCore
import Observation
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case search = "Search"
    case accounts = "Accounts"
    case sync = "Sync chats"
    case backups = "Backups"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .sessions: return "list.bullet.rectangle"
        case .search: return "magnifyingglass"
        case .accounts: return "person.2"
        case .sync: return "arrow.triangle.2.circlepath"
        case .backups: return "archivebox"
        }
    }
}

struct PlanSheet: Identifiable {
    enum State {
        case preview
        case applying([String])
        case done(ApplyResult, reopened: Bool, steps: [String])
        case failed(String, steps: [String])
    }
    let id = UUID()
    let intent: WriteIntent
    var plan: WritePlan
    var state: State = .preview
    var note: String?
}

/// Main-queue blocks run in order, so a late index progress update can never land after the final one.
func onMainQueue(_ f: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated { f() } }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

@MainActor
@Observable
final class AppModel {
    let paths = HelperPaths.standard()

    var section: AppSection = .sessions
    var searchQuery = ""
    var searchSelection: Int64?
    /// Only used by the --snapshot self-check.
    var autoSelectFirstResult = false
    var snapshot: Snapshot?
    var claudeRunning = false
    var banner: String?

    /// Queued edits from the sessions browser, keyed by folderId|sessionId.
    var pending: [String: SessionEdit] = [:]
    var planSheet: PlanSheet?

    // Search index
    var indexProgress = IndexProgress()
    var indexFiles = 0
    var indexMessages = 0
    var indexLastRun: String?
    var indexSettings: IndexSettings {
        didSet { saveSettings() }
    }
    private var cancelFlag: CancelFlag?
    private var timer: Timer?

    /// Account id -> email, learned from transcripts by the indexer.
    var accountEmails: [String: String] = [:]

    // Login profiles
    var profiles: [LoginProfile] = []
    var switchSteps: [String] = []
    var switching = false
    var switchSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(switchSyncEnabled, forKey: "switch.sync") }
    }

    // Sync
    /// Accounts that should share chats.
    var syncAccounts: Set<String> {
        didSet { UserDefaults.standard.set(Array(syncAccounts), forKey: "syncAccounts") }
    }
    /// nil: merge all picked accounts. Otherwise copy from this account to the other picked ones.
    var syncSource: String? {
        didSet { UserDefaults.standard.set(syncSource, forKey: "syncSource") }
    }
    var nicknames: [String: String] {
        didSet { UserDefaults.standard.set(nicknames, forKey: "folderNicknames") }
    }

    init() {
        let d = UserDefaults.standard
        indexSettings = IndexSettings(includeToolOutput: d.bool(forKey: "index.tools"), includeSubagents: d.bool(forKey: "index.subagents"))
        // Older versions stored picked folders ("<account>/<org>"); keep their accounts.
        let oldFolders = d.stringArray(forKey: "syncSelection") ?? []
        syncAccounts = Set(d.stringArray(forKey: "syncAccounts") ?? oldFolders.compactMap { $0.split(separator: "/").first.map(String.init) })
        syncSource = d.string(forKey: "syncSource")
        nicknames = d.dictionary(forKey: "folderNicknames") as? [String: String] ?? [:]
        switchSyncEnabled = d.bool(forKey: "switch.sync")
        refresh()
        loadIndexStats()
        startIndexing()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.startIndexing() }
        }
        // The --snapshot self-check only looks; it must not save logins.
        if SelfCheck.outputDir == nil {
            maintainProfiles()
            profileTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.maintainProfiles() }
            }
        }
    }

    private var profileTimer: Timer?

    /// Keep the signed-in account's saved login current and flag saved logins that stopped working.
    /// Runs off the main thread; skipped while a switch is in progress.
    func maintainProfiles() {
        guard !switching, !profiles.isEmpty || awaitingLogin != nil else { return }
        let paths = self.paths
        let awaiting = awaitingLogin
        let newName = awaiting.flatMap { accountEmails[$0] } ?? awaiting.map { "Account " + String($0.prefix(8)) }
        DispatchQueue.global(qos: .utility).async {
            var refreshed = LoginProfiles.refreshActive(paths: paths)
            if refreshed == nil, let awaiting, let newName {
                refreshed = LoginProfiles.saveNewIfSettled(account: awaiting, name: newName, paths: paths)
            }
            LoginProfiles.updateProblems(paths: paths)
            let list = LoginProfiles.list(paths: paths)
            onMainQueue {
                if self.switching { return }
                self.profiles = list
                if let r = refreshed, self.awaitingLogin == r.accountId || self.awaitingLogin == r.id {
                    self.awaitingLogin = nil
                    self.banner = "Saved the login for \(self.email(forAccount: r.accountId) ?? r.name). You can switch to it from the menu bar now."
                }
            }
        }
    }

    /// Profile (or account) the user was asked to log in to again; cleared once that login is saved.
    var awaitingLogin: String?

    private func saveSettings() {
        UserDefaults.standard.set(indexSettings.includeToolOutput, forKey: "index.tools")
        UserDefaults.standard.set(indexSettings.includeSubagents, forKey: "index.subagents")
    }

    // MARK: Sessions

    func refresh() {
        snapshot = SessionScanner.scan(paths: paths)
        profiles = LoginProfiles.list(paths: paths)
        claudeRunning = ClaudeApp.isRunning()
        // Drop pending edits whose session vanished.
        if let snap = snapshot {
            let ids = Set(snap.allSessions.map(\.id))
            pending = pending.filter { ids.contains($0.key) }
        }
    }

    func email(forAccount id: String?) -> String? { id.flatMap { accountEmails[$0] } }

    func label(_ folder: SessionFolder) -> String {
        var s: String
        if let nick = nicknames[folder.id], !nick.isEmpty {
            s = nick
        } else if let email = accountEmails[folder.accountId] {
            // An account can have several org folders; name the org only when it is needed to tell them apart.
            let siblings = snapshot?.folders.filter { $0.folder.accountId == folder.accountId && !$0.folder.isBackupCopy }.count ?? 1
            s = email
            if siblings > 1 || folder.isBackupCopy { s += " / org " + String(folder.orgId.prefix(8)) }
            if folder.isBackupCopy { s += " (backup copy)" }
        } else {
            s = folder.shortLabel
        }
        if folder.accountId == snapshot?.activeAccountId, !folder.isBackupCopy { s += " (signed in)" }
        return s
    }

    func record(for key: String) -> SessionRecord? {
        snapshot?.allSessions.first { $0.id == key }
    }

    /// Merge an edit into the queue. Edits that end up matching the file are dropped.
    func queue(_ records: [SessionRecord], title: ((SessionRecord) -> String?)? = nil, archived: Bool? = nil, starred: Bool? = nil) {
        for r in records {
            var e = pending[r.id] ?? SessionEdit(folderId: r.folder.id, sessionId: r.sessionId)
            if let title, let t = title(r) { e.title = t }
            if let archived {
                e.isArchived = archived
                if archived, (e.isStarred ?? r.isStarred) { e.isStarred = false }
            }
            if let starred {
                e.isStarred = starred
                if starred, (e.isArchived ?? r.isArchived) { e.isArchived = false }
            }
            if e.title == r.title { e.title = nil }
            if e.isArchived == r.isArchived && r.isArchived == r.inArchivedIndex { e.isArchived = nil }
            if e.isStarred == r.isStarred { e.isStarred = nil }
            pending[r.id] = e.isEmpty ? nil : e
        }
    }

    func discardPending() { pending = [:] }

    func previewPending() {
        let intent = WriteIntent.edits(Array(pending.values))
        planSheet = PlanSheet(intent: intent, plan: Planner.plan(intent, paths: paths))
    }

    func open(_ r: SessionRecord) {
        guard let url = r.openURL else { return }
        if let active = snapshot?.activeAccountId, r.folder.accountId != active {
            banner = "\"\(r.title)\" is in \(label(r.folder)), but Claude is signed in to another account. It may not open. Account sync can copy it over."
        } else if r.isArchived {
            banner = "\"\(r.title)\" is archived. It opens, but it stays out of the sidebar until you restore it."
        } else {
            banner = nil
        }
        NSWorkspace.shared.open(url)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Sync and backups

    /// The chat lists (folders) of an account that hold chats. An account has one per organization it used.
    /// Falls back to all its folders when none has chats yet.
    func folderIds(forAccount id: String) -> [String] {
        let live = (snapshot?.folders ?? []).filter { $0.folder.accountId == id && !$0.folder.isBackupCopy }
        let used = live.filter { !$0.sessions.isEmpty || !$0.deletedMarkers.isEmpty }
        return (used.isEmpty ? live : used).map(\.folder.id)
    }

    /// Distinct chats across an account's folders.
    func chatCount(forAccount id: String) -> Int {
        let ids = Set(folderIds(forAccount: id))
        var chats = Set<String>()
        for f in snapshot?.folders ?? [] where ids.contains(f.folder.id) { chats.formUnion(f.sessions.map(\.sessionId)) }
        return chats.count
    }

    /// Picked accounts in display order.
    var pickedAccounts: [String] { accountEntries.map(\.id).filter { syncAccounts.contains($0) } }

    /// All folders of the picked accounts (what a merge, and the sync on switch, works on).
    var syncFolderIds: [String] { pickedAccounts.flatMap { folderIds(forAccount: $0) } }

    var syncIntent: WriteIntent? {
        let picked = pickedAccounts
        if let src = syncSource, picked.contains(src) {
            let targets = picked.filter { $0 != src }.flatMap { folderIds(forAccount: $0) }
            guard !targets.isEmpty else { return nil }
            return .copy(sourceFolderIds: folderIds(forAccount: src), targetFolderIds: targets)
        }
        let folders = syncFolderIds
        return folders.count >= 2 ? .sync(folderIds: folders) : nil
    }

    func previewSync(folderIds: [String]? = nil) {
        guard let intent = folderIds.map({ WriteIntent.sync(folderIds: $0) }) ?? syncIntent else { return }
        planSheet = PlanSheet(intent: intent, plan: Planner.plan(intent, paths: paths))
    }

    func previewRestore(_ b: BackupInfo) {
        let intent = WriteIntent.restoreBackup(b)
        planSheet = PlanSheet(intent: intent, plan: Planner.plan(intent, paths: paths))
    }

    func backups() -> [BackupInfo] { BackupManager.list(paths: paths) }

    // MARK: Apply

    func applyPlan() {
        guard var sheet = planSheet, sheet.plan.canApply else { return }
        sheet.state = .applying([])
        planSheet = sheet
        let sheetId = sheet.id
        let intent = sheet.intent, keys = sheet.plan.keys, paths = self.paths
        Task { @MainActor in
            do {
                let outcome = try await ApplyCoordinator.run(intent: intent, previewKeys: keys, paths: paths) { step in
                    Task { @MainActor in self.addStep(step, sheetId: sheetId) }
                }
                await Task.yield()
                switch outcome {
                case .applied(let result, let reopened):
                    if case .edits = intent { self.pending = [:] }
                    self.update(sheetId) { $0.state = .done(result, reopened: reopened, steps: self.steps(of: $0)) }
                case .planChanged(let newPlan):
                    self.update(sheetId) {
                        $0.plan = newPlan
                        $0.state = .preview
                        $0.note = "Claude changed some files while quitting, so the plan changed. Claude is still closed. Review the new list and apply again."
                    }
                }
            } catch {
                self.update(sheetId) { $0.state = .failed(error.localizedDescription, steps: self.steps(of: $0)) }
            }
            self.refresh()
        }
    }

    private func steps(of sheet: PlanSheet) -> [String] {
        if case .applying(let s) = sheet.state { return s }
        return []
    }

    private func addStep(_ step: String, sheetId: UUID) {
        update(sheetId) { s in
            if case .applying(var steps) = s.state {
                steps.append(step)
                s.state = .applying(steps)
            }
        }
    }

    private func update(_ id: UUID, _ f: (inout PlanSheet) -> Void) {
        guard var s = planSheet, s.id == id else { return }
        f(&s)
        planSheet = s
    }

    func reopenClaude() {
        Task { try? await ClaudeApp.open(); self.refresh() }
    }

    // MARK: Login profiles

    struct AccountEntry: Identifiable {
        let id: String          // account id
        let email: String?
        let profile: LoginProfile?
        let isActive: Bool
        var title: String { email ?? profile?.name ?? "Account " + String(id.prefix(8)) }
        /// The saved name, shown only when it says something the email does not.
        var nickname: String? { profile.flatMap { $0.name == email ? nil : $0.name } }
    }

    /// Every account seen on this Mac: account folders, saved logins and the signed-in account.
    var accountEntries: [AccountEntry] {
        var ids: [String] = []
        func add(_ id: String?) { if let id, !ids.contains(id) { ids.append(id) } }
        add(snapshot?.activeAccountId)
        for f in snapshot?.folders ?? [] where !f.folder.isBackupCopy { add(f.folder.accountId) }
        for p in profiles { add(p.accountId) }
        let active = snapshot?.activeAccountId
        return ids.map { id in
            AccountEntry(id: id, email: accountEmails[id], profile: profiles.first { $0.accountId == id }, isActive: id == active)
        }.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// One action per account: switch to it, or log in to it (saving it by itself afterwards).
    func activate(_ e: AccountEntry) {
        if let p = e.profile, !p.needsLogin { confirmAndSwitch(p) } else { confirmAndLogIn(accountId: e.id, who: e.title) }
    }

    var activeProfile: LoginProfile? { profiles.first { $0.accountId != nil && $0.accountId == snapshot?.activeAccountId } }

    func saveCurrentLogin(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let p = try LoginProfiles.saveCurrent(name: trimmed.isEmpty ? "Account" : trimmed, paths: paths)
            banner = "Saved the current Claude login as \(p.name)."
        } catch {
            banner = error.localizedDescription
        }
        refresh()
    }

    func renameProfile(_ p: LoginProfile, to name: String) {
        try? LoginProfiles.renameProfile(p, to: name, paths: paths)
        refresh()
    }

    func deleteProfile(_ p: LoginProfile) {
        let alert = NSAlert()
        alert.messageText = "Forget the saved login for \(email(forAccount: p.accountId) ?? p.name)?"
        alert.informativeText = "Only the helper's saved copy is removed. Claude, the account and your chats are not touched. You can log in and save it again later."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? LoginProfiles.delete(p, paths: paths)
        refresh()
    }

    /// Ask first: switching quits Claude, which stops running Code sessions.
    func confirmAndSwitch(_ p: LoginProfile) {
        guard !switching else { return }
        if p.needsLogin { confirmAndLogInAgain(p); return }
        let alert = NSAlert()
        alert.messageText = "Switch Claude to \(p.name)?"
        var info = "Claude will quit, which stops any running Code sessions, then reopen signed in as \(p.name). The current login is saved first and backed up."
        if switchSyncEnabled, syncFolderIds.count >= 2 { info += " Chats are merged between the accounts picked in Sync chats first." }
        alert.informativeText = info
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switchTo(p)
    }

    /// Reopen Claude signed out (without logging out) so another account can be logged in and saved.
    func confirmAndAddAccount() {
        guard !switching else { return }
        let alert = NSAlert()
        alert.messageText = "Add another account?"
        alert.informativeText = "The current login is saved first. Claude will quit, which stops any running Code sessions, and reopen signed out. Log in to the other account there, then click Save This Login here.\n\nDo not use Log out inside Claude for this: logging out can end that login on the server, and then its saved copy stops working."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switching = true
        switchSteps = []
        let paths = self.paths
        Task { @MainActor in
            do {
                let r = try await LoginProfiles.prepareFreshLogin(paths: paths, syncFolderIds: self.switchSyncEnabled ? self.syncFolderIds : nil) { step in
                    onMainQueue { self.switchSteps.append(step) }
                }
                self.banner = r.notes.joined(separator: " ")
            } catch {
                self.banner = error.localizedDescription
            }
            self.switching = false
            self.refresh()
        }
    }

    func confirmAndLogInAgain(_ p: LoginProfile) {
        confirmAndLogIn(accountId: p.accountId ?? p.id, who: email(forAccount: p.accountId) ?? p.name)
    }

    /// Reopen Claude signed out (without logging anything out) so the user can log in to `who`;
    /// the helper saves that login by itself once they are in.
    func confirmAndLogIn(accountId: String, who: String) {
        guard !switching else { return }
        let alert = NSAlert()
        alert.messageText = "Log in to \(who)?"
        var info = "The current login is saved first. Claude quits, which stops any running Code sessions, and reopens signed out. Log in to \(who) there. The helper saves that login by itself within a minute, and from then on you can switch to it from the menu bar."
        if switchSyncEnabled, syncFolderIds.count >= 2 { info += " Chats are merged between the accounts picked in Sync chats first." }
        alert.informativeText = info
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        awaitingLogin = accountId
        switching = true
        switchSteps = []
        let paths = self.paths
        Task { @MainActor in
            do {
                _ = try await LoginProfiles.prepareFreshLogin(paths: paths, syncFolderIds: self.switchSyncEnabled ? self.syncFolderIds : nil) { step in
                    onMainQueue { self.switchSteps.append(step) }
                }
                self.banner = "Claude is signed out. Log in to \(who) there. The helper saves it by itself once you are in."
            } catch {
                self.banner = error.localizedDescription
            }
            self.switching = false
            self.refresh()
        }
    }

    func switchTo(_ p: LoginProfile) {
        switching = true
        switchSteps = []
        let paths = self.paths
        let sync: [String]? = switchSyncEnabled ? syncFolderIds : nil
        Task { @MainActor in
            var message: String
            var warnings: [String] = []
            do {
                let r = try await LoginProfiles.switchTo(p, syncFolderIds: sync, paths: paths) { step in
                    onMainQueue { self.switchSteps.append(step) }
                }
                warnings = r.warnings
                message = r.notes.joined(separator: " ")
            } catch {
                message = error.localizedDescription
                warnings = [message]
            }
            self.switching = false
            self.refresh()
            self.banner = message
            if !warnings.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Could not switch to \(p.name)"
                alert.informativeText = warnings.joined(separator: "\n\n")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    // MARK: Index

    func loadIndexStats() {
        accountEmails = TranscriptIndex.accountEmails(paths: paths)
        guard let idx = try? TranscriptIndex(paths: paths, settings: indexSettings) else { return }
        let s = idx.stats()
        indexFiles = s.files
        indexMessages = s.messages
        indexLastRun = s.lastRun
    }

    private var indexWorkerActive = false
    private var restartIndexing = false

    /// Runs one incremental pass in the background. `force` queues another pass if one is running
    /// (used when the index options change, so the old pass stops and a rebuild follows).
    func startIndexing(force: Bool = false) {
        if indexWorkerActive {
            if force { restartIndexing = true }
            return
        }
        indexWorkerActive = true
        let flag = CancelFlag()
        cancelFlag = flag
        indexProgress = IndexProgress()
        indexProgress.phase = .discovering
        let paths = self.paths, settings = self.indexSettings
        DispatchQueue.global(qos: .utility).async {
            do {
                let idx = try TranscriptIndex(paths: paths, settings: settings)
                try idx.update(progress: { p in onMainQueue { self.indexProgress = p } }, cancelled: { flag.isSet })
                let s = idx.stats()
                let emails = TranscriptIndex.accountEmails(paths: paths)
                onMainQueue {
                    self.accountEmails = emails
                    self.indexFiles = s.files
                    self.indexMessages = s.messages
                    self.indexLastRun = s.lastRun
                }
            } catch {
                let msg = error.localizedDescription
                onMainQueue { self.indexProgress.phase = .failed(msg) }
            }
            onMainQueue {
                self.indexWorkerActive = false
                if self.restartIndexing {
                    self.restartIndexing = false
                    self.startIndexing()
                }
            }
        }
    }

    /// Back up every live account folder right now, without changing anything.
    func backupNow() -> String {
        let folders = (snapshot?.folders ?? []).map(\.folder).filter { !$0.isBackupCopy }
        do {
            let b = try BackupManager.create(folders: folders, reason: "manual", title: "Manual backup", changes: [], paths: paths)
            var info = b
            info.applied = true
            try? BackupManager.save(info)
            return "Backed up \(b.files.count) files to \(b.dir.lastPathComponent)"
        } catch {
            return "Backup failed: " + error.localizedDescription
        }
    }

    func cancelIndexing() { cancelFlag?.set() }

    var indexStatusText: String {
        let p = indexProgress
        switch p.phase {
        case .discovering: return "Looking for transcripts"
        case .indexing:
            return String(format: "Indexing %d of %d files, %.0f%%", p.filesDone, p.filesTotal, p.fraction * 100)
        case .failed(let m): return "Index failed: " + m
        case .cancelled: return "Indexing stopped. \(indexFiles) files, \(indexMessages) messages indexed"
        case .idle, .done:
            return "\(indexFiles) chats, \(indexMessages) messages indexed"
        }
    }
}
