import Foundation
import HelperCore

/// `ClaudeHelper --cli selftest`: runs the write logic and the indexer against made-up fixtures in a temp folder.
/// Never touches the real Claude folders. CI runs this on every push.
enum SelfTest {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "PASS " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    static let fm = FileManager.default

    static func write(_ s: String, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(s.utf8).write(to: url)
    }

    static func setMTime(_ url: URL, _ secondsAgo: TimeInterval) throws {
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-secondsAgo)], ofItemAtPath: url.path)
    }

    static func session(_ uuid: String, title: String, archived: Bool, starred: Bool = false, cli: String? = nil) -> String {
        let cliPart = cli.map { "\"cliSessionId\":\"\($0)\"," } ?? ""
        return "{\"sessionId\":\"local_\(uuid)\",\(cliPart)\"cwd\":\"/tmp/project\",\"createdAt\":1700000000000,"
            + "\"lastActivityAt\":1700000100000,\"isArchived\":\(archived),\"title\":\"\(title)\",\"isStarred\":\(starred),"
            + "\"spawnedFrom\":{\"title\":\"nested title must not change\"},\"cost\":0.30594340000000001}"
    }

    /// Every managed file in a folder, name -> bytes.
    static func contents(_ dir: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where BackupManager.isManagedName(name) {
            out[name] = try? Data(contentsOf: dir.appendingPathComponent(name))
        }
        return out
    }

    static func run() async -> Int32 {
        let base = fm.temporaryDirectory.appendingPathComponent("claudehelper-selftest-" + UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        do {
            try await runAll(base)
        } catch {
            check(false, "unexpected error: \(error.localizedDescription)")
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    static func runAll(_ base: URL) async throws {
        let paths = HelperPaths(sessionsRoot: base.appendingPathComponent("sessions"),
                                claudeConfig: base.appendingPathComponent("config.json"),
                                projectsRoot: base.appendingPathComponent("projects"),
                                dataDir: base.appendingPathComponent("data"))
        check(!paths.isLiveSessionsRoot, "fixture root is not the live folder")

        // JSON patcher
        let original = Data(session("p1", title: "Old", archived: true, cli: "c-p1").utf8)
        let renamed = try TopLevelJSON.patch(original, set: [("title", "New \"quoted\" / text"), ("titleSource", "user")])
        let renamedObj = try JSONSerialization.jsonObject(with: renamed) as! [String: Any]
        check(renamedObj["title"] as? String == "New \"quoted\" / text", "patch sets a top-level key")
        check((renamedObj["spawnedFrom"] as? [String: Any])?["title"] as? String == "nested title must not change", "patch leaves nested keys alone")
        check(String(decoding: renamed, as: UTF8.self).contains("0.30594340000000001"), "patch keeps number formatting")
        check(try TopLevelJSON.patch(original, set: [("isArchived", true)]) == original, "no-op patch returns identical bytes")
        let flipped = try TopLevelJSON.patch(original, set: [("isArchived", false)])
        check(flipped.count == original.count + 1, "flipping isArchived changes one value in place")

        // archived-sessions.idx format
        check(SchemaGuard.parseArchivedIndex(Data("{\"v\":1,\"archived\":[\"local_a\"]}".utf8)).ids == ["local_a"], "idx: valid file parses")
        check(SchemaGuard.parseArchivedIndex(Data("{\"v\":2,\"archived\":[]}".utf8)).problem != nil, "idx: v 2 is refused")
        check(SchemaGuard.parseArchivedIndex(Data("{\"v\":1,\"archived\":[],\"x\":1}".utf8)).problem != nil, "idx: extra key is refused")
        check(String(decoding: try SchemaGuard.encodeArchivedIndex(["local_b", "local_a", "local_b"]), as: UTF8.self)
              == "{\"v\":1,\"archived\":[\"local_a\",\"local_b\"]}", "idx: written sorted, compact, no newline")

        // Two account folders
        let a = paths.sessionsRoot.appendingPathComponent("acct-a/org-1")
        let b = paths.sessionsRoot.appendingPathComponent("acct-b/org-1")
        try write(session("s1", title: "Shared older", archived: false, cli: "c1"), b.appendingPathComponent("local_s1.json"))
        try write(session("s1", title: "Shared newer", archived: false, cli: "c1"), a.appendingPathComponent("local_s1.json"))
        try setMTime(b.appendingPathComponent("local_s1.json"), 3600)
        try write(session("s2", title: "Archived in A", archived: true, cli: "c2"), a.appendingPathComponent("local_s2.json"))
        try write(session("s3", title: "Only in B", archived: false, starred: true, cli: "c3"), b.appendingPathComponent("local_s3.json"))
        try write(session("s4", title: "Deleted in A", archived: false, cli: "c4"), b.appendingPathComponent("local_s4.json"))
        try write("1700000000000", a.appendingPathComponent("deleted_s4"))
        try write("{\"v\":1,\"archived\":[\"local_s2\"]}", a.appendingPathComponent("archived-sessions.idx"))
        try write("{\"v\":1,\"archived\":[]}", b.appendingPathComponent("archived-sessions.idx"))
        try write("{\"keep\":true}", b.appendingPathComponent("scheduled-tasks.json"))
        try write("{}", b.appendingPathComponent("backlog/tasks.json"))

        let snap = SessionScanner.scan(paths: paths)
        check(snap.folders.count == 2 && snap.allSessions.count == 5, "scanner finds 2 folders and 5 session files")
        check(snap.allSessions.allSatisfy { $0.problems.isEmpty }, "fixtures pass the schema guard")

        // Restore one archived chat
        let restore = Planner.plan(.edits([SessionEdit(folderId: "acct-a/org-1", sessionId: "local_s2", isArchived: false)]), paths: paths)
        check(restore.canApply && restore.changes.count == 2, "restore plan: session file + archived list")
        let before = contents(a)
        let r1 = try Executor.apply(restore, paths: paths)
        let after = contents(a)
        let changed = Set(after.keys).union(before.keys).filter { after[$0] != before[$0] }
        check(changed == ["local_s2.json", "archived-sessions.idx"], "restore changed exactly two files")
        check(SchemaGuard.parseArchivedIndex(after["archived-sessions.idx"]!).ids == [], "restored chat left the archived list")
        check(fm.fileExists(atPath: r1.backup.snapshotURL.path), "restore made a backup first")

        // Archive a pinned chat: it gets unpinned too
        let arch = Planner.plan(.edits([SessionEdit(folderId: "acct-b/org-1", sessionId: "local_s3", isArchived: true)]), paths: paths)
        check(arch.changes.first?.summary.contains("unpin") == true, "archiving a pinned chat also unpins it")

        // Sync A <-> B
        let preA = contents(a), preB = contents(b)
        let sync = Planner.plan(.sync(folderIds: ["acct-a/org-1", "acct-b/org-1"]), paths: paths)
        let kinds = Dictionary(grouping: sync.changes, by: { $0.kind.rawValue }).mapValues(\.count)
        check(kinds["update"] == 1 && kinds["add"] == 2 && kinds["removeDeleted"] == 1 && kinds["addMarker"] == 1,
              "sync plan: 1 update, 2 adds, 1 deleted copy moved out, 1 marker (got \(kinds))")
        let rs = try Executor.apply(sync, paths: paths)
        let postA = contents(a), postB = contents(b)
        check(postA == postB, "after sync both folders hold identical files")
        check(postA["local_s4.json"] == nil, "deleted chat was not brought back")
        check(fm.fileExists(atPath: rs.backup.removedDir.appendingPathComponent("acct-b/org-1/local_s4.json").path), "deleted copy moved into the backup")
        check(String(decoding: postA["local_s1.json"]!, as: UTF8.self).contains("Shared newer"), "newest copy won")
        check((try? Data(contentsOf: b.appendingPathComponent("scheduled-tasks.json"))) == Data("{\"keep\":true}".utf8)
              && fm.fileExists(atPath: b.appendingPathComponent("backlog/tasks.json").path), "unmanaged files untouched")
        check(Planner.plan(.sync(folderIds: ["acct-a/org-1", "acct-b/org-1"]), paths: paths).changes.isEmpty, "second sync has nothing to do")

        // Restore the sync backup
        let back = Planner.plan(.restoreBackup(rs.backup), paths: paths)
        _ = try Executor.apply(back, paths: paths)
        check(contents(a) == preA && contents(b) == preB, "restoring the backup brings both folders back exactly")

        // Schema guard refuses broken files
        try write(session("bad", title: "No cli id", archived: false), a.appendingPathComponent("local_bad.json"))
        let bad = Planner.plan(.edits([SessionEdit(folderId: "acct-a/org-1", sessionId: "local_bad", isStarred: true)]), paths: paths)
        check(!bad.canApply && bad.problems.contains { $0.message.contains("cliSessionId") }, "guard: missing cliSessionId blocks the write")
        var threw = false
        do { _ = try Executor.apply(bad, paths: paths) } catch { threw = true }
        check(threw, "guard: executor refuses a plan with problems")
        try write("{\"v\":2,\"archived\":[]}", b.appendingPathComponent("archived-sessions.idx"))
        check(!Planner.plan(.sync(folderIds: ["acct-a/org-1", "acct-b/org-1"]), paths: paths).canApply, "guard: bad archived list blocks sync")

        // Allowlist
        check(Executor.isAllowedTarget(a.appendingPathComponent("local_x.json"), paths: paths), "allowlist: session file allowed")
        check(!Executor.isAllowedTarget(b.appendingPathComponent("backlog/tasks.json"), paths: paths), "allowlist: backlog refused")
        check(!Executor.isAllowedTarget(b.appendingPathComponent("scheduled-tasks.json"), paths: paths), "allowlist: scheduled-tasks.json refused")
        check(!Executor.isAllowedTarget(paths.projectsRoot.appendingPathComponent("p/local_x.json"), paths: paths), "allowlist: transcripts refused")
        check(!Executor.isAllowedTarget(a.appendingPathComponent("../../acct-b/org-1/local_x.json"), paths: paths), "allowlist: .. refused")

        // Search index
        let transcript = paths.projectsRoot.appendingPathComponent("-tmp-project/c1.jsonl")
        let lines = [
            #"{"type":"custom-title","customTitle":"Fixture chat","sessionId":"c1"}"#,
            #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"please fix the zebracorn parser"},"uuid":"u1","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp/project"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"secret thoughts quokka"}]},"type":"assistant","uuid":"a0","timestamp":"2026-01-01T10:00:01.000Z"}"#,
            #"{"parentUuid":"u1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Fixed the parser <system-reminder>hidden wombat</system-reminder> done"}]},"type":"assistant","uuid":"a1","timestamp":"2026-01-01T10:00:02.000Z"}"#,
            #"{"parentUuid":"a1","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"tool output platypus"}]},"uuid":"u2","timestamp":"2026-01-01T10:00:03.000Z"}"#,
        ]
        try write(lines.joined(separator: "\n") + "\n", transcript)
        let index = try TranscriptIndex(paths: paths, settings: IndexSettings())
        try index.update(progress: { _ in }, cancelled: { false })
        func hits(_ q: String) throws -> Int { try TranscriptIndex.search(paths: paths, query: q).reduce(0) { $0 + $1.hits.count } }
        check(try hits("zebracorn") == 1, "index: user text found")
        check(try hits("zebra") == 1, "index: last word matches as a prefix")
        check(try hits("parser fixed") == 1, "index: words are ANDed")
        check(try hits("quokka") == 0, "index: thinking skipped")
        check(try hits("wombat") == 0, "index: system reminders stripped")
        check(try hits("platypus") == 0, "index: tool output off by default")
        check((try TranscriptIndex.search(paths: paths, query: "zebracorn")).first?.file.title == "Fixture chat", "index: custom title picked up")
        let fh = try FileHandle(forWritingTo: transcript)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data((#"{"parentUuid":"u2","isSidechain":false,"type":"user","message":{"role":"user","content":"appended narwhal line"},"uuid":"u3","timestamp":"2026-01-01T10:01:00.000Z"}"# + "\n").utf8))
        try fh.close()
        try index.update(progress: { _ in }, cancelled: { false })
        check(try hits("narwhal") == 1 && (try hits("zebracorn")) == 1, "index: appended line indexed once, old lines not duplicated")
        check(TranscriptIndex.ftsQuery("\"exact phrase\" more") == "\"exact phrase\" \"more\"", "query: phrase plus word")
    }
}
