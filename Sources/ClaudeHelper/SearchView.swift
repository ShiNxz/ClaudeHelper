import AppKit
import HelperCore
import SwiftUI

func highlighted(_ snippet: String) -> AttributedString {
    var out = AttributedString()
    var bold = false
    var buf = ""
    func flush() {
        guard !buf.isEmpty else { return }
        var part = AttributedString(buf)
        if bold {
            part.font = .body.bold()
            part.backgroundColor = Color.yellow.opacity(0.35)
        }
        out += part
        buf = ""
    }
    for ch in snippet {
        if ch == "\u{2}" { flush(); bold = true }
        else if ch == "\u{3}" { flush(); bold = false }
        else { buf.append(ch == "\n" ? " " : ch) }
    }
    flush()
    return out
}

func shortDate(_ iso: String?) -> String {
    guard let iso, let d = parseISODate(iso) else { return "" }
    return d.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
}

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var role: SearchRole = .any
    @State private var order: SearchOrder = .relevance
    @State private var onlyOrphans = false
    @State private var groups: [SearchGroup] = []
    @State private var error: String?
    @State private var elapsed: Double = 0
    @FocusState private var focused: Bool

    var query: String { model.searchQuery }

    var body: some View {
        @Bindable var model = model
        let snap = model.snapshot
        let map = snap?.sessionsByCliId() ?? [:]
        let shown = onlyOrphans ? groups.filter { map[$0.file.cliSessionId] == nil } : groups
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your chats. Words must all match, \"quotes\" for a phrase.", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                Picker("", selection: $role) {
                    Text("Everyone").tag(SearchRole.any)
                    Text("Me").tag(SearchRole.user)
                    Text("Claude").tag(SearchRole.assistant)
                    if model.indexSettings.includeToolOutput { Text("Tools").tag(SearchRole.tool) }
                }
                .frame(width: 110)
                Picker("", selection: $order) {
                    Text("Best match").tag(SearchOrder.relevance)
                    Text("Newest").tag(SearchOrder.newest)
                }
                .frame(width: 120)
                Toggle("No desktop session", isOn: $onlyOrphans).toggleStyle(.checkbox)
                    .help("Only chats that have no sidebar entry in any account folder")
            }
            .padding(12)
            IndexBar()
            Divider()
            HSplitView {
                List(selection: $model.searchSelection) {
                    if let error { Text(error).foregroundStyle(.red) }
                    if !query.isEmpty && shown.isEmpty && error == nil {
                        Text(model.indexFiles == 0 ? "The index is still empty. It fills in the background." : "No matches.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(shown) { g in
                        ResultRow(group: g, desktop: snap?.preferredSession(forCli: g.file.cliSessionId, in: map), labeler: model.label)
                            .tag(g.id)
                    }
                }
                .frame(minWidth: 340, idealWidth: 420)
                Group {
                    if let id = model.searchSelection, let g = groups.first(where: { $0.id == id }) {
                        ResultDetail(group: g, desktop: snap?.preferredSession(forCli: g.file.cliSessionId, in: map),
                                     copies: map[g.file.cliSessionId] ?? [])
                            .id(g.id)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "text.magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
                            Text(groups.isEmpty ? "Type to search \(model.indexMessages) messages." : "\(shown.count) chats, \(String(format: "%.0f", elapsed)) ms")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 380)
            }
        }
        .onAppear { focused = true }
        .task(id: "\(query)|\(role.rawValue)|\(order.rawValue)|\(model.indexMessages)") {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let q = query, r = role, o = order, paths = model.paths
            let t0 = Date()
            let result = await Task.detached { () -> Result<[SearchGroup], Error> in
                Result { try TranscriptIndex.search(paths: paths, query: q, role: r, order: o) }
            }.value
            guard !Task.isCancelled else { return }
            elapsed = Date().timeIntervalSince(t0) * 1000
            switch result {
            case .success(let g):
                groups = g
                error = nil
                if let s = model.searchSelection, !g.contains(where: { $0.id == s }) { model.searchSelection = nil }
                if model.searchSelection == nil, model.autoSelectFirstResult { model.searchSelection = g.first?.id }
            case .failure(let e):
                error = "Search failed: " + e.localizedDescription
            }
        }
    }
}

struct IndexBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            if model.indexProgress.isRunning {
                ProgressView(value: model.indexProgress.fraction).frame(width: 160)
            }
            Text(model.indexStatusText).font(.callout).foregroundStyle(.secondary)
            if let last = model.indexLastRun, !model.indexProgress.isRunning {
                Text("updated " + shortDate(last)).font(.callout).foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                Toggle("Include tool calls and output", isOn: $model.indexSettings.includeToolOutput)
                Toggle("Include subagent and workflow chats", isOn: $model.indexSettings.includeSubagents)
                Divider()
                Text("Changing these rebuilds the index. With both on, the first build reads every transcript and can take minutes, and the index gets much larger.")
            } label: {
                Label("Index options", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onChange(of: model.indexSettings) { _, _ in
                model.cancelIndexing()
                model.startIndexing(force: true)
            }
            if model.indexProgress.isRunning {
                Button("Stop") { model.cancelIndexing() }
            } else {
                Button("Update index") { model.startIndexing() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

struct ResultRow: View {
    let group: SearchGroup
    let desktop: SessionRecord?
    let labeler: (SessionFolder) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(desktop?.title ?? group.file.displayTitle).font(.headline).lineLimit(1)
                Spacer()
                Text("\(group.hits.count)").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            HStack(spacing: 6) {
                Text(projectName(group.file)).lineLimit(1)
                Text(shortDate(group.file.lastTimestamp))
                if let d = desktop {
                    if d.isArchived { Text("archived").foregroundStyle(.orange) }
                    Text(labeler(d.folder)).lineLimit(1)
                } else {
                    Text("no desktop session").foregroundStyle(.orange)
                }
                if group.file.isSubagent { Text("subagent") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let h = group.hits.first {
                Text(highlighted(h.snippet)).font(.callout).lineLimit(2).foregroundStyle(.primary.opacity(0.85))
            }
        }
        .padding(.vertical, 3)
    }
}

func projectName(_ f: IndexedFile) -> String {
    if let cwd = f.cwd, !cwd.isEmpty { return cwd.split(separator: "/").suffix(2).joined(separator: "/") }
    return f.projectDir
}

struct ResultDetail: View {
    @Environment(AppModel.self) private var model
    let group: SearchGroup
    let desktop: SessionRecord?
    let copies: [SessionRecord]
    @State private var hit: Int64?
    @State private var full: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(desktop?.title ?? group.file.displayTitle).font(.title3.bold()).textSelection(.enabled)
                Text(group.file.cwd ?? group.file.projectDir).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Text("\(group.file.messages) messages, last on \(shortDate(group.file.lastTimestamp))").font(.callout).foregroundStyle(.secondary)
                HStack {
                    if let d = desktop {
                        Button("Open in Claude") { model.open(d) }.keyboardShortcut(.defaultAction)
                        if d.isArchived {
                            Button("Restore to Sidebar") {
                                model.queue([d], archived: false)
                                model.section = .sessions
                            }
                        }
                    }
                    Button("Copy Resume Command") { model.copy(group.file.resumeCommand) }
                        .help(group.file.resumeCommand)
                    Button("Show Transcript") { model.reveal(URL(fileURLWithPath: group.file.path)) }
                }
                if desktop == nil {
                    Text("No account folder has a sidebar entry for this chat. Resume it from a terminal with the copied command.")
                        .font(.callout).foregroundStyle(.orange)
                } else if copies.count > 1 {
                    Text("Sidebar entries in: " + copies.map { model.label($0.folder) + ($0.isArchived ? " (archived)" : "") }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            Divider()
            List(group.hits, selection: $hit) { h in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(h.role == "user" ? "You" : h.role == "assistant" ? "Claude" : "Tool").font(.caption.bold())
                        Text(shortDate(h.timestamp)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(highlighted(h.snippet)).font(.callout)
                }
                .tag(h.id)
            }
            .frame(minHeight: 140)
            if let full {
                Divider()
                ScrollView {
                    Text(full).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .frame(minHeight: 160)
            }
        }
        .onChange(of: hit) { _, id in
            full = id.flatMap { TranscriptIndex.fullText(paths: model.paths, rowid: $0) }
        }
    }
}
