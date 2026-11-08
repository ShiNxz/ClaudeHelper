import CryptoKit
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
                                dataDir: base.appendingPathComponent("data"),
                                claudeLog: base.appendingPathComponent("main.log"))
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
            #"{"type":"session-owner","accountUuid":"11111111-2222-3333-4444-555555555555","organizationUuid":"org","sessionId":"c1"}"#,
            #"{"type":"custom-title","customTitle":"Fixture chat","sessionId":"c1"}"#,
            ##"{"parentUuid":null,"isSidechain":false,"type":"user","isMeta":true,"message":{"role":"user","content":"# userEmail\nThe user's email address is someone.test@example.com. Use it only to identify the user."},"uuid":"m0","timestamp":"2026-01-01T09:59:00.000Z"}"##,
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
        check(TranscriptIndex.accountEmails(paths: paths) == ["11111111-2222-3333-4444-555555555555": "someone.test@example.com"], "index: account id linked to its email")
        check(try hits("someone") == 0, "index: meta context lines not indexed as messages")
        let fh = try FileHandle(forWritingTo: transcript)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data((#"{"parentUuid":"u2","isSidechain":false,"type":"user","message":{"role":"user","content":"appended narwhal line"},"uuid":"u3","timestamp":"2026-01-01T10:01:00.000Z"}"# + "\n").utf8))
        try fh.close()
        try index.update(progress: { _ in }, cancelled: { false })
        check(try hits("narwhal") == 1 && (try hits("zebracorn")) == 1, "index: appended line indexed once, old lines not duplicated")
        check(TranscriptIndex.ftsQuery("\"exact phrase\" more") == "\"exact phrase\" \"more\"", "query: phrase plus word")

        try await profileTests(paths)
        try copyTests(base)
        try await freshLoginMergeTest(base)
        updaterTests()
        try pullTests(base)
        try await carryTest(base)
        try usageTests(base)
    }

    /// Update checks: version order and the Ed25519 signature every update must carry.
    static func updaterTests() {
        check(Updater.isNewer("0.10.0", than: "0.9.9") && Updater.isNewer("v1.0", than: "0.9") && Updater.isNewer("0.4.1", than: "0.4"),
              "update: newer versions recognized")
        check(!Updater.isNewer("0.4.0", than: "0.4.0") && !Updater.isNewer("0.3.9", than: "0.4.0"), "update: same or older is not offered")
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let data = Data("Relay-0.5.0.dmg contents".utf8)
        let sig = (try? key.signature(for: data))?.base64EncodedString() ?? ""
        check(Updater.verify(data, signature: sig, publicKey: pub), "update: a correctly signed download passes")
        check(!Updater.verify(data + Data([0]), signature: sig, publicKey: pub), "update: a changed download is refused")
        check(!Updater.verify(data, signature: sig), "update: a download signed with another key is refused")
        check(Data(base64Encoded: Updater.publicKey)?.count == 32, "update: the built-in public key is an Ed25519 key")
    }

    /// Pull: chosen chats copied into the signed-in account's chat lists, nothing else.
    static func pullTests(_ base: URL) throws {
        let paths = HelperPaths(sessionsRoot: base.appendingPathComponent("pull-sessions"),
                                claudeConfig: base.appendingPathComponent("pull/config.json"),
                                projectsRoot: base.appendingPathComponent("projects"),
                                dataDir: base.appendingPathComponent("pull-data"),
                                claudeLog: base.appendingPathComponent("pull.log"))
        let other = paths.sessionsRoot.appendingPathComponent("acct-o/org-1")
        let me1 = paths.sessionsRoot.appendingPathComponent("acct-m/org-1"), me2 = paths.sessionsRoot.appendingPathComponent("acct-m/org-2")
        try write(session("p1", title: "Wanted", archived: false, cli: "kp1"), other.appendingPathComponent("local_p1.json"))
        try write(session("p2", title: "Wanted archived", archived: true, cli: "kp2"), other.appendingPathComponent("local_p2.json"))
        try write(session("p3", title: "Not picked", archived: false, cli: "kp3"), other.appendingPathComponent("local_p3.json"))
        try write(session("p4", title: "Newer here", archived: false, cli: "kp4"), other.appendingPathComponent("local_p4.json"))
        try setMTime(other.appendingPathComponent("local_p4.json"), 3600)
        try write(session("p4", title: "Newer here, mine", archived: false, cli: "kp4"), me1.appendingPathComponent("local_p4.json"))
        try write("1", me2.appendingPathComponent("deleted_p1"))
        try write("{\"v\":1,\"archived\":[]}", me1.appendingPathComponent("archived-sessions.idx"))
        let otherBefore = contents(other)
        let items = ["local_p1", "local_p2", "local_p4"].map { PullItem(folderId: "acct-o/org-1", sessionId: $0) }
        let plan = Planner.plan(.pull(items: items, targetFolderIds: ["acct-m/org-1", "acct-m/org-2"]), paths: paths)
        check(plan.canApply && !plan.changes.contains { $0.folder.accountId == "acct-o" }, "pull: plan never writes the account pulled from")
        _ = try Executor.apply(plan, paths: paths)
        let m1 = contents(me1), m2 = contents(me2)
        check(contents(other) == otherBefore, "pull: source folder unchanged")
        check(m1["local_p1.json"] != nil && m2["local_p1.json"] != nil && m1["local_p2.json"] != nil, "pull: picked chats added to every chat list of the account")
        check(m1["local_p3.json"] == nil && m2["local_p3.json"] == nil, "pull: chats that were not picked stay out")
        check(String(decoding: m1["local_p4.json"]!, as: UTF8.self).contains("mine"), "pull: a newer copy already in the account is kept")
        check(m2["deleted_p1"] == nil, "pull: a deleted marker for a pulled chat is moved to the backup")
        check(SchemaGuard.parseArchivedIndex(m1["archived-sessions.idx"]!).ids == ["local_p2"], "pull: archived list follows the pulled chats")
        check(Planner.plan(.pull(items: items, targetFolderIds: ["acct-m/org-1", "acct-m/org-2"]), paths: paths).changes.isEmpty,
              "pull: pulling again has nothing to do")
        check(!Planner.plan(.pull(items: items, targetFolderIds: []), paths: paths).problems.isEmpty, "pull: no chat list to pull into is refused")
    }

    /// Switching with chats to bring along: they are copied while Claude is closed, before the login swap.
    static func carryTest(_ base: URL) async throws {
        let paths = HelperPaths(sessionsRoot: base.appendingPathComponent("carry-sessions"),
                                claudeConfig: base.appendingPathComponent("carry/config.json"),
                                projectsRoot: base.appendingPathComponent("projects"),
                                dataDir: base.appendingPathComponent("carry-data"),
                                claudeLog: base.appendingPathComponent("carry.log"))
        let from = paths.sessionsRoot.appendingPathComponent("acct-f/org-1"), to = paths.sessionsRoot.appendingPathComponent("acct-t/org-1")
        try write(session("w1", title: "Working on this", archived: false, cli: "kw1"), from.appendingPathComponent("local_w1.json"))
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        try fakeLogin(paths, account: "acct-t", token: "T", marker: "marker-t")
        let target = try LoginProfiles.saveCurrent(name: "Target", paths: paths)
        try fakeLogin(paths, account: "acct-f", token: "F", marker: "marker-f")
        let carry = WriteIntent.pull(items: [PullItem(folderId: "acct-f/org-1", sessionId: "local_w1")], targetFolderIds: ["acct-t/org-1"])
        let r = try await LoginProfiles.switchTo(target, syncFolderIds: nil, carry: carry, paths: paths, step: { _ in })
        check(r.switched && fm.fileExists(atPath: to.appendingPathComponent("local_w1.json").path) && r.carryBackup != nil,
              "switch: chats brought along to the new account, backed up first")
        check(AccountHistory.events(paths: paths).last?.kind == .signedIn(account: "acct-t", wasSignedOut: false),
              "switch: the new account is noted in the helper's account history")
        check(LoginProfiles.loginSwapDates(paths: paths).count == 1, "switch: login swap time read back from the backup name")
    }

    static func usageTests(_ base: URL) throws {
        let json = #"{"version":2,"samples":[{"org":"org-x","t":1700000000000,"u":{"fh":10,"sd":40}},{"org":"org-y","t":1700000600000,"u":{"sd":7}},{"org":"org-x","t":1700001200000,"u":{"fh":12.6,"sd":41,"xu":0}},{"bad":1}]}"#
        let samples = PlanUsage.parseSamples(Data(json.utf8))
        check(samples.count == 3 && samples[1].fiveHour == nil && samples[2].fiveHour == 13 && samples[2].date == Date(timeIntervalSince1970: 1_700_001_200),
              "usage: history parsed, missing 5-hour window kept as none, percent rounded")

        // Who was signed in when: x until a swap the log did not show, then y.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func sample(_ org: String, _ minutes: Double, _ fh: Int?, _ sd: Int?) -> UsageSample {
            UsageSample(org: org, date: t0.addingTimeInterval(minutes * 60), fiveHour: fh, sevenDay: sd)
        }
        let events = [LoginEvent(date: t0.addingTimeInterval(-60), kind: .signedIn(account: "acct-x", wasSignedOut: true)),
                      LoginEvent(date: t0.addingTimeInterval(100 * 60), kind: .signedOut(from: nil)),
                      LoginEvent(date: t0.addingTimeInterval(300 * 60), kind: .signedIn(account: "acct-y", wasSignedOut: true))]
        let list = [sample("org-x", 0, 5, 20), sample("org-x", 30, 8, 22), sample("org-x", 150, 30, 50), sample("org-y", 301, nil, 70)]
        let attributed = PlanUsage.attribute(list, events: events)
        check(attributed.map(\.account) == ["acct-x", "acct-x", "acct-x", "acct-y"],
              "usage: samples matched by who was signed in, and by organization after an unlogged swap")

        // Five-hour window: reset by five hours after the window's first sample; weekly anchor from a drop.
        let x = [sample("org-x", 0, 0, 90), sample("org-x", 30, 10, 95), sample("org-x", 60, 20, 2), sample("org-x", 90, 40, 5)]
        let u = PlanUsage.accountUsage(samples: x, events: [events[0]])["acct-x"]!
        check(u.fiveHour == 40 && u.fiveHourResetsBy == t0.addingTimeInterval(30 * 60 + 5 * 3600), "usage: 5-hour reset bound from the window's first sample")
        check(u.weekAnchor == t0.addingTimeInterval(60 * 60), "usage: weekly reset found where the weekly figure dropped")
        let later = t0.addingTimeInterval(90 * 60)
        check(u.fiveHourNow(later.addingTimeInterval(60)) == 40 && u.fiveHourNow(later.addingTimeInterval(6 * 3600)) == 0, "usage: 5-hour use counts as 0 once its window passed")
        check(u.sevenDayNow(later.addingTimeInterval(86400)) == 5 && u.sevenDayNow(t0.addingTimeInterval(60 * 60 + 7 * 86400 + 1)) == 0,
              "usage: weekly use counts as 0 after the next weekly reset")
        check(u.weekReset(later) == t0.addingTimeInterval(60 * 60 + 7 * 86400), "usage: next weekly reset is a week after the last one")

        // Auto-switch: the signed-in account at the threshold, the least used other account picked.
        func acct(_ id: String, _ fh: Int, _ sd: Int) -> AutoSwitch.Candidate {
            AutoSwitch.Candidate(accountId: id, usage: AccountUsage(accountId: id, org: "o-" + id, sampledAt: Date(), fiveHour: fh, sevenDay: sd,
                                                                    fiveHourResetsBy: nil, weekAnchor: nil))
        }
        check(AutoSwitch.reason(acct("a", 10, 96).usage!, threshold: 95)?.contains("weekly") == true
              && AutoSwitch.reason(acct("a", 96, 10).usage!, threshold: 95)?.contains("5-hour") == true
              && AutoSwitch.reason(acct("a", 94, 94).usage!, threshold: 95) == nil, "auto-switch: triggers on either limit at the threshold")
        let pick = AutoSwitch.pick([acct("b", 0, 60), acct("c", 99, 10), acct("d", 20, 30), AutoSwitch.Candidate(accountId: "e", usage: nil)], threshold: 95)
        check(pick?.accountId == "d", "auto-switch: lowest weekly use under the threshold on both limits wins")
        check(AutoSwitch.pick([acct("c", 99, 10), AutoSwitch.Candidate(accountId: "e", usage: nil)], threshold: 95)?.accountId == "e",
              "auto-switch: an account with no usage data is tried last")
        check(AutoSwitch.pick([acct("c", 99, 10)], threshold: 95) == nil, "auto-switch: no pick when every account is over")

        // Mid-turn: an unanswered prompt or tool result, or a running tool call. Finished: end_turn, an error, an interrupt.
        let tdir = base.appendingPathComponent("turns")
        func turn(_ name: String, _ lines: [String]) throws -> Bool {
            let url = tdir.appendingPathComponent(name + ".jsonl")
            try write(lines.joined(separator: "\n") + "\n", url)
            return ChatActivity.endsMidTurn(url)
        }
        let prompt = #"{"type":"user","message":{"role":"user","content":"do it"}}"#
        let toolUse = #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}]}}"#
        let toolResult = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#
        let done = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}"#
        let limit = #"{"type":"assistant","error":"rate_limit","isApiErrorMessage":true,"message":{"stop_reason":"stop_sequence","content":[{"type":"text","text":"limit"}]}}"#
        let interrupted = #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        let summary = #"{"type":"system","subtype":"stop_hook_summary"}"#
        check(try turn("a", [prompt]) && turn("b", [prompt, toolUse]) && turn("c", [prompt, toolUse, toolResult]),
              "activity: unanswered prompt, running tool and tool result are mid-turn")
        check(try !turn("d", [prompt, toolUse, toolResult, done, summary]) && !turn("e", [prompt, limit]) && !turn("f", [prompt, toolUse, interrupted]),
              "activity: finished, limited and interrupted turns are not")
        check(ChatActivity.busyTranscripts(paths: HelperPaths(sessionsRoot: base, claudeConfig: base.appendingPathComponent("x.json"), projectsRoot: base,
                                                               dataDir: base, claudeLog: base.appendingPathComponent("x.log")),
                                           among: ["b", "d", "zzz"]) == ["b"], "activity: only the given chats that are mid-turn")

        // Rotated logs are read too, and only new lines are parsed again.
        let logDir = base.appendingPathComponent("logs")
        let lp = HelperPaths(sessionsRoot: base, claudeConfig: base.appendingPathComponent("x.json"), projectsRoot: base,
                             dataDir: base.appendingPathComponent("logdata"), claudeLog: logDir.appendingPathComponent("main.log"))
        try write(logLine(t0, "Login-state transition (loggedOut: true \u{2192} false, uuid: <none> \u{2192} aaaaaaaa-0000-0000-0000-000000000001)"),
                  logDir.appendingPathComponent("main1.log"))
        try write(logLine(t0.addingTimeInterval(60), "Login-state transition (loggedOut: true \u{2192} false, uuid: <none> \u{2192} bbbbbbbb-0000-0000-0000-000000000002)"),
                  lp.claudeLog)
        try write("x", logDir.appendingPathComponent("other.log"))
        check(ClaudeLog.allLoginEvents(paths: lp).count == 2, "log: rotated copies are read")
        try appendLog(lp, logLine(t0.addingTimeInterval(120), "Login-state transition (loggedOut: false \u{2192} true, uuid: bbbbbbbb-0000-0000-0000-000000000002 \u{2192} <none>), clearing oauth cache"))
        check(ClaudeLog.allLoginEvents(paths: lp).count == 3 && ClaudeLog.allLoginEvents(paths: lp).last?.isSignOut == true, "log: new lines picked up")
    }

    /// One-way copy from one account (two organizations) into two others.
    static func copyTests(_ base: URL) throws {
        let paths = HelperPaths(sessionsRoot: base.appendingPathComponent("copy-sessions"),
                                claudeConfig: base.appendingPathComponent("copy-config.json"),
                                projectsRoot: base.appendingPathComponent("projects"),
                                dataDir: base.appendingPathComponent("copy-data"),
                                claudeLog: base.appendingPathComponent("copy.log"))
        let src1 = paths.sessionsRoot.appendingPathComponent("acct-s/org-1")
        let src2 = paths.sessionsRoot.appendingPathComponent("acct-s/org-2")
        let t = paths.sessionsRoot.appendingPathComponent("acct-t/org-1")
        let u = paths.sessionsRoot.appendingPathComponent("acct-u/org-1")
        try write(session("c1", title: "Shared", archived: false, cli: "k1"), src1.appendingPathComponent("local_c1.json"))
        try write(session("c2", title: "Archived one", archived: true, cli: "k2"), src1.appendingPathComponent("local_c2.json"))
        try write(session("c3", title: "Deleted in source", archived: false, cli: "k3"), src1.appendingPathComponent("local_c3.json"))
        try write("1", src1.appendingPathComponent("deleted_c3"))
        try write(session("c4", title: "Other org", archived: false, cli: "k4"), src2.appendingPathComponent("local_c4.json"))
        try write("{\"v\":1,\"archived\":[\"local_c2\"]}", src1.appendingPathComponent("archived-sessions.idx"))
        try write(session("c1", title: "Shared older", archived: false, cli: "k1"), t.appendingPathComponent("local_c1.json"))
        try setMTime(t.appendingPathComponent("local_c1.json"), 3600)
        try write(session("c5", title: "Own chat", archived: false, cli: "k5"), t.appendingPathComponent("local_c5.json"))
        try write("1", t.appendingPathComponent("deleted_c2"))
        try write("{\"v\":1,\"archived\":[]}", t.appendingPathComponent("archived-sessions.idx"))
        try write(session("c1", title: "Shared newer here", archived: false, cli: "k1"), u.appendingPathComponent("local_c1.json"))
        try setMTime(src1.appendingPathComponent("local_c1.json"), 60)
        try write("{\"v\":1,\"archived\":[]}", u.appendingPathComponent("archived-sessions.idx"))

        let srcBefore1 = contents(src1), srcBefore2 = contents(src2)
        let plan = Planner.plan(.copy(sourceFolderIds: ["acct-s/org-1", "acct-s/org-2"], targetFolderIds: ["acct-t/org-1", "acct-u/org-1"]), paths: paths)
        check(plan.canApply && !plan.changes.contains { $0.folder.accountId == "acct-s" }, "copy: plan never writes the source account")
        _ = try Executor.apply(plan, paths: paths)
        let tAfter = contents(t), uAfter = contents(u)
        check(contents(src1) == srcBefore1 && contents(src2) == srcBefore2, "copy: source folders unchanged")
        check(String(decoding: tAfter["local_c1.json"]!, as: UTF8.self).contains("\"Shared\"") && tAfter["local_c4.json"] != nil,
              "copy: newer source copy updates, chats from every source org are added")
        check(tAfter["local_c2.json"] == nil && tAfter["local_c3.json"] == nil, "copy: chats deleted in the target or the source are not copied")
        check(tAfter["local_c5.json"] != nil, "copy: the target's own chats stay")
        check(String(decoding: uAfter["local_c1.json"]!, as: UTF8.self).contains("newer here"), "copy: a newer copy in the target is kept")
        check(SchemaGuard.parseArchivedIndex(uAfter["archived-sessions.idx"]!).ids == ["local_c2"], "copy: archived list follows the copied chats")
        check(Planner.plan(.copy(sourceFolderIds: ["acct-s/org-1", "acct-s/org-2"], targetFolderIds: ["acct-t/org-1", "acct-u/org-1"]), paths: paths).changes.isEmpty,
              "copy: a second copy has nothing to do")
    }

    /// Log In and Save / Add Another Account merge chats first when that option is on.
    static func freshLoginMergeTest(_ base: URL) async throws {
        let paths = HelperPaths(sessionsRoot: base.appendingPathComponent("copy-sessions"),
                                claudeConfig: base.appendingPathComponent("fresh/config.json"),
                                projectsRoot: base.appendingPathComponent("projects"),
                                dataDir: base.appendingPathComponent("copy-data"),
                                claudeLog: base.appendingPathComponent("fresh.log"))
        try write(#"{"locale":"en"}"#, paths.claudeConfig)
        let t = paths.sessionsRoot.appendingPathComponent("acct-t/org-1"), u = paths.sessionsRoot.appendingPathComponent("acct-u/org-1")
        try write(session("n1", title: "Made just before leaving", archived: false, cli: "kn1"), t.appendingPathComponent("local_n1.json"))
        let r = try await LoginProfiles.prepareFreshLogin(paths: paths, syncFolderIds: ["acct-t/org-1", "acct-u/org-1"], step: { _ in })
        check(fm.fileExists(atPath: u.appendingPathComponent("local_n1.json").path) && r.syncBackup != nil,
              "log in and save: chats merged before signing out")
        check(contents(t) == contents(u), "log in and save: both accounts hold the same chats afterwards")
    }

    static func sqlite(_ db: URL, _ sql: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db.path, sql]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fake login: a config.json with made-up token strings and a cookie database with marker rows.
    static func fakeLogin(_ paths: HelperPaths, account: String, token: String, marker: String, v1: Bool = true, locale: String = "en", expiresInDays: Double = 30) throws {
        var config = "{\"locale\":\"\(locale)\","
        if v1 { config += "\"oauth:tokenCache\":\"v1-\(token)\"," }
        config += "\"oauth:tokenCacheV2\":\"v2-\(token)\",\"lastKnownAccountUuid\":\"\(account)\",\"windowState\":{\"x\":1}}"
        try write(config, paths.claudeConfig)
        let cookies = paths.claudeDir.appendingPathComponent("Cookies")
        try? fm.removeItem(at: cookies)
        let expires = Int64((Date().timeIntervalSince1970 + expiresInDays * 86400 + 11_644_473_600) * 1_000_000)
        _ = try sqlite(cookies, "CREATE TABLE cookies(host_key TEXT, name TEXT, expires_utc INTEGER, encrypted_value BLOB);"
            + "INSERT INTO cookies VALUES('.claude.ai','sessionKey',\(expires),x'763130');"
            + "INSERT INTO cookies VALUES('.claude.ai','\(marker)',\(expires),x'763130');")
    }

    static func profileTests(_ paths: HelperPaths) async throws {
        let j = Data(#"{"a":1,"b":"x","c":[1,2],"d":{"e":1}}"#.utf8)
        check(String(decoding: try TopLevelJSON.remove(j, keys: ["b"]), as: UTF8.self) == #"{"a":1,"c":[1,2],"d":{"e":1}}"#, "json remove: middle key")
        check(String(decoding: try TopLevelJSON.remove(j, keys: ["d"]), as: UTF8.self) == #"{"a":1,"b":"x","c":[1,2]}"#, "json remove: last key")
        check(String(decoding: try TopLevelJSON.remove(j, keys: ["a"]), as: UTF8.self) == #"{"b":"x","c":[1,2],"d":{"e":1}}"#, "json remove: first key")
        check(!paths.isLiveClaudeDir, "profile fixtures are not the live Claude folder")

        let cookies = paths.claudeDir.appendingPathComponent("Cookies")
        try fakeLogin(paths, account: "acct-a", token: "A", marker: "marker-a")
        let work = try LoginProfiles.saveCurrent(name: "Work", paths: paths)
        let workDir = paths.profilesDir.appendingPathComponent(work.id)
        let dirPerms = (try fm.attributesOfItem(atPath: workDir.path)[.posixPermissions] as? NSNumber)?.intValue
        let filePerms = (try fm.attributesOfItem(atPath: workDir.appendingPathComponent("auth.json").path)[.posixPermissions] as? NSNumber)?.intValue
        check(work.accountId == "acct-a" && dirPerms == 0o700 && filePerms == 0o600, "save: profile stored with 0700 folder and 0600 files")
        check(work.sessionExpires.map { $0 > Date() } == true, "save: session expiry read from the cookie metadata")

        try fakeLogin(paths, account: "acct-b", token: "B", marker: "marker-b", locale: "he")
        let personal = try LoginProfiles.saveCurrent(name: "Personal", paths: paths)
        check(LoginProfiles.list(paths: paths).count == 2, "save: two profiles")
        check(try LoginProfiles.saveCurrent(name: "Personal again", paths: paths).id == personal.id, "save: same account updates its profile")

        // Claude refreshes the current account's tokens before the switch.
        try write(#"{"locale":"he","oauth:tokenCache":"v1-B2","oauth:tokenCacheV2":"v2-B2","lastKnownAccountUuid":"acct-b","windowState":{"x":2}}"#, paths.claudeConfig)
        _ = try sqlite(cookies, "INSERT INTO cookies VALUES('.claude.ai','marker-b2',0,x'763130');")

        let r = try await LoginProfiles.switchTo(work, syncFolderIds: nil, paths: paths, step: { _ in })
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeConfig)) as! [String: Any]
        check(config["lastKnownAccountUuid"] as? String == "acct-a" && config["oauth:tokenCacheV2"] as? String == "v2-A"
              && config["oauth:tokenCache"] as? String == "v1-A", "switch: login keys replaced")
        check(config["locale"] as? String == "he" && (config["windowState"] as? [String: Any])?["x"] as? Int == 2, "switch: other config keys untouched")
        let markerA = try sqlite(cookies, "SELECT count(*) FROM cookies WHERE name='marker-a'")
        let markerB = try sqlite(cookies, "SELECT count(*) FROM cookies WHERE name LIKE 'marker-b%'")
        check(markerA == "1" && markerB == "0", "switch: cookie database swapped")
        let personalDir = paths.profilesDir.appendingPathComponent(personal.id)
        let savedAuth = try JSONSerialization.jsonObject(with: Data(contentsOf: personalDir.appendingPathComponent("auth.json"))) as! [String: Any]
        let refreshedCookie = try sqlite(personalDir.appendingPathComponent("Cookies"), "SELECT count(*) FROM cookies WHERE name='marker-b2'")
        check(savedAuth["oauth:tokenCacheV2"] as? String == "v2-B2" && refreshedCookie == "1",
              "switch: outgoing account re-saved with its refreshed login first")
        check(r.loginBackup.map { fm.fileExists(atPath: $0.appendingPathComponent("config.json").path) && fm.fileExists(atPath: $0.appendingPathComponent("Cookies").path) } == true,
              "switch: previous login files backed up")

        // A profile saved without the older token key: the key must not linger from the other account.
        try fakeLogin(paths, account: "acct-c", token: "C", marker: "marker-c", v1: false)
        let noV1 = try LoginProfiles.saveCurrent(name: "No V1", paths: paths)
        _ = try await LoginProfiles.switchTo(work, syncFolderIds: nil, paths: paths, step: { _ in })
        _ = try await LoginProfiles.switchTo(noV1, syncFolderIds: nil, paths: paths, step: { _ in })
        let config2 = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeConfig)) as! [String: Any]
        check(config2["oauth:tokenCache"] == nil && config2["lastKnownAccountUuid"] as? String == "acct-c", "switch: keys missing from the profile are removed")

        // Add another account: current login saved, login files moved aside, Claude left signed out.
        let fresh = try await LoginProfiles.prepareFreshLogin(paths: paths, step: { _ in })
        let config3 = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeConfig)) as! [String: Any]
        check(config3["lastKnownAccountUuid"] == nil && config3["oauth:tokenCacheV2"] == nil && config3["locale"] != nil
              && !fm.fileExists(atPath: cookies.path), "add account: login keys and cookies moved aside, other keys kept")
        check(fresh.loginBackup.map { fm.fileExists(atPath: $0.appendingPathComponent("Cookies").path) } == true, "add account: cookies kept in the backup")
        check(LoginProfiles.list(paths: paths).count == 3, "add account: no extra profile created")

        // Expired logins are refused with a clear message.
        var expired = work
        expired.sessionExpires = Date().addingTimeInterval(-3600)
        var message = ""
        do { _ = try await LoginProfiles.switchTo(expired, syncFolderIds: nil, paths: paths, step: { _ in }) } catch { message = error.localizedDescription }
        check(message.contains("expired") && message.contains("Log In Again"), "switch: expired login refused with a clear message")

        try await logTests(paths)
    }

    static func logLine(_ date: Date, _ text: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date) + " [info] [account] " + text + "\n"
    }

    static func appendLog(_ paths: HelperPaths, _ text: String) throws {
        if !fm.fileExists(atPath: paths.claudeLog.path) { try write("", paths.claudeLog) }
        let h = try FileHandle(forWritingTo: paths.claudeLog)
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
    }

    /// Sign-in and sign-out handling, driven by fake lines in Claude's log format.
    static func logTests(_ paths: HelperPaths) async throws {
        let now = Date()
        try write(logLine(now.addingTimeInterval(-300), "Login-state transition (loggedOut: false \u{2192} true, uuid: aaaaaaaa-0000-0000-0000-000000000001 \u{2192} <none>), clearing oauth cache")
                  + logLine(now.addingTimeInterval(-290), "Navigated to /logout, synthesizing logged-out")
                  + logLine(now.addingTimeInterval(-280), "Login-state transition (loggedOut: true \u{2192} false, uuid: aaaaaaaa-0000-0000-0000-000000000001 \u{2192} bbbbbbbb-0000-0000-0000-000000000002)")
                  + "2026-01-01 00:00:00 [info] [oauth-v2] unrelated line\n", paths.claudeLog)
        let events = ClaudeLog.loginEvents(paths: paths)
        check(events.count == 3 && events[0].kind == .signedOut(from: "aaaaaaaa-0000-0000-0000-000000000001")
              && events[1].kind == .signedOut(from: nil)
              && events[2].kind == .signedIn(account: "bbbbbbbb-0000-0000-0000-000000000002", wasSignedOut: true), "log: sign-in and sign-out lines parsed")

        // Two accounts saved while signed in (the last log event is a sign-in).
        let xId = "aaaaaaaa-0000-0000-0000-00000000000a", yId = "bbbbbbbb-0000-0000-0000-00000000000b"
        try fakeLogin(paths, account: xId, token: "X", marker: "marker-x")
        let x = try LoginProfiles.saveCurrent(name: "X", paths: paths)
        try fakeLogin(paths, account: yId, token: "Y", marker: "marker-y")
        let y = try LoginProfiles.saveCurrent(name: "Y", paths: paths)

        // Signed out of Y inside Claude: saving must refuse, and Y is flagged.
        try appendLog(paths, logLine(Date().addingTimeInterval(2), "Login-state transition (loggedOut: false \u{2192} true, uuid: \(yId) \u{2192} <none>), clearing oauth cache"))
        check(!LoginProfiles.isSignedIn(paths: paths), "log: signed-out state detected")
        var refused = false
        do { _ = try LoginProfiles.saveCurrent(name: "Y", paths: paths) } catch { refused = true }
        check(refused, "save: refuses to save while Claude is signed out")
        LoginProfiles.updateProblems(paths: paths)
        check(LoginProfiles.list(paths: paths).first { $0.id == y.id }?.problem?.contains("Signed out") == true, "profiles: login ended by a sign-out is flagged")
        check(LoginProfiles.list(paths: paths).first { $0.id == x.id }?.problem == nil, "profiles: other logins not flagged")
        var switchRefused = ""
        do { _ = try await LoginProfiles.switchTo(LoginProfiles.list(paths: paths).first { $0.id == y.id }!, syncFolderIds: nil, paths: paths, step: { _ in }) } catch { switchRefused = error.localizedDescription }
        check(switchRefused.contains("Log In Again"), "switch: a flagged login is not used")

        // Back on X (signed in), switch to a copy of Y that Claude rejects: X must be put back and Y flagged.
        try fakeLogin(paths, account: xId, token: "X", marker: "marker-x")
        try appendLog(paths, logLine(Date().addingTimeInterval(3), "Login-state transition (loggedOut: true \u{2192} false, uuid: <none> \u{2192} \(xId))"))
        var yClean = LoginProfiles.list(paths: paths).first { $0.id == y.id }!
        yClean.problem = nil
        LoginProfiles.saveMeta(yClean, paths: paths)
        let r = try await LoginProfiles.switchTo(yClean, syncFolderIds: nil, paths: paths, verifier: { _ in .rejected }, step: { _ in })
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.claudeConfig)) as! [String: Any]
        check(after["lastKnownAccountUuid"] as? String == xId && (after["oauth:tokenCacheV2"] as? String) == "v2-X",
              "switch: rejected login rolls back to the previous account")
        check(r.warnings.first?.contains("back on X") == true, "switch: rollback is explained")
        check(LoginProfiles.list(paths: paths).first { $0.id == y.id }?.problem != nil, "switch: rejected login is flagged")

        // An accepted switch: Y is used and X stays good.
        var yAgain = LoginProfiles.list(paths: paths).first { $0.id == y.id }!
        yAgain.problem = nil
        LoginProfiles.saveMeta(yAgain, paths: paths)
        let ok = try await LoginProfiles.switchTo(yAgain, syncFolderIds: nil, paths: paths, verifier: { _ in .accepted }, step: { _ in })
        check(ok.warnings.isEmpty && LoginProfiles.currentAccountId(paths: paths) == yId, "switch: accepted login stays in place")

        // Log In and Save: a new account is saved by itself once Claude has settled after the sign-in.
        let zId = "cccccccc-0000-0000-0000-00000000000c"
        try fakeLogin(paths, account: zId, token: "Z", marker: "marker-z")
        try appendLog(paths, logLine(Date(), "Login-state transition (loggedOut: true \u{2192} false, uuid: <none> \u{2192} \(zId))"))
        check(LoginProfiles.saveNewIfSettled(account: zId, name: "z@example.com", paths: paths) == nil, "log in and save: waits while Claude settles")
        try appendLog(paths, logLine(Date().addingTimeInterval(-60), "Login-state transition (loggedOut: true \u{2192} false, uuid: <none> \u{2192} \(zId))"))
        let z = LoginProfiles.saveNewIfSettled(account: zId, name: "z@example.com", paths: paths)
        check(z?.accountId == zId && z?.name == "z@example.com", "log in and save: new account saved by itself")
        check(LoginProfiles.saveNewIfSettled(account: zId, name: "again", paths: paths) == nil, "log in and save: no second profile")
        try fakeLogin(paths, account: yId, token: "Y", marker: "marker-y")

        // Self-refresh: the signed-in account's copy is re-saved and its flag cleared.
        var yMeta = LoginProfiles.list(paths: paths).first { $0.id == y.id }!
        yMeta.problem = "stale"
        LoginProfiles.saveMeta(yMeta, paths: paths)
        try appendLog(paths, logLine(Date().addingTimeInterval(-60), "Login-state transition (loggedOut: true \u{2192} false, uuid: <none> \u{2192} \(yId))"))
        _ = x
        check(LoginProfiles.refreshActive(paths: paths)?.id == y.id
              && LoginProfiles.list(paths: paths).first { $0.id == y.id }?.problem == nil, "refresh: signed-in account re-saved and unflagged")
    }
}
