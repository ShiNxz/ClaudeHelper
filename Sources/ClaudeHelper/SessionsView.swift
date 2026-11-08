import AppKit
import HelperCore
import SwiftUI

/// One chat, with its copies in every account folder being shown.
struct SessionRow: Identifiable {
    /// The copy shown: the signed-in account's when it has one, otherwise the newest.
    let record: SessionRecord
    /// Every copy in the folders being shown. Changes from the table go to all of them.
    let copies: [SessionRecord]
    /// One line per copy, for the Accounts tooltip.
    let copyLabels: [String]
    let accountCount: Int
    let edit: SessionEdit?
    let hasPending: Bool
    /// The signed-in account has this chat, so Claude can open it.
    let inSignedIn: Bool
    /// The signed-in account lacks it and can take it in.
    let pullable: Bool

    var id: String { record.sessionId }
    var title: String { edit?.title ?? record.title }
    var isArchived: Bool { edit?.isArchived ?? record.isArchived }
    var isStarred: Bool { edit?.isStarred ?? record.isStarred }
    var project: String {
        let comps = record.cwd.split(separator: "/")
        return comps.suffix(2).joined(separator: "/")
    }
    var lastActivity: Date { copies.map { $0.lastActivityAt ?? $0.fileMTime }.max() ?? record.fileMTime }
    var accountsText: String { accountCount == 1 ? (copyLabels.first ?? "") : "\(accountCount) accounts" }
    var archivedSort: Int { isArchived ? 1 : 0 }
    var hereSort: Int { inSignedIn ? 0 : pullable ? 1 : 2 }
    var pinnedSort: Int { isStarred ? 1 : 0 }
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "All", active = "Active", archived = "Archived", pinned = "Pinned", elsewhere = "Not in this account", pending = "Changed"
    var id: String { rawValue }
}

struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var status: StatusFilter = SelfCheck.sessionsFilter ?? .all
    @State private var folderFilter = "all-live"
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\SessionRow.lastActivity, order: .reverse)]
    @State private var renaming: [SessionRow] = []
    @State private var showInspector = false

    var rows: [SessionRow] {
        guard let snap = model.snapshot else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let have = model.signedInChatIds
        let active = snap.activeAccountId
        // Copies of each chat in the folders the Folder menu shows.
        var byChat: [String: [SessionRecord]] = [:]
        var order: [String] = []
        for f in snap.folders {
            switch folderFilter {
            case "all": break
            case "all-live": if f.folder.isBackupCopy { continue }
            default: if f.folder.id != folderFilter { continue }
            }
            for s in f.sessions {
                if byChat[s.sessionId] == nil { order.append(s.sessionId) }
                byChat[s.sessionId, default: []].append(s)
            }
        }
        var out: [SessionRow] = []
        for sid in order {
            let copies = byChat[sid]!
            let primary = copies.first { $0.folder.accountId == active && !$0.folder.isBackupCopy }
                ?? copies.max { ($0.lastActivityAt ?? $0.fileMTime) < ($1.lastActivityAt ?? $1.fileMTime) }!
            let row = SessionRow(record: primary, copies: copies,
                                 copyLabels: copies.map { model.label($0.folder) }.sorted(),
                                 accountCount: Set(copies.map { $0.folder.isBackupCopy ? $0.folder.id : $0.folder.accountId }).count,
                                 edit: model.pending[primary.id], hasPending: copies.contains { model.pending[$0.id] != nil },
                                 inSignedIn: have.contains(sid), pullable: copies.contains { model.canPull($0, have: have) })
            switch status {
            case .all: break
            case .active: if row.isArchived { continue }
            case .archived: if !row.isArchived { continue }
            case .pinned: if !row.isStarred { continue }
            case .elsewhere: if !row.pullable { continue }
            case .pending: if !row.hasPending { continue }
            }
            if !q.isEmpty {
                let hay = (row.title + " " + primary.cwd + " " + sid + " " + (primary.cliSessionId ?? "") + " " + row.copyLabels.joined(separator: " ")).lowercased()
                if !hay.contains(q) { continue }
            }
            out.append(row)
        }
        return out.sorted(using: sortOrder)
    }

    func rows(_ ids: Set<String>) -> [SessionRow] { rows.filter { ids.contains($0.id) } }

    /// Copies that changes go to: the live ones, or the backup copies for a chat that only exists there.
    static func editTargets(_ rows: [SessionRow]) -> [SessionRecord] {
        rows.flatMap { r in
            let live = r.copies.filter { !$0.folder.isBackupCopy }
            return live.isEmpty ? r.copies : live
        }
    }

    var body: some View {
        let rows = self.rows
        let selected = rows.filter { selection.contains($0.id) }
        let targets = Self.editTargets(selected)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Show", selection: $status) {
                    ForEach(StatusFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 540)
                .help("Not in this account: chats the signed-in account does not have, so Claude cannot open them yet.")
                Picker("Folder", selection: $folderFilter) {
                    Text("All accounts").tag("all-live")
                    Text("All, including backup copies").tag("all")
                    Divider()
                    ForEach(model.snapshot?.folders ?? []) { f in
                        Text("\(model.label(f.folder)) (\(f.sessions.count))").tag(f.folder.id)
                    }
                }
                .frame(maxWidth: 330)
                .help("Pick one account folder to see and change only its copies")
                Spacer()
                Text("\(rows.count) chat" + (rows.count == 1 ? "" : "s")).foregroundStyle(.secondary).font(.callout)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Title", value: \.title) { row in
                    HStack(spacing: 6) {
                        if row.hasPending { Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("Changed, not applied yet") }
                        Text(row.title).italic(row.hasPending).lineLimit(1)
                        let problems = row.copies.flatMap(\.problems)
                        if !problems.isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help(Array(Set(problems)).sorted().joined(separator: "\n"))
                        }
                    }
                }
                .width(min: 200, ideal: 320)
                TableColumn("Project", value: \.project) { row in
                    Text(row.project).foregroundStyle(.secondary).lineLimit(1).help(row.record.cwd)
                }
                .width(min: 90, ideal: 150)
                TableColumn("Signed-in account", value: \.hereSort) { row in
                    if row.inSignedIn {
                        HStack(spacing: 5) {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text("Here").foregroundStyle(.secondary)
                        }
                        .help("The signed-in account has this chat, so Claude can open it")
                    } else if row.pullable {
                        Button("Add to This Account") { model.previewPull(row.copies) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Copy this chat into the signed-in account so Claude can open it")
                    }
                }
                .width(min: 120, ideal: 140)
                TableColumn("Accounts", value: \.accountsText) { row in
                    Text(row.accountsText).foregroundStyle(.secondary).lineLimit(1)
                        .help(row.copyLabels.joined(separator: "\n"))
                }
                .width(min: 90, ideal: 160)
                TableColumn("Archived", value: \.archivedSort) { row in
                    if row.isArchived { Image(systemName: "archivebox").foregroundStyle(.secondary) }
                }
                .width(60)
                TableColumn("Pinned", value: \.pinnedSort) { row in
                    if row.isStarred { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                }
                .width(50)
                TableColumn("Last activity", value: \.lastActivity) { row in
                    Text(row.lastActivity, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                        .foregroundStyle(.secondary)
                }
                .width(min: 140, ideal: 160)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                contextMenu(for: self.rows(ids))
            } primaryAction: { ids in
                if let id = ids.first, let row = self.rows.first(where: { $0.id == id }) { model.open(row.record) }
            }

            if !model.pending.isEmpty { PendingBar() }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Filter by title, project, account or id")
        .toolbar {
            ToolbarItemGroup {
                Button { model.previewPull(selected.flatMap(\.copies)) } label: { Label("Add to This Account", systemImage: "square.and.arrow.down") }
                    .help("Copy the selected chats into the signed-in account so Claude can open them")
                    .disabled(!selected.contains { $0.pullable })
                Button { model.queue(targets, archived: false) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    .help("Restore the selected archived chats")
                    .disabled(!selected.contains { $0.isArchived })
                Button { model.queue(targets, archived: true) } label: { Label("Archive", systemImage: "archivebox") }
                    .help("Archive the selected chats in every account that has them")
                    .disabled(selected.isEmpty)
                Button {
                    model.queue(targets, starred: selected.contains { !$0.isStarred })
                } label: { Label("Pin", systemImage: "pin") }
                    .help("Pin or unpin the selected chats")
                    .disabled(selected.isEmpty)
                Button { renaming = selected } label: { Label("Rename", systemImage: "pencil") }
                    .help("Rename the selected chats")
                    .disabled(selected.isEmpty)
                Button { model.refresh() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .help("Read the session files again")
                Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                    .help("Show details of the selected chat")
            }
        }
        .inspector(isPresented: $showInspector) {
            SessionInspector(row: selected.count == 1 ? selected.first : nil)
                .inspectorColumnWidth(min: 260, ideal: 300)
        }
        .sheet(isPresented: Binding(get: { !renaming.isEmpty }, set: { if !$0 { renaming = [] } })) {
            RenameSheet(rows: renaming) { renaming = [] }
        }
    }

    @ViewBuilder
    func contextMenu(for rows: [SessionRow]) -> some View {
        let targets = Self.editTargets(rows)
        if let row = rows.first, rows.count == 1 {
            let r = row.record
            Button(row.inSignedIn ? "Open in Claude" : "Add to This Account and Open...") { model.open(r) }
            if let cmd = r.resumeCommand { Button("Copy Resume Command") { model.copy(cmd) } }
            Button("Copy Session ID") { model.copy(r.sessionId) }
            Button("Show File in Finder") { model.reveal(r.fileURL) }
            Divider()
        }
        if rows.contains(where: \.pullable) {
            Button("Add to This Account...") { model.previewPull(rows.flatMap(\.copies)) }
            Divider()
        }
        if !rows.isEmpty {
            Button("Restore from Archive") { model.queue(targets, archived: false) }
            Button("Archive") { model.queue(targets, archived: true) }
            Button("Pin") { model.queue(targets, starred: true) }
            Button("Unpin") { model.queue(targets, starred: false) }
            Button("Rename...") { renaming = rows }
            if rows.contains(where: \.hasPending) {
                Divider()
                Button("Undo Pending Change") { for r in rows.flatMap(\.copies) { model.pending[r.id] = nil } }
            }
        }
    }
}

struct PendingBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Image(systemName: "square.and.pencil")
            let n = Set(model.pending.values.map(\.sessionId)).count
            Text("\(n) chat\(n == 1 ? "" : "s") changed, not written yet.")
            Spacer()
            Button("Discard") { model.discardPending() }
            Button("Review and Apply...") { model.previewPending() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(10)
        .background(.bar)
    }
}

struct SessionInspector: View {
    @Environment(AppModel.self) private var model
    let row: SessionRow?

    var body: some View {
        if let row, case let r = row.record {
            Form {
                Section {
                    Text(r.title).font(.headline).textSelection(.enabled)
                    HStack {
                        Button(row.inSignedIn ? "Open in Claude" : "Add and Open") { model.open(r) }
                        if let cmd = r.resumeCommand { Button("Copy Resume") { model.copy(cmd) } }
                    }
                }
                Section(row.copies.count == 1 ? "Account" : "In \(row.accountCount) accounts") {
                    ForEach(row.copies, id: \.id) { c in
                        HStack {
                            Text(model.label(c.folder))
                            Spacer()
                            if c.isArchived { Image(systemName: "archivebox").foregroundStyle(.secondary).help("Archived in this account") }
                            if c.isStarred { Image(systemName: "pin.fill").foregroundStyle(.orange).help("Pinned in this account") }
                        }
                    }
                }
                Section("Shown copy") {
                    LabeledContent("Account folder", value: model.label(r.folder))
                    LabeledContent("Project", value: r.cwd)
                    LabeledContent("File") { Button(r.fileURL.lastPathComponent) { model.reveal(r.fileURL) }.buttonStyle(.link) }
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(r.fileSize), countStyle: .file))
                }
                Section("State") {
                    LabeledContent("Archived", value: r.isArchived ? "yes" : "no")
                    LabeledContent("In archived list", value: r.inArchivedIndex ? "yes" : "no")
                    LabeledContent("Pinned", value: r.isStarred ? "yes" : "no")
                    LabeledContent("Title source", value: r.titleSource ?? "-")
                    if let m = r.model { LabeledContent("Model", value: m) }
                }
                Section("IDs") {
                    LabeledContent("Session", value: r.sessionId).textSelection(.enabled)
                    LabeledContent("CLI session", value: r.cliSessionId ?? "missing").textSelection(.enabled)
                    if !r.priorCliSessionIds.isEmpty {
                        LabeledContent("Earlier CLI ids", value: r.priorCliSessionIds.joined(separator: ", ")).textSelection(.enabled)
                    }
                }
                Section("Dates") {
                    if let c = r.createdAt { LabeledContent("Created", value: c.formatted()) }
                    if let a = r.lastActivityAt { LabeledContent("Last activity", value: a.formatted()) }
                    LabeledContent("File modified", value: r.fileMTime.formatted())
                }
                if !r.problems.isEmpty {
                    Section("Schema guard") {
                        ForEach(r.problems, id: \.self) { Text($0).foregroundStyle(.orange) }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            Text("Select one chat to see its details.").foregroundStyle(.secondary).padding()
        }
    }
}

struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    let rows: [SessionRow]
    let done: () -> Void
    var records: [SessionRecord] { rows.map(\.record) }
    @State private var single = ""
    @State private var find = ""
    @State private var replace = ""
    @State private var prefix = ""

    func currentTitle(_ r: SessionRecord) -> String { model.pending[r.id]?.title ?? r.title }

    func newTitle(_ r: SessionRecord) -> String {
        if records.count == 1 { return single }
        var t = currentTitle(r)
        if !find.isEmpty { t = t.replacingOccurrences(of: find, with: replace) }
        if !prefix.isEmpty, !t.hasPrefix(prefix) { t = prefix + t }
        return t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(records.count == 1 ? "Rename chat" : "Rename \(records.count) chats").font(.headline)
            if records.count == 1 {
                TextField("Title", text: $single).textFieldStyle(.roundedBorder).frame(minWidth: 420)
            } else {
                Grid(alignment: .leading) {
                    GridRow { Text("Find"); TextField("text to replace", text: $find).textFieldStyle(.roundedBorder) }
                    GridRow { Text("Replace with"); TextField("", text: $replace).textFieldStyle(.roundedBorder) }
                    GridRow { Text("Add prefix"); TextField("optional", text: $prefix).textFieldStyle(.roundedBorder) }
                }
                List(records) { r in
                    VStack(alignment: .leading) {
                        Text(newTitle(r))
                        if newTitle(r) != currentTitle(r) { Text("was: " + currentTitle(r)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .frame(minWidth: 480, minHeight: 220)
            }
            Text("Titles are written when you apply pending changes. Renamed chats get titleSource \"user\" so Claude keeps the name.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Rename") {
                    // Every account's copy of a chat gets the title worked out from the shown copy.
                    var titles: [String: String] = [:]
                    for r in records {
                        let t = newTitle(r).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { titles[r.sessionId] = t }
                    }
                    model.queue(SessionsView.editTargets(rows), title: { titles[$0.sessionId] })
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { if let r = records.first { single = currentTitle(r) } }
    }
}
