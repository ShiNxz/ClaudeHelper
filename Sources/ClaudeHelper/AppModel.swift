import AppKit
import HelperCore
import Observation
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case search = "Search"
    case sync = "Account sync"
    case backups = "Backups"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .sessions: return "list.bullet.rectangle"
        case .search: return "magnifyingglass"
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

    // Sync
    var syncSelection: Set<String> {
        didSet { UserDefaults.standard.set(Array(syncSelection), forKey: "syncSelection") }
    }
    var nicknames: [String: String] {
        didSet { UserDefaults.standard.set(nicknames, forKey: "folderNicknames") }
    }

    init() {
        let d = UserDefaults.standard
        indexSettings = IndexSettings(includeToolOutput: d.bool(forKey: "index.tools"), includeSubagents: d.bool(forKey: "index.subagents"))
        syncSelection = Set(d.stringArray(forKey: "syncSelection") ?? [])
        nicknames = d.dictionary(forKey: "folderNicknames") as? [String: String] ?? [:]
        refresh()
        loadIndexStats()
        startIndexing()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.startIndexing() }
        }
    }

    private func saveSettings() {
        UserDefaults.standard.set(indexSettings.includeToolOutput, forKey: "index.tools")
        UserDefaults.standard.set(indexSettings.includeSubagents, forKey: "index.subagents")
    }

    // MARK: Sessions

    func refresh() {
        snapshot = SessionScanner.scan(paths: paths)
        claudeRunning = ClaudeApp.isRunning()
        // Drop pending edits whose session vanished.
        if let snap = snapshot {
            let ids = Set(snap.allSessions.map(\.id))
            pending = pending.filter { ids.contains($0.key) }
        }
    }

    func label(_ folder: SessionFolder) -> String {
        var s = nicknames[folder.id].flatMap { $0.isEmpty ? nil : $0 } ?? folder.shortLabel
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

    func previewSync(folderIds: [String]? = nil) {
        let chosen = folderIds.map(Set.init) ?? syncSelection
        let ordered = snapshot?.folders.map(\.folder.id).filter { chosen.contains($0) } ?? Array(chosen)
        let intent = WriteIntent.sync(folderIds: ordered)
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

    // MARK: Index

    func loadIndexStats() {
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
                onMainQueue {
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
