import AppKit
import HelperCore
import SwiftUI

struct SyncView: View {
    @Environment(AppModel.self) private var model

    /// Accounts that have at least one chat list on this Mac.
    var accounts: [AppModel.AccountEntry] { model.accountEntries.filter { !model.folderIds(forAccount: $0.id).isEmpty } }
    var picked: [AppModel.AccountEntry] { accounts.filter { model.syncAccounts.contains($0.id) } }

    func countText(_ e: AppModel.AccountEntry) -> String {
        let lists = model.folderIds(forAccount: e.id).count
        return "\(model.chatCount(forAccount: e.id)) chats" + (lists > 1 ? ", in \(lists) chat lists (one per organization), all included" : "")
    }

    var explanation: String {
        if let src = model.syncSource, let e = picked.first(where: { $0.id == src }) {
            return "Copies the chats of \(e.title) into the other picked accounts. Their own chats stay and nothing is deleted. If an account already has a newer copy of a chat, it keeps its copy."
        }
        return "Every picked account ends up with all of their chats. When two accounts have the same chat, the newest copy wins. A chat deleted in one account stays deleted in all of them."
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Text("Give your accounts the same chats. Tick the accounts, choose how, then preview. Nothing is written until you apply, Claude is closed while it happens, and everything is backed up first.")
                    .foregroundStyle(.secondary)
            }
            Section("Accounts") {
                ForEach(accounts) { e in
                    Toggle(isOn: Binding(
                        get: { model.syncAccounts.contains(e.id) },
                        set: { on in
                            if on { model.syncAccounts.insert(e.id) } else {
                                model.syncAccounts.remove(e.id)
                                if model.syncSource == e.id { model.syncSource = nil }
                            }
                        })) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(e.title)
                                if e.isActive { Text("signed in").font(.caption).foregroundStyle(.green) }
                            }
                            Text(countText(e)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 2)
                }
            }
            Section("How") {
                Picker("", selection: $model.syncSource) {
                    Text("Merge: every picked account gets every chat").tag(String?.none)
                    ForEach(picked) { e in
                        Text("Copy from \(e.title) to the others" + (e.isActive ? " (signed in now)" : "")).tag(String?.some(e.id))
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(explanation).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text(picked.count < 2 ? "Tick at least two accounts." : "\(picked.count) accounts picked").foregroundStyle(.secondary)
                    Spacer()
                    Button("Preview...") { model.previewSync() }
                        .disabled(model.syncIntent == nil)
                        .keyboardShortcut(.defaultAction)
                }
            }
            Section {
                DisclosureGroup("Folders on disk") {
                    ForEach(model.snapshot?.folders ?? []) { f in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.label(f.folder)).font(.callout)
                            Text("\(f.sessions.count) chats, \(f.deletedMarkers.count) deleted markers" + (f.folder.isBackupCopy ? ", hand-made backup copy, never synced" : "")
                                 + (model.syncFolderIds.contains(f.folder.id) ? ", included" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(f.folder.id).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct BackupsView: View {
    @Environment(AppModel.self) private var model
    @State private var backups: [BackupInfo] = []
    @State private var selected: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Every write makes a backup here first. Restoring one quits Claude, backs up the current state, puts the session files back as they were and reopens Claude. backlog, waiting-input and scheduled-tasks.json are never touched.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Back Up Now") {
                    let r = model.backupNow()
                    model.notify(r.text, title: r.ok ? "Backed up" : "Backup failed", warning: !r.ok)
                    backups = model.backups()
                }
                .help("Save a copy of every account folder's session files without changing anything")
                Button("Open Folder") { model.reveal(model.paths.backupsDir) }
            }
            .padding(12)
            Divider()
            if backups.isEmpty {
                Text("No backups yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(backups, selection: $selected) { b in
                    BackupRow(backup: b, expanded: selected == b.id).tag(b.id)
                }
            }
        }
        .onAppear { backups = model.backups() }
        .onChange(of: model.planSheet == nil) { _, _ in backups = model.backups() }
    }
}

struct BackupRow: View {
    @Environment(AppModel.self) private var model
    let backup: BackupInfo
    let expanded: Bool

    var foldersText: String {
        backup.folders.map { String($0.accountId.prefix(8)) + "/" + String($0.orgId.prefix(8)) }.joined(separator: ", ")
    }

    var countsText: String {
        let applied = backup.applied ? "" : ", not applied"
        return "\(backup.files.count) files saved, \(backup.changes.count) planned changes, \(backup.removed.count) moved out" + applied
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(backup.title).font(.headline)
                Text(backup.created.formatted(date: .abbreviated, time: .standard) + ", " + foldersText)
                    .font(.caption).foregroundStyle(.secondary)
                Text(countsText).font(.caption).foregroundStyle(.secondary)
                if expanded {
                    ForEach(Array(backup.changes.prefix(12)), id: \.self) { c in Text("- " + c).font(.caption) }
                    if backup.changes.count > 12 {
                        Text("and \(backup.changes.count - 12) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button("Show") { model.reveal(backup.dir) }
            Button("Preview Restore...") { model.previewRestore(backup) }
        }
        .padding(.vertical, 4)
    }
}

struct PlanSheetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let sheet = model.planSheet {
            content(sheet).frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 640)
        }
    }

    @ViewBuilder
    func content(_ sheet: PlanSheet) -> some View {
        let plan = sheet.plan
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.title).font(.title2.bold())
                Text(summaryLine(plan)).foregroundStyle(.secondary)
                if let note = sheet.note { Text(note).foregroundStyle(.orange) }
            }
            .padding(16)
            Divider()
            switch sheet.state {
            case .preview:
                changeList(plan)
            case .applying(let steps):
                stepList(steps, running: true)
            case .done(let result, let reopened, _):
                VStack(alignment: .leading, spacing: 10) {
                    Label("Done. Wrote \(result.written) file(s), moved \(result.moved) to the backup.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.headline)
                    Text(reopened ? "Claude was reopened." : (model.claudeRunning ? "" : "Claude was not running, so it was not started."))
                    if let r = sheet.openAfter { Text("Opening \(quoted(r.title)) in Claude.") }
                    HStack {
                        Text("Backup: " + result.backup.dir.path).font(.caption).textSelection(.enabled)
                        Button("Show") { model.reveal(result.backup.dir) }
                    }
                    if result.log.contains(where: { $0.hasPrefix("WARNING") }) {
                        ForEach(result.log.filter { $0.hasPrefix("WARNING") }, id: \.self) { Text($0).foregroundStyle(.orange) }
                    }
                    Spacer()
                }
                .padding(16)
            case .failed(let message, let steps):
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    stepList(steps, running: false)
                }
                .padding(16)
            }
            Divider()
            footer(sheet)
                .padding(12)
        }
    }

    func summaryLine(_ plan: WritePlan) -> String {
        var parts = ["\(plan.changes.count) change(s) in \(Set(plan.changes.map(\.folder.id)).count) folder(s)"]
        if !plan.problems.isEmpty { parts.append("\(plan.problems.count) problem(s) block applying") }
        if !plan.warnings.isEmpty { parts.append("\(plan.warnings.count) warning(s)") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    func changeList(_ plan: WritePlan) -> some View {
        List {
            if !plan.problems.isEmpty {
                Section("Schema guard: nothing will be written until these are fixed") {
                    ForEach(plan.problems) { p in
                        VStack(alignment: .leading) {
                            Text(p.message).foregroundStyle(.red)
                            Text(p.path.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            if !plan.warnings.isEmpty {
                Section("Warnings") {
                    ForEach(plan.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
            }
            if plan.changes.isEmpty && plan.problems.isEmpty {
                Text("Nothing to change. Everything already matches.").foregroundStyle(.secondary)
            }
            let byFolder = Dictionary(grouping: plan.changes, by: \.folder.id)
            ForEach(byFolder.keys.sorted(), id: \.self) { fid in
                let changes = byFolder[fid]!.sorted { a, b in
                    let ka = kindOrder(a.kind), kb = kindOrder(b.kind)
                    return ka != kb ? ka < kb : a.summary.localizedCaseInsensitiveCompare(b.summary) == .orderedAscending
                }
                Section(model.label(changes[0].folder) + ":  " + totals(changes)) {
                    ForEach(changes) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: icon(c.kind)).foregroundStyle(color(c.kind)).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.summary).lineLimit(2)
                                if let d = c.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                    }
                }
            }
        }
    }

    static let kindNames: [PlannedChange.Kind: String] = [
        .edit: "edit", .update: "update", .add: "add", .putBack: "put back", .removeDeleted: "move out deleted",
        .moveOut: "move out", .addMarker: "deleted marker", .archivedIndex: "archived list",
    ]

    func kindOrder(_ k: PlannedChange.Kind) -> Int {
        [.edit, .update, .add, .putBack, .removeDeleted, .moveOut, .addMarker, .archivedIndex].firstIndex(of: k) ?? 99
    }

    func totals(_ changes: [PlannedChange]) -> String {
        let counts = Dictionary(grouping: changes, by: \.kind).mapValues(\.count)
        return counts.keys.sorted { kindOrder($0) < kindOrder($1) }
            .map { "\(Self.kindNames[$0] ?? $0.rawValue): \(counts[$0]!)" }
            .joined(separator: ", ")
    }

    func icon(_ k: PlannedChange.Kind) -> String {
        switch k {
        case .edit: return "pencil"
        case .add: return "plus.circle"
        case .update: return "arrow.triangle.2.circlepath"
        case .removeDeleted, .moveOut: return "tray.and.arrow.up"
        case .addMarker: return "trash.slash"
        case .archivedIndex: return "archivebox"
        case .putBack: return "arrow.uturn.backward"
        }
    }

    func color(_ k: PlannedChange.Kind) -> Color {
        switch k {
        case .removeDeleted, .moveOut, .addMarker: return .orange
        case .add, .putBack: return .green
        default: return .accentColor
        }
    }

    func stepList(_ steps: [String], running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                HStack {
                    if running && i == steps.count - 1 { ProgressView().controlSize(.small) } else { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                    Text(s).textSelection(.enabled)
                }
            }
            if steps.isEmpty && running { ProgressView().controlSize(.small) }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func footer(_ sheet: PlanSheet) -> some View {
        HStack {
            switch sheet.state {
            case .preview:
                if !model.claudeRunning, model.paths.isLiveSessionsRoot {
                    Button("Reopen Claude") { model.reopenClaude() }
                }
                if let r = sheet.openAfter {
                    Button("Open Without Adding") { model.planSheet = nil; model.openInClaude(r) }
                        .help("Claude most likely shows an empty or missing chat")
                }
                Spacer()
                Button("Cancel") { model.planSheet = nil }.keyboardShortcut(.cancelAction)
                Button((model.claudeRunning ? "Quit Claude, Back Up and " : "Back Up and ") + (sheet.openAfter == nil ? "Apply" : "Add")) { model.applyPlan() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!sheet.plan.canApply)
            case .applying:
                Spacer()
                Text("Working. Do not reopen Claude yet.").foregroundStyle(.secondary)
            case .done, .failed:
                Spacer()
                Button("Close") { model.planSheet = nil; model.refresh() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
