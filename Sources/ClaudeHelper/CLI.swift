import Foundation
import HelperCore

/// Headless mode: `ClaudeHelper --cli <command> ...`. Used for testing against copies of the real data.
enum CLI {
    static func out(_ s: String) { print(s); fflush(stdout) }

    static func value(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func run(_ argv: [String]) async -> Int32 {
        let args = Array(argv.drop { $0 != "--cli" }.dropFirst())
        guard let cmd = args.first else {
            out("""
            usage: ClaudeHelper --cli <command>
              selftest                             run the built-in tests against temp fixtures
              scan                                 list folders and sessions
              accounts                             account folders with the email each belongs to (from the index)
              roundtrip                            check the JSON patcher on every session file (no writes)
              index [--tools] [--subagents]        update the search index
              search <query> [--role user|assistant|tool]
              edit --folder <acct/org> --session <local_id> [--restore|--archive|--pin|--unpin|--title T] [--apply]
              sync <acct/org> <acct/org> ... [--apply]
              backup [<acct/org> ...]              back up folders now (default: all live folders), changes nothing
              backups
              restore-backup <backup id> [--apply]
              app-cycle --bundle-id <id>          quit and reopen an app (tests the quit logic)
            env: CLAUDE_HELPER_SESSIONS_ROOT, CLAUDE_HELPER_PROJECTS_ROOT, CLAUDE_HELPER_DATA_DIR
            --apply on the live folder also needs --quit-claude
            """)
            return 2
        }
        let paths = HelperPaths.standard()
        do {
            switch cmd {
            case "selftest": return await SelfTest.run()
            case "accounts":
                let emails = TranscriptIndex.accountEmails(paths: paths)
                let active = paths.activeAccountId()
                for f in SessionScanner.listFolders(root: paths.sessionsRoot) {
                    out(f.id + "  " + (emails[f.accountId] ?? "(email unknown)") + (f.accountId == active ? "  signed in" : ""))
                }
            case "privacy-check":
                // Launch through `open` so macOS treats the app as its own process for privacy prompts.
                var r: [String: Any] = [:]
                let fm = FileManager.default
                let folders = SessionScanner.listFolders(root: paths.sessionsRoot)
                r["sessionFolders"] = folders.count
                r["sessionFiles"] = folders.reduce(0) { $0 + SessionScanner.scanFolder($1).sessions.count }
                let projects = (try? fm.contentsOfDirectory(atPath: paths.projectsRoot.path)) ?? []
                r["projectDirs"] = projects.count
                var readBytes = 0
                outer: for p in projects {
                    let dir = paths.projectsRoot.appendingPathComponent(p)
                    for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".jsonl") {
                        if let h = try? FileHandle(forReadingFrom: dir.appendingPathComponent(f)) {
                            readBytes = (try? h.read(upToCount: 64))?.count ?? 0
                            try? h.close()
                            break outer
                        }
                    }
                }
                r["transcriptBytesRead"] = readBytes
                r["activeAccountKnown"] = paths.activeAccountId() != nil
                if let bid = value(args, "--cycle-app") {
                    let t0 = Date()
                    do {
                        try await ClaudeApp.quit(bundleID: bid, timeout: 20)
                        r["quitSeconds"] = Date().timeIntervalSince(t0)
                        try await ClaudeApp.open(bundleID: bid)
                        try await Task.sleep(nanoseconds: 1_500_000_000)
                        r["reopened"] = ClaudeApp.isRunning(bundleID: bid)
                    } catch {
                        r["cycleError"] = error.localizedDescription
                    }
                }
                let data = try JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])
                if let outPath = value(args, "--out") { try data.write(to: URL(fileURLWithPath: outPath)) }
                out(String(decoding: data, as: UTF8.self))
            case "scan": scan(paths)
            case "roundtrip": return roundtrip(paths)
            case "index": try index(paths, args)
            case "search": try search(paths, args)
            case "edit":
                guard let folder = value(args, "--folder"), let sid = value(args, "--session") else { out("need --folder and --session"); return 2 }
                var e = SessionEdit(folderId: folder, sessionId: sid)
                if args.contains("--restore") { e.isArchived = false }
                if args.contains("--archive") { e.isArchived = true }
                if args.contains("--pin") { e.isStarred = true }
                if args.contains("--unpin") { e.isStarred = false }
                if let t = value(args, "--title") { e.title = t }
                return try await planAndMaybeApply(.edits([e]), paths: paths, args: args)
            case "sync":
                let ids = args.dropFirst().filter { !$0.hasPrefix("--") }
                return try await planAndMaybeApply(.sync(folderIds: Array(ids)), paths: paths, args: args)
            case "backup":
                let ids = Set(args.dropFirst().filter { !$0.hasPrefix("--") })
                let folders = SessionScanner.listFolders(root: paths.sessionsRoot).filter { ids.isEmpty ? !$0.isBackupCopy : ids.contains($0.id) }
                var b = try BackupManager.create(folders: folders, reason: "manual", title: "Manual backup", changes: [], paths: paths)
                b.applied = true
                try BackupManager.save(b)
                out("backed up \(b.files.count) files from \(folders.count) folders to \(b.dir.path)")
            case "backups":
                for b in BackupManager.list(paths: paths) {
                    out("\(b.id)  \(b.title)  folders=\(b.folders.count) files=\(b.files.count) applied=\(b.applied) removed=\(b.removed.count) size=\(b.sizeBytes / 1024)KB")
                }
            case "restore-backup":
                guard args.count > 1, let b = BackupManager.list(paths: paths).first(where: { $0.id == args[1] }) else { out("backup not found"); return 2 }
                return try await planAndMaybeApply(.restoreBackup(b), paths: paths, args: args)
            case "app-cycle":
                guard let bid = value(args, "--bundle-id") else { out("need --bundle-id"); return 2 }
                guard bid != ClaudeApp.bundleID else { out("refusing to cycle Claude from the CLI test"); return 2 }
                out("running: \(ClaudeApp.isRunning(bundleID: bid))")
                let t0 = Date()
                try await ClaudeApp.quit(bundleID: bid, timeout: 20)
                out(String(format: "quit after %.1fs, running: \(ClaudeApp.isRunning(bundleID: bid))", Date().timeIntervalSince(t0)))
                try await ClaudeApp.open(bundleID: bid)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                out("reopened, running: \(ClaudeApp.isRunning(bundleID: bid))")
            default:
                out("unknown command \(cmd)")
                return 2
            }
        } catch {
            out("error: " + error.localizedDescription)
            return 1
        }
        return 0
    }

    static func scan(_ paths: HelperPaths) {
        let snap = SessionScanner.scan(paths: paths)
        out("root: \(paths.sessionsRoot.path)")
        out("signed-in account: \(snap.activeAccountId ?? "unknown")")
        for f in snap.folders {
            let s = f.sessions
            let bad = s.filter { !$0.problems.isEmpty }.count
            let mismatch = s.filter { $0.isArchived != $0.inArchivedIndex }.count
            out("\(f.folder.id)  sessions=\(s.count) archived=\(s.filter(\.isArchived).count) pinned=\(s.filter(\.isStarred).count) idx=\(f.archivedIndex.ids?.count.description ?? "BAD: \(f.archivedIndex.problem ?? "")") markers=\(f.deletedMarkers.count) guardProblems=\(bad) idxMismatch=\(mismatch) unreadable=\(f.unreadable.count)")
        }
    }

    static func roundtrip(_ paths: HelperPaths) -> Int32 {
        var ok = 0, failed = 0
        for s in SessionScanner.scan(paths: paths).allSessions {
            guard let data = try? Data(contentsOf: s.fileURL) else { continue }
            do {
                _ = try TopLevelJSON.patch(data, set: [("isArchived", !s.isArchived)])
                _ = try TopLevelJSON.patch(data, set: [("isStarred", !s.isStarred)])
                let t = try TopLevelJSON.patch(data, set: [("title", "Test \"quoted\" / שלום \u{1F600}"), ("titleSource", "user")])
                // A no-op patch must give back the identical bytes.
                let same = try TopLevelJSON.patch(data, set: [("isArchived", s.isArchived)])
                if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["isArchived"] != nil, same != data {
                    throw HelperError.message("no-op patch changed bytes")
                }
                _ = t
                ok += 1
            } catch {
                failed += 1
                out("FAIL \(s.fileURL.path): \(error.localizedDescription)")
            }
        }
        out("patch round-trip: \(ok) ok, \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    static func index(_ paths: HelperPaths, _ args: [String]) throws {
        let settings = IndexSettings(includeToolOutput: args.contains("--tools"), includeSubagents: args.contains("--subagents"))
        let idx = try TranscriptIndex(paths: paths, settings: settings)
        let t0 = Date()
        var last = Date.distantPast
        try idx.update(progress: { p in
            if Date().timeIntervalSince(last) > 2 || p.phase == .done {
                last = Date()
                out(String(format: "%@ files %d/%d  %.0f/%.0f MB  +%d msgs  %.0fs%@", "\(p.phase)", p.filesDone, p.filesTotal,
                           Double(p.bytesDone) / 1e6, Double(p.bytesTotal) / 1e6, p.messagesAdded, Date().timeIntervalSince(t0),
                           p.rebuilt ? " (rebuilt)" : ""))
            }
        }, cancelled: { false })
        let st = idx.stats()
        let size = (try? FileManager.default.attributesOfItem(atPath: paths.indexDB.path)[.size] as? NSNumber)?.int64Value ?? 0
        out("index: \(st.files) files, \(st.messages) messages, db \(size / 1_000_000) MB (plus WAL)")
    }

    static func search(_ paths: HelperPaths, _ args: [String]) throws {
        let q = args.dropFirst().filter { !$0.hasPrefix("--") && $0 != value(args, "--role") }.joined(separator: " ")
        let role = SearchRole(rawValue: value(args, "--role") ?? "any") ?? .any
        out("fts query: \(TranscriptIndex.ftsQuery(q) ?? "-")")
        let t0 = Date()
        let groups = try TranscriptIndex.search(paths: paths, query: q, role: role)
        out(String(format: "%d chats in %.0f ms", groups.count, Date().timeIntervalSince(t0) * 1000))
        let snap = SessionScanner.scan(paths: paths)
        let map = snap.sessionsByCliId()
        for g in groups.prefix(10) {
            let desktop = snap.preferredSession(forCli: g.file.cliSessionId, in: map)
            out("- \(g.file.displayTitle) [\(g.hits.count) hits] \(g.file.lastTimestamp ?? "")")
            out("  " + (desktop.map { "desktop: \($0.sessionId) in \($0.folder.shortLabel) -> \($0.openURL!.absoluteString)" } ?? "no desktop session: \(g.file.resumeCommand)"))
            if let h = g.hits.first {
                out("  \(h.role): " + h.snippet.replacingOccurrences(of: "\u{2}", with: "[").replacingOccurrences(of: "\u{3}", with: "]").replacingOccurrences(of: "\n", with: " "))
            }
        }
    }

    static func printPlan(_ plan: WritePlan) {
        out("== \(plan.title): \(plan.changes.count) change(s), \(plan.problems.count) problem(s), \(plan.warnings.count) warning(s)")
        for p in plan.problems { out("PROBLEM \(p.path.path): \(p.message)") }
        for w in plan.warnings { out("warning: \(w)") }
        let byFolder = Dictionary(grouping: plan.changes, by: \.folder.id)
        for (fid, changes) in byFolder.sorted(by: { $0.key < $1.key }) {
            out("[\(fid)]")
            let kinds = Dictionary(grouping: changes, by: \.kind.rawValue).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ")
            out("  totals: \(kinds)")
            for c in changes { out("  \(c.kind.rawValue): \(c.summary)" + (c.detail.map { "  (\($0))" } ?? "")) }
        }
    }

    static func planAndMaybeApply(_ intent: WriteIntent, paths: HelperPaths, args: [String]) async throws -> Int32 {
        let plan = Planner.plan(intent, paths: paths)
        printPlan(plan)
        guard args.contains("--apply") else { out("dry run, nothing written"); return 0 }
        guard plan.canApply else { out("not applying"); return 1 }
        if paths.isLiveSessionsRoot, ClaudeApp.isRunning(), !args.contains("--quit-claude") {
            out("Claude is running and this is the live folder. Pass --quit-claude to quit it first.")
            return 1
        }
        let outcome = try await ApplyCoordinator.run(intent: intent, previewKeys: plan.keys, paths: paths, step: { out("> " + $0) })
        switch outcome {
        case .applied(let r, let reopened):
            out("applied: wrote \(r.written), moved \(r.moved), backup \(r.backup.dir.path), reopened Claude: \(reopened)")
            r.log.forEach { out("  " + $0) }
        case .planChanged(let p):
            out("files changed after Claude quit, new plan:")
            printPlan(p)
        }
        return 0
    }
}
