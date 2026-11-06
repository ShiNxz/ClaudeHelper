import AppKit
import HelperCore
import SwiftUI

struct SessionRow: Identifiable {
    let record: SessionRecord
    let edit: SessionEdit?
    let accountLabel: String
    let copies: Int

    var id: String { record.id }
    var title: String { edit?.title ?? record.title }
    var isArchived: Bool { edit?.isArchived ?? record.isArchived }
    var isStarred: Bool { edit?.isStarred ?? record.isStarred }
    var hasPending: Bool { edit != nil }
    var project: String {
        let comps = record.cwd.split(separator: "/")
        return comps.suffix(2).joined(separator: "/")
    }
    var lastActivity: Date { record.lastActivityAt ?? record.fileMTime }
    var archivedSort: Int { isArchived ? 1 : 0 }
    var pinnedSort: Int { isStarred ? 1 : 0 }
}

enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "All", active = "Active", archived = "Archived", pinned = "Pinned", pending = "Changed"
    var id: String { rawValue }
}

struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var status: StatusFilter = .all
    @State private var folderFilter = "all-live"
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\SessionRow.lastActivity, order: .reverse)]
    @State private var renaming: [SessionRecord] = []
    @State private var showInspector = false

    var rows: [SessionRow] {
        guard let snap = model.snapshot else { return [] }
        var counts: [String: Int] = [:]
        for s in snap.allSessions where !s.folder.isBackupCopy { counts[s.sessionId, default: 0] += 1 }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [SessionRow] = []
        for f in snap.folders {
            switch folderFilter {
            case "all": break
            case "all-live": if f.folder.isBackupCopy { continue }
            default: if f.folder.id != folderFilter { continue }
            }
            let label = model.label(f.folder)
            for s in f.sessions {
                let row = SessionRow(record: s, edit: model.pending[s.id], accountLabel: label, copies: counts[s.sessionId] ?? 1)
                switch status {
                case .all: break
                case .active: if row.isArchived { continue }
                case .archived: if !row.isArchived { continue }
                case .pinned: if !row.isStarred { continue }
                case .pending: if !row.hasPending { continue }
                }
                if !q.isEmpty {
                    let hay = (row.title + " " + s.cwd + " " + s.sessionId + " " + (s.cliSessionId ?? "")).lowercased()
                    if !hay.contains(q) { continue }
                }
                out.append(row)
            }
        }
        return out.sorted(using: sortOrder)
    }

    var selectedRecords: [SessionRecord] {
        guard let snap = model.snapshot else { return [] }
        return snap.allSessions.filter { selection.contains($0.id) }
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Show", selection: $status) {
                    ForEach(StatusFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 380)
                Picker("Folder", selection: $folderFilter) {
                    Text("All account folders").tag("all-live")
                    Text("All, including backup copies").tag("all")
                    Divider()
                    ForEach(model.snapshot?.folders ?? []) { f in
                        Text("\(model.label(f.folder)) (\(f.sessions.count))").tag(f.folder.id)
                    }
                }
                .frame(maxWidth: 330)
                Spacer()
                Text("\(rows.count) shown").foregroundStyle(.secondary).font(.callout)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Title", value: \.title) { row in
                    HStack(spacing: 6) {
                        if row.hasPending { Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("Changed, not applied yet") }
                        Text(row.title).italic(row.hasPending).lineLimit(1)
                        if !row.record.problems.isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help(row.record.problems.joined(separator: "\n"))
                        }
                    }
                }
                .width(min: 200, ideal: 300)
                TableColumn("Project", value: \.project) { row in
                    Text(row.project).foregroundStyle(.secondary).lineLimit(1).help(row.record.cwd)
                }
                .width(min: 90, ideal: 150)
                TableColumn("Account folder", value: \.accountLabel) { row in
                    Text(row.accountLabel).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 90, ideal: 150)
                TableColumn("Copies", value: \.copies) { row in
                    Text(row.copies > 1 ? "\(row.copies)" : "").foregroundStyle(.secondary)
                        .help("Number of account folders with this chat")
                }
                .width(50)
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
                contextMenu(for: ids)
            } primaryAction: { ids in
                if let id = ids.first, let r = model.record(for: id) { model.open(r) }
            }

            if !model.pending.isEmpty { PendingBar() }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Filter by title, folder or id")
        .toolbar {
            ToolbarItemGroup {
                Button { model.queue(selectedRecords, archived: false) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    .help("Restore the selected archived chats")
                    .disabled(!selectedRecords.contains { (model.pending[$0.id]?.isArchived ?? $0.isArchived) })
                Button { model.queue(selectedRecords, archived: true) } label: { Label("Archive", systemImage: "archivebox") }
                    .help("Archive the selected chats")
                    .disabled(selectedRecords.isEmpty)
                Button {
                    let anyUnpinned = selectedRecords.contains { !(model.pending[$0.id]?.isStarred ?? $0.isStarred) }
                    model.queue(selectedRecords, starred: anyUnpinned)
                } label: { Label("Pin", systemImage: "pin") }
                    .help("Pin or unpin the selected chats")
                    .disabled(selectedRecords.isEmpty)
                Button { renaming = selectedRecords } label: { Label("Rename", systemImage: "pencil") }
                    .help("Rename the selected chats")
                    .disabled(selectedRecords.isEmpty)
                Button { model.refresh() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .help("Read the session files again")
                Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                    .help("Show details of the selected chat")
            }
        }
        .inspector(isPresented: $showInspector) {
            SessionInspector(record: selectedRecords.count == 1 ? selectedRecords.first : nil)
                .inspectorColumnWidth(min: 260, ideal: 300)
        }
        .sheet(isPresented: Binding(get: { !renaming.isEmpty }, set: { if !$0 { renaming = [] } })) {
            RenameSheet(records: renaming) { renaming = [] }
        }
    }

    @ViewBuilder
    func contextMenu(for ids: Set<String>) -> some View {
        let recs = model.snapshot?.allSessions.filter { ids.contains($0.id) } ?? []
        if let r = recs.first, recs.count == 1 {
            Button("Open in Claude") { model.open(r) }
            if let cmd = r.resumeCommand { Button("Copy Resume Command") { model.copy(cmd) } }
            Button("Copy Session ID") { model.copy(r.sessionId) }
            Button("Show File in Finder") { model.reveal(r.fileURL) }
            Divider()
        }
        if !recs.isEmpty {
            Button("Restore from Archive") { model.queue(recs, archived: false) }
            Button("Archive") { model.queue(recs, archived: true) }
            Button("Pin") { model.queue(recs, starred: true) }
            Button("Unpin") { model.queue(recs, starred: false) }
            Button("Rename...") { renaming = recs }
            if recs.contains(where: { model.pending[$0.id] != nil }) {
                Divider()
                Button("Undo Pending Change") { for r in recs { model.pending[r.id] = nil } }
            }
        }
    }
}

struct PendingBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Image(systemName: "square.and.pencil")
            Text("\(model.pending.count) chat\(model.pending.count == 1 ? "" : "s") changed, not written yet.")
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
    let record: SessionRecord?

    var body: some View {
        if let r = record {
            Form {
                Section {
                    Text(r.title).font(.headline).textSelection(.enabled)
                    HStack {
                        Button("Open in Claude") { model.open(r) }
                        if let cmd = r.resumeCommand { Button("Copy Resume") { model.copy(cmd) } }
                    }
                }
                Section("Where") {
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
    let records: [SessionRecord]
    let done: () -> Void
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
                    model.queue(records, title: { r in
                        let t = newTitle(r).trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? nil : t
                    })
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { if let r = records.first { single = currentTitle(r) } }
    }
}
