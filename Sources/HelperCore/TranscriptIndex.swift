import Foundation

public struct IndexSettings: Equatable, Codable, Sendable {
    public var includeToolOutput: Bool
    public var includeSubagents: Bool

    public init(includeToolOutput: Bool = false, includeSubagents: Bool = false) {
        self.includeToolOutput = includeToolOutput
        self.includeSubagents = includeSubagents
    }

    /// Bump the version when the extraction rules change; a different key forces a full rebuild.
    var key: String { "v3;tools=\(includeToolOutput);subagents=\(includeSubagents)" }
}

public struct IndexProgress: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle, discovering, indexing, done, cancelled
        case failed(String)
    }
    public var phase: Phase = .idle
    public var filesTotal = 0
    public var filesDone = 0
    public var bytesTotal: Int64 = 0
    public var bytesDone: Int64 = 0
    public var messagesAdded = 0
    public var currentFile: String?
    public var startedAt = Date()
    public var finishedAt: Date?
    public var rebuilt = false

    public init() {}

    public var fraction: Double {
        bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : (filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : 0)
    }
    public var isRunning: Bool { phase == .discovering || phase == .indexing }
}

public struct IndexedFile: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let path: String
    public let cliSessionId: String
    public let isSubagent: Bool
    public let projectDir: String
    public let cwd: String?
    public let title: String?
    public let firstPrompt: String?
    public let firstTimestamp: String?
    public let lastTimestamp: String?
    public let messages: Int
    public let size: Int64

    public var lastDate: Date? { lastTimestamp.flatMap(parseISODate) }
    public var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if let p = firstPrompt, !p.isEmpty { return p }
        return cliSessionId
    }
    public var resumeCommand: String {
        let dir = cwd ?? ""
        return (dir.isEmpty ? "" : "cd " + shellQuote(dir) + " && ") + "claude --resume " + cliSessionId
    }
}

public struct SearchHit: Sendable, Identifiable, Hashable {
    public let id: Int64          // fts rowid
    public let fileId: Int64
    public let role: String
    public let timestamp: String?
    /// Snippet with \u{2} ... \u{3} around matched terms.
    public let snippet: String
    public let rank: Double
}

public struct SearchGroup: Sendable, Identifiable, Hashable {
    public let file: IndexedFile
    public var hits: [SearchHit]
    public var bestRank: Double
    public var id: Int64 { file.id }
}

public enum SearchRole: String, CaseIterable, Sendable {
    case any, user, assistant, tool
}

public enum SearchOrder: String, CaseIterable, Sendable {
    case relevance, newest
}

let isoFormatterFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoFormatter = ISO8601DateFormatter()

public func parseISODate(_ s: String) -> Date? {
    isoFormatterFrac.date(from: s) ?? isoFormatter.date(from: s)
}

/// Full-text index of transcripts in ~/.claude/projects. Transcripts are only ever read.
public final class TranscriptIndex {
    let db: SQLiteDB
    let paths: HelperPaths
    let settings: IndexSettings

    public init(paths: HelperPaths, settings: IndexSettings) throws {
        self.paths = paths
        self.settings = settings
        try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
        db = try SQLiteDB(path: paths.indexDB.path)
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        try createSchema()
    }

    func createSchema() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS files(
            id INTEGER PRIMARY KEY,
            path TEXT UNIQUE NOT NULL,
            inode INTEGER, size INTEGER, mtime REAL, offset INTEGER,
            cli_session_id TEXT, is_subagent INTEGER, project_dir TEXT,
            cwd TEXT, title TEXT, title_kind INTEGER, first_prompt TEXT,
            first_ts TEXT, last_ts TEXT, messages INTEGER DEFAULT 0);
        CREATE INDEX IF NOT EXISTS files_cli ON files(cli_session_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS messages USING fts5(
            text, role UNINDEXED, file_id UNINDEXED, ts UNINDEXED,
            tokenize='unicode61 remove_diacritics 2');
        """)
    }

    func meta(_ key: String) throws -> String? {
        let s = try db.prepare("SELECT value FROM meta WHERE key=?")
        s.bind(1, key)
        return try s.step() ? s.text(0) : nil
    }

    func setMeta(_ key: String, _ value: String) throws {
        let s = try db.prepare("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)")
        s.bind(1, key).bind(2, value)
        try s.run()
    }

    public func stats() -> (files: Int, messages: Int, lastRun: String?) {
        var files = 0, msgs = 0
        if let s = try? db.prepare("SELECT count(*), coalesce(sum(messages),0) FROM files"), (try? s.step()) == true {
            files = Int(s.int64(0)); msgs = Int(s.int64(1))
        }
        return (files, msgs, try? meta("last_run"))
    }

    // MARK: Discovery

    struct Candidate {
        let url: URL
        let cliSessionId: String
        let isSubagent: Bool
        let projectDir: String
        let inode: Int64
        let size: Int64
        let mtime: Double
    }

    func discover() -> [Candidate] {
        let fm = FileManager.default
        var out: [Candidate] = []
        guard let projects = try? fm.contentsOfDirectory(atPath: paths.projectsRoot.path) else { return [] }
        for proj in projects where !proj.hasPrefix(".") {
            let projURL = paths.projectsRoot.appendingPathComponent(proj, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(atPath: projURL.path) else { continue }
            for item in items {
                let url = projURL.appendingPathComponent(item)
                if item.hasSuffix(".jsonl") {
                    if let c = candidate(url, cli: String(item.dropLast(6)), sub: false, proj: proj) { out.append(c) }
                } else if settings.includeSubagents {
                    // <cli id>/subagents/agent-*.jsonl and <cli id>/subagents/workflows/<wf>/agent-*.jsonl
                    let subDir = url.appendingPathComponent("subagents", isDirectory: true)
                    guard fm.fileExists(atPath: subDir.path), let e = fm.enumerator(atPath: subDir.path) else { continue }
                    while let rel = e.nextObject() as? String {
                        guard rel.hasSuffix(".jsonl") else { continue }
                        if let c = candidate(subDir.appendingPathComponent(rel), cli: item, sub: true, proj: proj) { out.append(c) }
                    }
                }
            }
        }
        return out
    }

    func candidate(_ url: URL, cli: String, sub: Bool, proj: String) -> Candidate? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return Candidate(url: url, cliSessionId: cli, isSubagent: sub, projectDir: proj, inode: Int64(st.st_ino), size: Int64(st.st_size), mtime: mtime)
    }

    struct FileState {
        var id: Int64
        var inode: Int64
        var size: Int64
        var mtime: Double
        var offset: Int64
        var titleKind: Int   // 0 none, 1 summary, 2 ai-title, 3 custom-title
        var title: String?
        var cwd: String?
        var firstPrompt: String?
        var firstTs: String?
        var lastTs: String?
        var messages: Int
    }

    // MARK: Update

    /// Index new bytes of every transcript. Safe to call repeatedly; only appended lines are read.
    public func update(progress: (IndexProgress) -> Void, cancelled: () -> Bool) throws {
        var p = IndexProgress()
        p.phase = .discovering
        progress(p)

        if try meta("settings") != settings.key {
            try db.exec("DROP TABLE IF EXISTS messages; DROP TABLE IF EXISTS files;")
            try createSchema()
            try setMeta("settings", settings.key)
            p.rebuilt = true
        }

        let found = discover()
        var known: [String: FileState] = [:]
        let q = try db.prepare("SELECT id,path,inode,size,mtime,offset,title_kind,title,cwd,first_prompt,first_ts,last_ts,messages FROM files")
        while try q.step() {
            known[q.text(1) ?? ""] = FileState(
                id: q.int64(0), inode: q.int64(2), size: q.int64(3), mtime: q.double(4), offset: q.int64(5),
                titleKind: Int(q.int64(6)), title: q.text(7), cwd: q.text(8), firstPrompt: q.text(9),
                firstTs: q.text(10), lastTs: q.text(11), messages: Int(q.int64(12)))
        }

        // Forget files that no longer exist.
        let foundPaths = Set(found.map(\.url.path))
        let gone = known.filter { !foundPaths.contains($0.key) }
        if !gone.isEmpty {
            try db.exec("BEGIN")
            let delMsg = try db.prepare("DELETE FROM messages WHERE file_id=?")
            let delFile = try db.prepare("DELETE FROM files WHERE id=?")
            for (_, st) in gone {
                delMsg.bind(1, st.id); try delMsg.run()
                delFile.bind(1, st.id); try delFile.run()
            }
            try db.exec("COMMIT")
        }

        // Work list: new files, grown files, replaced/truncated files. Newest first.
        var work: [(Candidate, FileState?)] = []
        for c in found {
            if let st = known[c.url.path] {
                if st.inode == c.inode && st.size == c.size && st.mtime == c.mtime { continue }
            }
            work.append((c, known[c.url.path]))
        }
        work.sort { $0.0.mtime > $1.0.mtime }

        p.phase = .indexing
        p.filesTotal = work.count
        p.bytesTotal = work.reduce(0) { acc, w in
            let start = (w.1 != nil && w.1!.inode == w.0.inode && w.0.size >= w.1!.offset) ? w.1!.offset : 0
            return acc + max(0, w.0.size - start)
        }
        progress(p)

        var lastReport = Date()
        for (c, st) in work {
            if cancelled() { p.phase = .cancelled; progress(p); return }
            p.currentFile = c.url.lastPathComponent
            try indexFile(c, state: st, progress: &p, report: { pp in
                if Date().timeIntervalSince(lastReport) > 0.25 { progress(pp); lastReport = Date() }
            }, cancelled: cancelled)
            p.filesDone += 1
            if Date().timeIntervalSince(lastReport) > 0.25 { progress(p); lastReport = Date() }
        }
        if cancelled() { p.phase = .cancelled; progress(p); return }
        try setMeta("last_run", isoFormatter.string(from: Date()))
        p.phase = .done
        p.finishedAt = Date()
        p.currentFile = nil
        progress(p)
    }

    func indexFile(_ c: Candidate, state: FileState?, progress p: inout IndexProgress,
                   report: (IndexProgress) -> Void, cancelled: () -> Bool) throws {
        var st: FileState
        try db.exec("BEGIN")
        if var existing = state {
            if existing.inode != c.inode || c.size < existing.offset {
                // Replaced or truncated: start over for this file.
                let del = try db.prepare("DELETE FROM messages WHERE file_id=?")
                del.bind(1, existing.id); try del.run()
                existing = FileState(id: existing.id, inode: c.inode, size: 0, mtime: 0, offset: 0, titleKind: 0,
                                     title: nil, cwd: nil, firstPrompt: nil, firstTs: nil, lastTs: nil, messages: 0)
            }
            st = existing
            st.inode = c.inode
        } else {
            let ins = try db.prepare("INSERT INTO files(path,inode,size,mtime,offset,cli_session_id,is_subagent,project_dir,messages) VALUES(?,?,0,0,0,?,?,?,0)")
            ins.bind(1, c.url.path).bind(2, c.inode).bind(3, c.cliSessionId).bind(4, Int64(c.isSubagent ? 1 : 0)).bind(5, c.projectDir)
            try ins.run()
            st = FileState(id: db.lastInsertRowID, inode: c.inode, size: 0, mtime: 0, offset: 0, titleKind: 0,
                           title: nil, cwd: nil, firstPrompt: nil, firstTs: nil, lastTs: nil, messages: 0)
        }

        let insertMsg = try db.prepare("INSERT INTO messages(text, role, file_id, ts) VALUES(?,?,?,?)")
        let updateFile = try db.prepare("UPDATE files SET inode=?,size=?,mtime=?,offset=?,title=?,title_kind=?,cwd=?,first_prompt=?,first_ts=?,last_ts=?,messages=? WHERE id=?")
        func saveState(finished: Bool) throws {
            // Only record size/mtime once the whole file is consumed, so a partial run resumes from offset.
            updateFile.bind(1, st.inode).bind(2, finished ? c.size : -1).bind(3, finished ? c.mtime : 0).bind(4, st.offset)
            updateFile.bind(5, st.title).bind(6, Int64(st.titleKind)).bind(7, st.cwd).bind(8, st.firstPrompt)
            updateFile.bind(9, st.firstTs).bind(10, st.lastTs).bind(11, Int64(st.messages)).bind(12, st.id)
            try updateFile.run()
        }

        guard let fh = try? FileHandle(forReadingFrom: c.url) else {
            try saveState(finished: true)
            try db.exec("COMMIT")
            return
        }
        defer { try? fh.close() }
        try fh.seek(toOffset: UInt64(st.offset))

        let extractor = LineExtractor(settings: settings, isSubagentFile: c.isSubagent)
        var buf = Data()
        var pendingInBatch = 0
        let chunkSize = 8 << 20
        var stoppedEarly = false

        while true {
            if cancelled() { stoppedEarly = true; break }
            let more = try autoreleasepool { () -> Bool in
                guard let chunk = try fh.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
                buf.append(chunk)
                var consumed = 0
                var lines: [Data] = []
                buf.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { return }
                    var start = 0
                    while start < raw.count {
                        guard let nl = memchr(base + start, 0x0A, raw.count - start) else { break }
                        let end = base.distance(to: UnsafeRawPointer(nl))
                        if end > start {
                            let ptr = UnsafeRawBufferPointer(start: base + start, count: end - start)
                            if extractor.wants(ptr) { lines.append(Data(ptr)) }
                        }
                        start = end + 1
                    }
                    consumed = start
                }
                for line in lines {
                    for item in extractor.extract(line, into: &st) {
                        insertMsg.bind(1, item.text).bind(2, item.role).bind(3, st.id).bind(4, item.ts)
                        try insertMsg.run()
                        st.messages += 1
                        p.messagesAdded += 1
                        pendingInBatch += 1
                    }
                }
                if consumed > 0 {
                    st.offset += Int64(consumed)
                    buf.removeSubrange(0..<consumed)
                }
                p.bytesDone += Int64(chunk.count)
                report(p)
                if pendingInBatch > 20_000 {
                    try saveState(finished: false)
                    try db.exec("COMMIT; BEGIN")
                    pendingInBatch = 0
                }
                return true
            }
            if !more { break }
        }
        try saveState(finished: !stoppedEarly && buf.isEmpty)
        try db.exec("COMMIT")
    }

    // MARK: Search

    /// Turns what the user typed into an FTS5 query: words are ANDed, "quoted text" is a phrase,
    /// and the last word matches as a prefix while typing.
    public static func ftsQuery(_ input: String) -> String? {
        var parts: [String] = []
        var rest = input
        var phrases: [String] = []
        while let open = rest.firstIndex(of: "\"") {
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "\"") else { break }
            phrases.append(String(rest[after..<close]))
            rest.removeSubrange(open...close)
            rest.insert(" ", at: open)
        }
        rest = rest.replacingOccurrences(of: "\"", with: " ")
        for ph in phrases where !ph.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("\"" + ph.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
        }
        let words = rest.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (i, w) in words.enumerated() {
            let hasAlnum = w.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            guard hasAlnum else { continue }
            var term = "\"" + w.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let isLast = i == words.count - 1 && !(input.last?.isWhitespace ?? false)
            if isLast && phrases.isEmpty && w.count >= 2 { term += "*" }
            parts.append(term)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public static func search(paths: HelperPaths, query: String, role: SearchRole = .any,
                              order: SearchOrder = .relevance, limit: Int = 600) throws -> [SearchGroup] {
        guard let fts = ftsQuery(query) else { return [] }
        guard FileManager.default.fileExists(atPath: paths.indexDB.path) else { return [] }
        let db = try SQLiteDB(path: paths.indexDB.path, readOnly: true)
        var sql = """
        SELECT rowid, file_id, role, ts, snippet(messages, 0, char(2), char(3), '…', 24), bm25(messages)
        FROM messages WHERE messages MATCH ?1
        """
        if role != .any { sql += " AND role = ?2" }
        sql += order == .relevance ? " ORDER BY rank" : " ORDER BY ts DESC"
        sql += " LIMIT \(limit)"
        let s = try db.prepare(sql)
        s.bind(1, fts)
        if role != .any { s.bind(2, role.rawValue) }
        var hits: [SearchHit] = []
        while try s.step() {
            hits.append(SearchHit(id: s.int64(0), fileId: s.int64(1), role: s.text(2) ?? "", timestamp: s.text(3),
                                  snippet: s.text(4) ?? "", rank: s.double(5)))
        }
        let ids = Array(Set(hits.map(\.fileId)))
        var files: [Int64: IndexedFile] = [:]
        if !ids.isEmpty {
            let f = try db.prepare("SELECT id,path,cli_session_id,is_subagent,project_dir,cwd,title,first_prompt,first_ts,last_ts,messages,size FROM files WHERE id IN (" + ids.map(String.init).joined(separator: ",") + ")")
            while try f.step() {
                let file = IndexedFile(id: f.int64(0), path: f.text(1) ?? "", cliSessionId: f.text(2) ?? "", isSubagent: f.int64(3) != 0,
                                       projectDir: f.text(4) ?? "", cwd: f.text(5), title: f.text(6), firstPrompt: f.text(7),
                                       firstTimestamp: f.text(8), lastTimestamp: f.text(9), messages: Int(f.int64(10)), size: f.int64(11))
                files[file.id] = file
            }
        }
        var groups: [Int64: SearchGroup] = [:]
        var order: [Int64] = []
        for h in hits {
            guard let file = files[h.fileId] else { continue }
            if groups[h.fileId] == nil {
                groups[h.fileId] = SearchGroup(file: file, hits: [], bestRank: h.rank)
                order.append(h.fileId)
            }
            groups[h.fileId]!.hits.append(h)
        }
        return order.compactMap { groups[$0] }
    }

    public static func fullText(paths: HelperPaths, rowid: Int64) -> String? {
        guard let db = try? SQLiteDB(path: paths.indexDB.path, readOnly: true),
              let s = try? db.prepare("SELECT text FROM messages WHERE rowid=?") else { return nil }
        s.bind(1, rowid)
        return (try? s.step()) == true ? s.text(0) : nil
    }

    /// Every indexed transcript, for listing chats that have no desktop session.
    public static func allFiles(paths: HelperPaths) -> [IndexedFile] {
        guard let db = try? SQLiteDB(path: paths.indexDB.path, readOnly: true),
              let f = try? db.prepare("SELECT id,path,cli_session_id,is_subagent,project_dir,cwd,title,first_prompt,first_ts,last_ts,messages,size FROM files WHERE is_subagent=0") else { return [] }
        var out: [IndexedFile] = []
        while (try? f.step()) == true {
            out.append(IndexedFile(id: f.int64(0), path: f.text(1) ?? "", cliSessionId: f.text(2) ?? "", isSubagent: f.int64(3) != 0,
                                   projectDir: f.text(4) ?? "", cwd: f.text(5), title: f.text(6), firstPrompt: f.text(7),
                                   firstTimestamp: f.text(8), lastTimestamp: f.text(9), messages: Int(f.int64(10)), size: f.int64(11)))
        }
        return out
    }
}

/// Decides cheaply which transcript lines are worth parsing, then pulls user/assistant text out of them.
struct LineExtractor {
    let settings: IndexSettings
    let isSubagentFile: Bool

    struct Item {
        let text: String
        let role: String
        let ts: String?
    }

    static let typePrefix = Array("{\"type\":\"".utf8)
    static let typeUser = Array("{\"type\":\"user\"".utf8)
    static let typeAssistant = Array("{\"type\":\"assistant\"".utf8)
    static let titleTypes = ["custom-title", "ai-title", "summary"].map { Array("{\"type\":\"\($0)\"".utf8) }
    static let contentKey = Array("\"content\":".utf8)
    static let attachmentKey = Array("\"attachment\":".utf8)
    static let skipBlocks = ["[{\"type\":\"thinking\"", "[{\"type\":\"redacted_thinking\""].map { Array($0.utf8) }
    static let toolBlocks = ["[{\"type\":\"tool_use\"", "[{\"type\":\"tool_result\"", "[{\"tool_use_id\""].map { Array($0.utf8) }

    static func hasPrefix(_ p: UnsafeRawBufferPointer, _ needle: [UInt8], at offset: Int = 0) -> Bool {
        guard offset + needle.count <= p.count else { return false }
        for (i, b) in needle.enumerated() where p[offset + i] != b { return false }
        return true
    }

    static func find(_ p: UnsafeRawBufferPointer, _ needle: [UInt8], within limit: Int) -> Int? {
        guard let base = p.baseAddress else { return nil }
        let n = min(limit, p.count)
        return needle.withUnsafeBytes { nb -> Int? in
            guard let r = memmem(base, n, nb.baseAddress!, nb.count) else { return nil }
            return base.distance(to: UnsafeRawPointer(r))
        }
    }

    func wants(_ p: UnsafeRawBufferPointer) -> Bool {
        if Self.hasPrefix(p, Self.typePrefix) {
            if Self.hasPrefix(p, Self.typeUser) || Self.hasPrefix(p, Self.typeAssistant) { return true }
            return Self.titleTypes.contains { Self.hasPrefix(p, $0) } && p.count < 64 * 1024
        }
        let window = 4096
        let ci = Self.find(p, Self.contentKey, within: window)
        if let ai = Self.find(p, Self.attachmentKey, within: window), ci == nil || ai < ci! { return false }
        guard let c = ci else { return p.count < 256 * 1024 }
        let after = c + Self.contentKey.count
        if after < p.count, p[after] == 0x22 { return true }   // "content":"string"
        if Self.skipBlocks.contains(where: { Self.hasPrefix(p, $0, at: after) }) { return false }
        if Self.toolBlocks.contains(where: { Self.hasPrefix(p, $0, at: after) }) { return settings.includeToolOutput }
        return true
    }

    func extract(_ line: Data, into st: inout TranscriptIndex.FileState) -> [Item] {
        guard let d = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = d["type"] as? String else { return [] }
        switch type {
        case "custom-title":
            if let t = d["customTitle"] as? String, !t.isEmpty { st.title = t; st.titleKind = 3 }
            return []
        case "ai-title":
            if st.titleKind <= 2, let t = d["aiTitle"] as? String, !t.isEmpty { st.title = t; st.titleKind = 2 }
            return []
        case "summary":
            if st.titleKind <= 1, let t = d["summary"] as? String, !t.isEmpty { st.title = t; st.titleKind = 1 }
            return []
        case "user", "assistant":
            break
        default:
            return []
        }
        if (d["isMeta"] as? Bool) == true || (d["isCompactSummary"] as? Bool) == true { return [] }
        if !isSubagentFile, !settings.includeSubagents, (d["isSidechain"] as? Bool) == true { return [] }
        let ts = d["timestamp"] as? String
        if let ts {
            if st.firstTs == nil { st.firstTs = ts }
            if st.lastTs == nil || ts > st.lastTs! { st.lastTs = ts }
        }
        if st.cwd == nil, let cwd = d["cwd"] as? String, !cwd.isEmpty { st.cwd = cwd }
        guard let msg = d["message"] as? [String: Any] else { return [] }
        var out: [Item] = []
        func add(_ raw: String, _ role: String) {
            var text = role == "tool" ? raw : Self.stripReminders(raw)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if text.utf8.count > 100_000 { text = String(text.prefix(100_000)) }
            if role == "user", st.firstPrompt == nil, !text.hasPrefix("<") {
                st.firstPrompt = String(text.prefix(160)).replacingOccurrences(of: "\n", with: " ")
            }
            out.append(Item(text: text, role: role, ts: ts))
        }
        if let s = msg["content"] as? String {
            add(s, type)
        } else if let blocks = msg["content"] as? [[String: Any]] {
            for b in blocks {
                switch b["type"] as? String {
                case "text":
                    if let t = b["text"] as? String { add(t, type) }
                case "tool_use" where settings.includeToolOutput:
                    let name = b["name"] as? String ?? "tool"
                    var input = ""
                    if let i = b["input"], let data = try? JSONSerialization.data(withJSONObject: i, options: [.withoutEscapingSlashes]) {
                        input = String(decoding: data.prefix(4000), as: UTF8.self)
                    }
                    add("[\(name)] " + input, "tool")
                case "tool_result" where settings.includeToolOutput:
                    if let s = b["content"] as? String { add(String(s.prefix(8000)), "tool") }
                    else if let arr = b["content"] as? [[String: Any]] {
                        let joined = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
                        add(String(joined.prefix(8000)), "tool")
                    }
                default:
                    break
                }
            }
        }
        return out
    }

    static func stripReminders(_ s: String) -> String {
        guard s.contains("<system-reminder>") else { return s }
        var out = ""
        var rest = Substring(s)
        while let open = rest.range(of: "<system-reminder>") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "</system-reminder>") else { rest = ""; break }
            rest = rest[close.upperBound...]
        }
        out += rest
        return out
    }
}
