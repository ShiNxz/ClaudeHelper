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
    /// Open this chat in Claude once the plan is applied (Pull and Open).
    var openAfter: SessionRecord?
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
    let updater = Updater()

    var section: AppSection = .sessions
    var searchQuery = ""
    var searchSelection: Int64?
    /// Only used by the --snapshot self-check.
    var autoSelectFirstResult = false
    var snapshot: Snapshot?
    var claudeRunning = false
    /// Short message at the bottom of the window, gone after a few seconds.
    var toast: Toast?

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

    // Usage and auto-switch
    /// Latest plan usage per account id, from Claude's own usage history.
    var usage: [String: AccountUsage] = [:]
    /// True when the signed-in account's usage was sampled after it signed in (not left over from before).
    var activeUsageIsCurrent = false
    var autoSwitchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoSwitchEnabled, forKey: "autoSwitch.enabled")
            if autoSwitchEnabled { Notifier.shared.requestPermission() }
            autoSwitchStatus = nil
            autoSwitchWaitingSince = nil
            if autoSwitchEnabled { refreshUsage() }
        }
    }
    /// Percent of the 5-hour or weekly limit at which auto-switch moves on.
    var autoSwitchThreshold: Int {
        didSet { UserDefaults.standard.set(autoSwitchThreshold, forKey: "autoSwitch.threshold") }
    }
    var autoSwitchWaitForIdle: Bool {
        didSet { UserDefaults.standard.set(autoSwitchWaitForIdle, forKey: "autoSwitch.waitForIdle") }
    }
    /// What auto-switch is waiting for, shown in Accounts and the menu.
    var autoSwitchStatus: String?
    private var autoSwitchWaitingSince: Date?
    private var lastAutoSwitchAt: Date?
    private var noCandidateNoticeAt: Date?

    init() {
        let d = UserDefaults.standard
        indexSettings = IndexSettings(includeToolOutput: d.bool(forKey: "index.tools"), includeSubagents: d.bool(forKey: "index.subagents"))
        // Older versions stored picked folders ("<account>/<org>"); keep their accounts.
        let oldFolders = d.stringArray(forKey: "syncSelection") ?? []
        syncAccounts = Set(d.stringArray(forKey: "syncAccounts") ?? oldFolders.compactMap { $0.split(separator: "/").first.map(String.init) })
        syncSource = d.string(forKey: "syncSource")
        nicknames = d.dictionary(forKey: "folderNicknames") as? [String: String] ?? [:]
        switchSyncEnabled = d.bool(forKey: "switch.sync")
        autoSwitchEnabled = d.bool(forKey: "autoSwitch.enabled")
        let t = d.integer(forKey: "autoSwitch.threshold")
        autoSwitchThreshold = (50...100).contains(t) ? t : 95
        autoSwitchWaitForIdle = d.object(forKey: "autoSwitch.waitForIdle") as? Bool ?? true
        Notifier.shared.setUp()
        updater.model = self
        updater.start()
        refresh()
        loadIndexStats()
        startIndexing()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.startIndexing() }
        }
        // The --snapshot self-check only looks; it must not save logins or switch.
        if SelfCheck.outputDir == nil {
            maintainProfiles()
            refreshUsage()
            profileTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.maintainProfiles()
                    self?.refreshUsage()
                }
            }
        } else {
            usage = PlanUsage.accountUsage(paths: paths)
        }
    }

    private var profileTimer: Timer?

    // MARK: Notices

    /// Tell the user something. Inside the window when it is in front, otherwise as a macOS notification
    /// (or the window toast when notifications are off). `system: true` always tries a notification, for
    /// messages sent while another app comes to the front.
    func notify(_ text: String, title: String? = nil, warning: Bool = false, system: Bool? = nil) {
        let windowInFront = NSApp.isActive && NSApp.keyWindow?.title == AppInfo.name
        if system ?? !windowInFront {
            Notifier.shared.post(title: title ?? AppInfo.name, body: text) { [weak self] in
                self?.showToast(Toast(title: title, text: text, warning: warning))
            }
        } else {
            showToast(Toast(title: title, text: text, warning: warning))
        }
    }

    func showToast(_ t: Toast) {
        toast = t
        let seconds: UInt64 = t.warning ? 10 : 6
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if self.toast?.id == t.id { self.toast = nil }
        }
    }

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
                    self.notify("Saved the login for \(self.email(forAccount: r.accountId) ?? r.name). You can switch to it from the menu bar now.",
                                title: "Login saved")
                }
            }
        }
    }

    // MARK: Usage and auto-switch

    private var usageWorkerActive = false

    /// Read Claude's usage history off the main thread, then let auto-switch look at it.
    func refreshUsage() {
        guard !usageWorkerActive, SelfCheck.outputDir == nil else { return }
        usageWorkerActive = true
        let paths = self.paths
        let threshold = autoSwitchThreshold
        let watchIdle = autoSwitchEnabled && autoSwitchWaitForIdle
        DispatchQueue.global(qos: .utility).async {
            AccountHistory.noteCurrent(paths: paths)
            let events = PlanUsage.timelineEvents(paths: paths)
            let usage = PlanUsage.accountUsage(samples: PlanUsage.readSamples(paths: paths), events: events)
            let active = paths.activeAccountId()
            let activeUsage = active.flatMap { usage[$0] }
            let current = activeUsage.map { PlanUsage.isCurrent($0, events: events) } ?? false
            // When a switch is due, read the chat lists again (the last scan can be hours old) and look for
            // chats of the signed-in account that are mid-turn. Terminal sessions are not stopped by a switch.
            var fresh: Snapshot?
            var busy: Set<String> = []
            if current, let u = activeUsage, AutoSwitch.reason(u, threshold: threshold) != nil {
                let snap = SessionScanner.scan(paths: paths)
                fresh = snap
                if watchIdle {
                    let mine = Set(snap.folders.filter { $0.folder.accountId == active }.flatMap { $0.sessions.compactMap(\.cliSessionId) })
                    busy = ChatActivity.busyTranscripts(paths: paths, among: mine)
                }
            }
            onMainQueue {
                self.usageWorkerActive = false
                self.usage = usage
                self.activeUsageIsCurrent = current
                if let fresh { self.apply(fresh) }
                self.evaluateAutoSwitch(busyChats: busy)
            }
        }
    }

    /// Recent chats of an account, newest first, one per chat.
    func recentChats(ofAccount id: String, within seconds: TimeInterval) -> [SessionRecord] {
        let cutoff = Date().addingTimeInterval(-seconds)
        var best: [String: SessionRecord] = [:]
        for f in snapshot?.folders ?? [] where f.folder.accountId == id && !f.folder.isBackupCopy {
            for s in f.sessions {
                let when = max(s.lastActivityAt ?? .distantPast, s.fileMTime)
                guard when >= cutoff else { continue }
                if let cur = best[s.sessionId], max(cur.lastActivityAt ?? .distantPast, cur.fileMTime) >= when { continue }
                best[s.sessionId] = s
            }
        }
        return best.values.sorted { max($0.lastActivityAt ?? .distantPast, $0.fileMTime) > max($1.lastActivityAt ?? .distantPast, $1.fileMTime) }
    }

    /// The account auto-switch would move to now, if any.
    var autoSwitchPick: AccountEntry? {
        let candidates = accountEntries.filter { !$0.isActive }.compactMap { e -> AutoSwitch.Candidate? in
            guard let p = e.profile, !p.needsLogin else { return nil }
            return AutoSwitch.Candidate(accountId: e.id, usage: usage[e.id])
        }
        guard let pick = AutoSwitch.pick(candidates, threshold: autoSwitchThreshold) else { return nil }
        return accountEntries.first { $0.id == pick.accountId }
    }

    /// Called after each usage read. Switches when the signed-in account is at the threshold, Claude is running,
    /// nothing else is going on, and (if asked) no chat of the signed-in account is still working.
    func evaluateAutoSwitch(busyChats: Set<String>, now: Date = Date()) {
        guard autoSwitchEnabled else { autoSwitchStatus = nil; return }
        claudeRunning = ClaudeApp.isRunning()
        guard !switching, claudeRunning,
              let active = paths.activeAccountId(), let u = usage[active], activeUsageIsCurrent,
              let why = AutoSwitch.reason(u, threshold: autoSwitchThreshold, now: now) else {
            autoSwitchStatus = nil
            autoSwitchWaitingSince = nil
            return
        }
        let from = accountEntries.first { $0.id == active }?.title ?? "The signed-in account"
        if planSheet != nil {
            autoSwitchStatus = "\(from): \(why). Auto-switch waits while a preview is open here."
            return
        }
        if let last = lastAutoSwitchAt, now.timeIntervalSince(last) < 600 {
            autoSwitchStatus = "\(from): \(why). Waiting a few minutes after the last automatic switch before trying again."
            return
        }
        guard let target = autoSwitchPick, let profile = target.profile else {
            autoSwitchStatus = "\(from): \(why), and every other saved account is at \(autoSwitchThreshold)% or more. Staying on \(from)."
            if noCandidateNoticeAt.map({ now.timeIntervalSince($0) > 3 * 3600 }) ?? true {
                noCandidateNoticeAt = now
                notify("\(from): \(why). Every other saved account is at \(autoSwitchThreshold)% or more too, so Claude stays on \(from).",
                       title: "No account to switch to", warning: true)
            }
            return
        }
        if autoSwitchWaitForIdle {
            let running = busyChats
            if !running.isEmpty {
                if autoSwitchWaitingSince == nil {
                    autoSwitchWaitingSince = now
                    notify("\(from): \(why). Switching to \(target.title) once \(running.count == 1 ? "the running chat finishes" : "\(running.count) running chats finish").",
                           title: "Auto-switch is waiting")
                }
                autoSwitchStatus = "\(from): \(why). Will switch to \(target.title) once \(running.count == 1 ? "1 running chat finishes" : "\(running.count) running chats finish")."
                return
            }
        }
        autoSwitchStatus = nil
        autoSwitchWaitingSince = nil
        lastAutoSwitchAt = now
        // Chats worked on in the last day come along to the new account, and the newest one opens again.
        let recent = recentChats(ofAccount: active, within: 86400)
        let targets = folderIds(forAccount: target.id)
        let carry: WriteIntent? = recent.isEmpty || targets.isEmpty ? nil
            : .pull(items: recent.map { PullItem(folderId: $0.folder.id, sessionId: $0.sessionId) }, targetFolderIds: targets)
        switchTo(profile, carry: carry, openAfter: targets.isEmpty ? nil : recent.first,
                 auto: "\(from) was switched away from because \(why).")
    }

    /// Profile (or account) the user was asked to log in to again; cleared once that login is saved.
    var awaitingLogin: String?

    private func saveSettings() {
        UserDefaults.standard.set(indexSettings.includeToolOutput, forKey: "index.tools")
        UserDefaults.standard.set(indexSettings.includeSubagents, forKey: "index.subagents")
    }

    // MARK: Sessions

    func refresh() {
        apply(SessionScanner.scan(paths: paths))
        profiles = LoginProfiles.list(paths: paths)
        claudeRunning = ClaudeApp.isRunning()
    }

    func apply(_ snap: Snapshot) {
        snapshot = snap
        // Drop pending edits whose session vanished.
        let ids = Set(snap.allSessions.map(\.id))
        pending = pending.filter { ids.contains($0.key) }
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

    /// Open a chat in Claude. A chat the signed-in account does not have goes through Pull first, because
    /// Claude only opens chats of the account it is signed in to.
    func open(_ r: SessionRecord) {
        if canPull(r) {
            let who = accountEntries.first { $0.isActive }?.title ?? "the signed-in account"
            previewPull([r], openAfter: r,
                        note: "\(quoted(r.title)) is in \(label(r.folder)). Claude is signed in to \(who), so it cannot open it until it is added to \(who).")
            return
        }
        openInClaude(r)
    }

    func openInClaude(_ r: SessionRecord) {
        guard let url = r.openURL else { return }
        if r.isArchived {
            notify("\(quoted(r.title)) is archived. It opens, but stays out of Claude's sidebar until you restore it.", system: true)
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: Pull

    /// Folders (one per organization) the signed-in account keeps its chats in.
    var signedInFolderIds: [String] {
        guard let active = snapshot?.activeAccountId else { return [] }
        return folderIds(forAccount: active)
    }

    /// Chat ids the signed-in account already has.
    var signedInChatIds: Set<String> {
        guard let active = snapshot?.activeAccountId else { return [] }
        return Set((snapshot?.folders ?? []).filter { $0.folder.accountId == active && !$0.folder.isBackupCopy }.flatMap { $0.sessions.map(\.sessionId) })
    }

    /// True for a chat in another account (or a backup copy) that the signed-in account does not have.
    func canPull(_ r: SessionRecord, have: Set<String>? = nil) -> Bool {
        guard let active = snapshot?.activeAccountId, !signedInFolderIds.isEmpty else { return false }
        if r.folder.accountId == active && !r.folder.isBackupCopy { return false }
        return !(have ?? signedInChatIds).contains(r.sessionId)
    }

    func previewPull(_ records: [SessionRecord], openAfter: SessionRecord? = nil, note: String? = nil) {
        let have = signedInChatIds
        let items = records.filter { canPull($0, have: have) }.map { PullItem(folderId: $0.folder.id, sessionId: $0.sessionId) }
        guard !items.isEmpty else { return }
        let intent = WriteIntent.pull(items: items, targetFolderIds: signedInFolderIds)
        planSheet = PlanSheet(intent: intent, plan: Planner.plan(intent, paths: paths), note: note, openAfter: openAfter)
    }

    /// Open a chat once Claude has had a moment to start.
    func openWhenClaudeIsUp(_ r: SessionRecord) {
        Task { @MainActor in
            for _ in 0..<20 where !ClaudeApp.isRunning() { try? await Task.sleep(nanoseconds: 500_000_000) }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self.openInClaude(r)
        }
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
                    if let r = self.planSheet?.openAfter, self.planSheet?.id == sheetId { self.openWhenClaudeIsUp(r) }
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
        let usage: AccountUsage?
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
            AccountEntry(id: id, email: accountEmails[id], profile: profiles.first { $0.accountId == id }, isActive: id == active, usage: usage[id])
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
            notify("Saved the current Claude login as \(p.name).", title: "Login saved")
        } catch {
            notify(error.localizedDescription, title: "Could not save the login", warning: true)
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
        alert.informativeText = "Only Relay's saved copy is removed. Claude, the account and your chats are not touched. You can log in and save it again later."
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
                self.notify(r.notes.joined(separator: " "), title: "Claude is signed out", system: true)
            } catch {
                self.notify(error.localizedDescription, title: "Could not add an account", warning: true)
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
        var info = "The current login is saved first. Claude quits, which stops any running Code sessions, and reopens signed out. Log in to \(who) there. Relay saves that login by itself within a minute, and from then on you can switch to it from the menu bar."
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
                self.notify("Log in to \(who) in Claude. Relay saves it by itself once you are in.", title: "Claude is signed out", system: true)
            } catch {
                self.notify(error.localizedDescription, title: "Could not log in to \(who)", warning: true)
            }
            self.switching = false
            self.refresh()
        }
    }

    /// Switch Claude to a saved login. `carry` brings chats along first, `openAfter` opens a chat once Claude is
    /// back, and `auto` (the reason) marks an automatic switch, which reports by notification instead of alerts.
    func switchTo(_ p: LoginProfile, carry: WriteIntent? = nil, openAfter: SessionRecord? = nil, auto: String? = nil) {
        switching = true
        switchSteps = []
        let paths = self.paths
        let sync: [String]? = switchSyncEnabled ? syncFolderIds : nil
        let who = email(forAccount: p.accountId) ?? p.name
        Task { @MainActor in
            var notes: [String] = []
            var warnings: [String] = []
            var switched = false
            do {
                let r = try await LoginProfiles.switchTo(p, syncFolderIds: sync, carry: carry, paths: paths) { step in
                    onMainQueue { self.switchSteps.append(step) }
                }
                warnings = r.warnings
                notes = r.notes
                switched = r.switched
            } catch {
                warnings = [error.localizedDescription]
            }
            self.switching = false
            self.refresh()
            self.refreshUsage()
            if switched, let r = openAfter, let r2 = self.snapshot?.allSessions.first(where: { $0.sessionId == r.sessionId && $0.folder.accountId == p.accountId }) {
                self.openWhenClaudeIsUp(r2)
            }
            let body = ([auto].compactMap { $0 } + notes).joined(separator: " ")
            if auto != nil || warnings.isEmpty {
                let extra = warnings.isEmpty ? "" : " " + warnings.joined(separator: " ")
                self.notify(body + extra, title: switched ? "Switched to \(who)" : "Could not switch to \(who)",
                            warning: !warnings.isEmpty, system: true)
            } else {
                let alert = NSAlert()
                alert.messageText = switched ? "Switched to \(who), with a problem" : "Could not switch to \(who)"
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
    func backupNow() -> (ok: Bool, text: String) {
        let folders = (snapshot?.folders ?? []).map(\.folder).filter { !$0.isBackupCopy }
        do {
            let b = try BackupManager.create(folders: folders, reason: "manual", title: "Manual backup", changes: [], paths: paths)
            var info = b
            info.applied = true
            try? BackupManager.save(info)
            return (true, "Saved \(b.files.count) files to \(b.dir.lastPathComponent).")
        } catch {
            return (false, error.localizedDescription)
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
