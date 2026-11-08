import AppKit
import Foundation

public struct ApplyResult: Sendable {
    public let backup: BackupInfo
    public let written: Int
    public let moved: Int
    public let log: [String]
}

/// Applies a plan. Never called while Claude is running against the live folder (the coordinator checks).
public enum Executor {
    /// Defense in depth: the only paths the helper may ever create, replace or move.
    public static func isAllowedTarget(_ url: URL, paths: HelperPaths) -> Bool {
        if url.pathComponents.contains(where: { $0 == ".." || $0 == "." }) { return false }
        let root = URL(fileURLWithPath: canonicalPath(paths.sessionsRoot)).pathComponents
        let comps = URL(fileURLWithPath: canonicalPath(url)).pathComponents
        guard comps.count == root.count + 3, Array(comps.prefix(root.count)) == root else { return false }
        return BackupManager.isManagedName(comps.last!)
    }

    /// realpath() of the nearest existing ancestor plus the remaining components, so symlinks such as /tmp
    /// and /private/tmp compare equal and a not-yet-existing file still gets a stable path.
    static func canonicalPath(_ url: URL) -> String {
        var cur = url
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: cur.path), cur.pathComponents.count > 1 {
            rest.insert(cur.lastPathComponent, at: 0)
            cur = cur.deletingLastPathComponent()
        }
        guard let rp = realpath(cur.path, nil) else { return url.path }
        defer { free(rp) }
        return ([String(cString: rp)] + rest).joined(separator: "/")
    }

    public static func apply(_ plan: WritePlan, paths: HelperPaths, log say: (String) -> Void = { _ in }) throws -> ApplyResult {
        guard plan.problems.isEmpty else {
            throw HelperError.message("Refusing to write: \(plan.problems.count) schema problem(s).")
        }
        guard !plan.changes.isEmpty else { throw HelperError.message("Nothing to apply.") }
        for c in plan.changes where !isAllowedTarget(c.target, paths: paths) {
            throw HelperError.message("Refusing to touch \(c.target.path): outside the session files Relay manages.")
        }
        if paths.isLiveSessionsRoot, ClaudeApp.isRunning() {
            throw HelperError.message("Claude is running. Quit it first or it will overwrite these files.")
        }

        say("Backing up \(plan.folders.count) folder(s)")
        var backup = try BackupManager.create(folders: plan.folders, reason: plan.reason, title: plan.title,
                                              changes: plan.changes.map { $0.folder.shortLabel + ": " + $0.summary }, paths: paths)
        say("Backup: " + backup.dir.path)

        let fm = FileManager.default
        var log: [String] = []
        var written = 0, moved = 0
        for c in plan.changes {
            switch c.operation {
            case .write(let data, let mtime):
                try fm.createDirectory(at: c.target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let tmp = c.target.deletingLastPathComponent().appendingPathComponent("." + c.target.lastPathComponent + ".claudehelper-tmp")
                try data.write(to: tmp)
                var attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
                if let mtime { attrs[.modificationDate] = mtime }
                try fm.setAttributes(attrs, ofItemAtPath: tmp.path)
                if rename(tmp.path, c.target.path) != 0 {
                    let err = String(cString: strerror(errno))
                    try? fm.removeItem(at: tmp)
                    throw HelperError.message("Could not write \(c.target.lastPathComponent): \(err). Backup at \(backup.dir.path)")
                }
                written += 1
                log.append("wrote " + c.target.path)
            case .moveToBackup:
                guard fm.fileExists(atPath: c.target.path) else { continue }
                let comps = c.target.pathComponents.suffix(3)
                let dest = backup.removedDir.appendingPathComponent(comps.joined(separator: "/"))
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: c.target, to: dest)
                backup.removed.append(comps.joined(separator: "/"))
                moved += 1
                log.append("moved " + c.target.path + " -> " + dest.path)
            }
        }

        // Check every written file still passes the schema guard.
        for c in plan.changes {
            guard case .write = c.operation, let data = try? Data(contentsOf: c.target) else { continue }
            let name = c.target.lastPathComponent
            if name.hasPrefix("local_") {
                let problems = SchemaGuard.sessionProblems(try? JSONSerialization.jsonObject(with: data), fileURL: c.target)
                if !problems.isEmpty { log.append("WARNING after write: \(name): " + problems.joined(separator: "; ")) }
            } else if name == "archived-sessions.idx", let p = SchemaGuard.parseArchivedIndex(data).problem {
                log.append("WARNING after write: \(name): " + p)
            }
        }
        backup.applied = true
        try? BackupManager.save(backup)
        say("Wrote \(written) file(s), moved \(moved) to the backup")
        return ApplyResult(backup: backup, written: written, moved: moved, log: log)
    }
}

public enum ClaudeApp {
    public static let bundleID = "com.anthropic.claudefordesktop"

    public static func running(bundleID: String = bundleID) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { kill($0.processIdentifier, 0) == 0 }
    }

    public static func isRunning(bundleID: String = bundleID) -> Bool { !running(bundleID: bundleID).isEmpty }

    /// Ask the app to quit and wait until its processes are gone. Never force-kills.
    public static func quit(bundleID: String = bundleID, timeout: TimeInterval = 45) async throws {
        let apps = running(bundleID: bundleID)
        guard !apps.isEmpty else { return }
        let pids = apps.map(\.processIdentifier)
        for app in apps { _ = app.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids.allSatisfy({ kill($0, 0) != 0 }) {
                // Give it a moment to finish flushing files after the main process exits.
                try await Task.sleep(nanoseconds: 1_500_000_000)
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw HelperError.message("Claude did not quit within \(Int(timeout)) seconds. It may be showing a dialog. Quit it yourself, then try again. Nothing was written.")
    }

    public static func open(bundleID: String = bundleID) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw HelperError.message("Could not find the Claude app to reopen it.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}

public enum ApplyOutcome: Sendable {
    case applied(ApplyResult, reopened: Bool)
    /// After Claude quit, the files no longer match the preview. Claude stays closed; show the new plan.
    case planChanged(WritePlan)
}

public enum ApplyCoordinator {
    /// Quit Claude, rebuild the plan from disk, check it still matches what the user saw, back up, apply, reopen Claude.
    public static func run(intent: WriteIntent, previewKeys: Set<String>, paths: HelperPaths,
                           reopen: Bool = true, bundleID: String = ClaudeApp.bundleID,
                           step: @escaping @Sendable (String) -> Void) async throws -> ApplyOutcome {
        var quitByUs = false
        if paths.isLiveSessionsRoot, ClaudeApp.isRunning(bundleID: bundleID) {
            step("Quitting Claude")
            try await ClaudeApp.quit(bundleID: bundleID)
            quitByUs = true
        }
        do {
            step("Re-reading files")
            let plan = Planner.plan(intent, paths: paths)
            if !plan.problems.isEmpty {
                throw HelperError.message("Schema guard: " + plan.problems.map { $0.path.lastPathComponent + ": " + $0.message }.joined(separator: "; "))
            }
            if plan.keys != previewKeys {
                step("Files changed since the preview")
                return .planChanged(plan)
            }
            let result = try Executor.apply(plan, paths: paths, log: step)
            var reopened = false
            if quitByUs && reopen {
                step("Reopening Claude")
                try? await ClaudeApp.open(bundleID: bundleID)
                reopened = true
            }
            step("Done")
            return .applied(result, reopened: reopened)
        } catch {
            if quitByUs && reopen {
                step("Reopening Claude after an error")
                try? await ClaudeApp.open(bundleID: bundleID)
            }
            throw error
        }
    }
}
