import Foundation

public enum FileOperation: Sendable {
    /// Create or replace a file. `mtime` keeps the source file's modification date (sync, restore).
    case write(Data, mtime: Date?)
    /// Move the file into the backup's `removed/` folder instead of deleting it.
    case moveToBackup
}

public struct PlannedChange: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case edit, add, update, removeDeleted, addMarker, archivedIndex, putBack, moveOut
    }
    public let id = UUID()
    public let folder: SessionFolder
    public let kind: Kind
    public let target: URL
    public let summary: String
    public let detail: String?
    public let operation: FileOperation

    /// Identity used to compare a preview with the plan rebuilt after Claude quits.
    public var key: String { kind.rawValue + "|" + target.path }
}

public struct GuardProblem: Identifiable, Sendable {
    public let id = UUID()
    public let path: URL
    public let message: String
}

public struct WritePlan: Sendable {
    public var title: String
    public var reason: String
    public var changes: [PlannedChange] = []
    public var problems: [GuardProblem] = []
    public var warnings: [String] = []
    /// Folders whose files are backed up before applying.
    public var folders: [SessionFolder] = []

    public var keys: Set<String> { Set(changes.map(\.key)) }
    public var canApply: Bool { problems.isEmpty && !changes.isEmpty }
}

public struct SessionEdit: Sendable, Hashable {
    public let folderId: String
    public let sessionId: String
    public var title: String?
    public var isArchived: Bool?
    public var isStarred: Bool?

    public init(folderId: String, sessionId: String, title: String? = nil, isArchived: Bool? = nil, isStarred: Bool? = nil) {
        self.folderId = folderId
        self.sessionId = sessionId
        self.title = title
        self.isArchived = isArchived
        self.isStarred = isStarred
    }

    public var key: String { folderId + "|" + sessionId }
    public var isEmpty: Bool { title == nil && isArchived == nil && isStarred == nil }
}

/// What the user asked for. Plans are always rebuilt from disk, so the same intent can be re-planned after Claude quits.
public enum WriteIntent: Sendable {
    case edits([SessionEdit])
    case sync(folderIds: [String])
    /// One way: chats in the source folders are added to or updated in the target folders. Nothing is deleted
    /// and the source folders are never written.
    case copy(sourceFolderIds: [String], targetFolderIds: [String])
    case restoreBackup(BackupInfo)

    public var label: String {
        switch self {
        case .edits(let e): return "edit \(e.count) chat" + (e.count == 1 ? "" : "s")
        case .sync(let f): return "sync \(f.count) folders"
        case .copy(let s, let t): return "copy \(s.count) folders into \(t.count)"
        case .restoreBackup(let b): return "restore backup \(b.id)"
        }
    }
}

public enum Planner {
    public static func plan(_ intent: WriteIntent, paths: HelperPaths) -> WritePlan {
        switch intent {
        case .edits(let edits): return planEdits(edits, paths: paths)
        case .sync(let ids): return planSync(folderIds: ids, paths: paths)
        case .copy(let src, let dst): return planCopy(sourceIds: src, targetIds: dst, paths: paths)
        case .restoreBackup(let b): return planRestore(b, paths: paths)
        }
    }

    static func folder(id: String, paths: HelperPaths) -> SessionFolder? {
        SessionScanner.listFolders(root: paths.sessionsRoot).first { $0.id == id }
    }

    static func quoted(_ s: String) -> String { "\"" + s + "\"" }

    // MARK: Edits (restore, archive, pin, rename)

    static func planEdits(_ edits: [SessionEdit], paths: HelperPaths) -> WritePlan {
        let count = edits.count
        var plan = WritePlan(title: "Change \(count) chat" + (count == 1 ? "" : "s"), reason: "edit")
        let byFolder = Dictionary(grouping: edits.filter { !$0.isEmpty }, by: \.folderId)
        for (folderId, folderEdits) in byFolder.sorted(by: { $0.key < $1.key }) {
            guard let folder = folder(id: folderId, paths: paths) else {
                plan.problems.append(GuardProblem(path: paths.sessionsRoot.appendingPathComponent(folderId), message: "folder not found"))
                continue
            }
            plan.folders.append(folder)
            let idx = SessionScanner.readArchivedIndex(folder)
            var addToIdx = Set<String>(), removeFromIdx = Set<String>()
            for edit in folderEdits {
                let url = folder.sessionURL(edit.sessionId)
                guard let data = try? Data(contentsOf: url) else {
                    plan.problems.append(GuardProblem(path: url, message: "session file not found or unreadable"))
                    continue
                }
                let obj = try? JSONSerialization.jsonObject(with: data)
                let problems = SchemaGuard.sessionProblems(obj, fileURL: url)
                if !problems.isEmpty {
                    problems.forEach { plan.problems.append(GuardProblem(path: url, message: $0)) }
                    continue
                }
                let d = obj as! [String: Any]
                let title = d["title"] as? String ?? "(untitled)"
                let archived = d["isArchived"] as? Bool ?? false
                let starred = d["isStarred"] as? Bool ?? false
                var sets: [(String, Any)] = []
                var what: [String] = []
                if let t = edit.title, t != title {
                    sets.append(("title", t))
                    sets.append(("titleSource", "user"))
                    what.append("rename to " + quoted(t))
                }
                if let a = edit.isArchived {
                    if a != archived {
                        sets.append(("isArchived", a))
                        what.append(a ? "archive" : "restore from archive")
                    }
                    if a { addToIdx.insert(edit.sessionId) } else { removeFromIdx.insert(edit.sessionId) }
                    if a && starred && edit.isStarred == nil {
                        sets.append(("isStarred", false))
                        what.append("unpin (archived chats cannot stay pinned)")
                    }
                }
                if let s = edit.isStarred, s != starred, !(edit.isArchived == true && s) {
                    sets.append(("isStarred", s))
                    what.append(s ? "pin" : "unpin")
                }
                guard !sets.isEmpty else { continue }
                do {
                    let patched = try TopLevelJSON.patch(data, set: sets)
                    plan.changes.append(PlannedChange(folder: folder, kind: .edit, target: url,
                                                      summary: quoted(title) + ": " + what.joined(separator: ", "),
                                                      detail: url.lastPathComponent, operation: .write(patched, mtime: nil)))
                } catch {
                    plan.problems.append(GuardProblem(path: url, message: error.localizedDescription))
                }
            }
            if !addToIdx.isEmpty || !removeFromIdx.isEmpty {
                guard let ids = idx.ids else {
                    plan.problems.append(GuardProblem(path: idx.url, message: idx.problem ?? "unreadable"))
                    continue
                }
                let newIds = Set(ids).subtracting(removeFromIdx).union(addToIdx)
                if newIds != Set(ids) {
                    let added = newIds.subtracting(ids).count, removed = Set(ids).subtracting(newIds).count
                    do {
                        plan.changes.append(PlannedChange(folder: folder, kind: .archivedIndex, target: idx.url,
                                                          summary: "Archived list: " + idxDelta(added, removed) + " (\(newIds.count) total)",
                                                          detail: idx.exists ? nil : "file will be created",
                                                          operation: .write(try SchemaGuard.encodeArchivedIndex(Array(newIds)), mtime: nil)))
                    } catch {
                        plan.problems.append(GuardProblem(path: idx.url, message: error.localizedDescription))
                    }
                }
            }
        }
        return plan
    }

    static func idxDelta(_ added: Int, _ removed: Int) -> String {
        var parts: [String] = []
        if added > 0 { parts.append("add \(added)") }
        if removed > 0 { parts.append("remove \(removed)") }
        return parts.joined(separator: ", ")
    }

    // MARK: Account sync

    static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func planSync(folderIds: [String], paths: HelperPaths) -> WritePlan {
        var plan = WritePlan(title: "Sync \(folderIds.count) account folders", reason: "sync")
        let all = SessionScanner.listFolders(root: paths.sessionsRoot)
        let folders = folderIds.compactMap { id in all.first { $0.id == id } }
        for id in folderIds where !folders.contains(where: { $0.id == id }) {
            plan.problems.append(GuardProblem(path: paths.sessionsRoot.appendingPathComponent(id), message: "folder not found"))
        }
        guard folders.count >= 2 else {
            plan.problems.append(GuardProblem(path: paths.sessionsRoot, message: "pick at least two folders"))
            return plan
        }
        plan.folders = folders
        let scans = folders.map(SessionScanner.scanFolder)

        for scan in scans {
            if let p = scan.archivedIndex.problem {
                plan.problems.append(GuardProblem(path: scan.archivedIndex.url, message: p))
            }
            for (url, why) in scan.unreadable {
                plan.problems.append(GuardProblem(path: url, message: why))
            }
            if scan.folder.isBackupCopy {
                plan.warnings.append(scan.folder.shortLabel + " is a hand-made backup copy, not a live account folder.")
            }
        }

        // Deleted markers: union across folders. Keep the earliest marker as the one to copy.
        var markers: [String: (url: URL, mtime: Date, data: Data, folder: SessionFolder)] = [:]
        for scan in scans {
            for (uuid, url) in scan.deletedMarkers {
                let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
                guard let data = try? Data(contentsOf: url) else {
                    plan.problems.append(GuardProblem(path: url, message: "could not read deleted marker"))
                    continue
                }
                if let existing = markers[uuid], existing.mtime <= mtime { continue }
                markers[uuid] = (url, mtime, data, scan.folder)
            }
        }

        // Group copies of each session across folders.
        var copies: [String: [SessionRecord]] = [:]
        for scan in scans {
            for s in scan.sessions { copies[s.sessionId, default: []].append(s) }
        }
        var titles: [String: String] = [:]
        var finalArchived: [String: Bool] = [:]   // session id -> archived, for sessions that will exist everywhere

        for (sid, list) in copies.sorted(by: { $0.key < $1.key }) {
            let uuid = list[0].uuid
            titles[uuid] = list[0].title
            if let marker = markers[uuid] {
                for s in list {
                    plan.changes.append(PlannedChange(folder: s.folder, kind: .removeDeleted, target: s.fileURL,
                                                      summary: quoted(s.title) + ": deleted in " + marker.folder.shortLabel + ", move this copy to the backup",
                                                      detail: s.fileURL.lastPathComponent, operation: .moveToBackup))
                }
                continue
            }
            let bad = list.filter { !$0.problems.isEmpty }
            if !bad.isEmpty {
                for s in bad {
                    s.problems.forEach { plan.problems.append(GuardProblem(path: s.fileURL, message: $0)) }
                }
                continue
            }
            let winner = list.max { a, b in
                if a.fileMTime != b.fileMTime { return a.fileMTime < b.fileMTime }
                return (a.lastActivityAt ?? .distantPast) < (b.lastActivityAt ?? .distantPast)
            }!
            guard let winnerData = try? Data(contentsOf: winner.fileURL) else {
                plan.problems.append(GuardProblem(path: winner.fileURL, message: "could not read"))
                continue
            }
            finalArchived[sid] = winner.isArchived
            if winnerData.count > 100_000 {
                plan.warnings.append(quoted(winner.title) + " is \(winnerData.count / 1024) KB (connector config). A copy this big once failed to show in the sidebar.")
            }
            for scan in scans {
                let target = scan.folder.sessionURL(sid)
                if let mine = list.first(where: { $0.folder == scan.folder }) {
                    if mine.folder == winner.folder { continue }
                    guard let mineData = try? Data(contentsOf: mine.fileURL) else { continue }
                    if mineData == winnerData { continue }
                    plan.changes.append(PlannedChange(
                        folder: scan.folder, kind: .update, target: target,
                        summary: quoted(winner.title) + ": update from " + winner.folder.shortLabel,
                        detail: "newer copy " + dateFmt.string(from: winner.fileMTime) + " replaces " + dateFmt.string(from: mine.fileMTime)
                            + (mine.title != winner.title ? ", title was " + quoted(mine.title) : "")
                            + (mine.isArchived != winner.isArchived ? (winner.isArchived ? ", becomes archived" : ", becomes active") : ""),
                        operation: .write(winnerData, mtime: winner.fileMTime)))
                } else {
                    plan.changes.append(PlannedChange(
                        folder: scan.folder, kind: .add, target: target,
                        summary: quoted(winner.title) + ": add from " + winner.folder.shortLabel,
                        detail: (winner.isArchived ? "archived" : "active") + ", last change " + dateFmt.string(from: winner.fileMTime),
                        operation: .write(winnerData, mtime: winner.fileMTime)))
                }
            }
        }

        for (uuid, marker) in markers.sorted(by: { $0.key < $1.key }) {
            for scan in scans where scan.deletedMarkers[uuid] == nil {
                let name = titles[uuid].map { " (" + quoted($0) + ")" } ?? ""
                plan.changes.append(PlannedChange(folder: scan.folder, kind: .addMarker, target: scan.folder.markerURL(uuid),
                                                  summary: "Deleted marker for " + String(uuid.prefix(8)) + name + " from " + marker.folder.shortLabel,
                                                  detail: "deleted_" + uuid, operation: .write(marker.data, mtime: marker.mtime)))
            }
        }

        // Every folder ends up with the same sessions, so the archived list is the same everywhere.
        let wantedArchived = Set(finalArchived.filter { $0.value }.keys)
        for scan in scans {
            guard let current = scan.archivedIndex.ids else { continue }
            let cur = Set(current)
            if cur == wantedArchived { continue }
            if !scan.archivedIndex.exists && wantedArchived.isEmpty { continue }
            let added = wantedArchived.subtracting(cur).count, removed = cur.subtracting(wantedArchived).count
            do {
                plan.changes.append(PlannedChange(folder: scan.folder, kind: .archivedIndex, target: scan.archivedIndex.url,
                                                  summary: "Archived list: " + idxDelta(added, removed) + " (\(wantedArchived.count) total)",
                                                  detail: scan.archivedIndex.exists ? nil : "file will be created",
                                                  operation: .write(try SchemaGuard.encodeArchivedIndex(Array(wantedArchived)), mtime: nil)))
            } catch {
                plan.problems.append(GuardProblem(path: scan.archivedIndex.url, message: error.localizedDescription))
            }
        }
        return plan
    }

    // MARK: One-way copy

    static func planCopy(sourceIds: [String], targetIds: [String], paths: HelperPaths) -> WritePlan {
        var plan = WritePlan(title: "Copy chats into \(targetIds.count) folder" + (targetIds.count == 1 ? "" : "s"), reason: "copy")
        let all = SessionScanner.listFolders(root: paths.sessionsRoot)
        let sources = sourceIds.compactMap { id in all.first { $0.id == id } }
        let targets = targetIds.filter { !sourceIds.contains($0) }.compactMap { id in all.first { $0.id == id } }
        guard !sources.isEmpty, !targets.isEmpty else {
            plan.problems.append(GuardProblem(path: paths.sessionsRoot, message: "pick an account to copy from and at least one to copy to"))
            return plan
        }
        plan.folders = targets
        let sourceScans = sources.map(SessionScanner.scanFolder)
        let targetScans = targets.map(SessionScanner.scanFolder)
        for scan in sourceScans + targetScans {
            for (url, why) in scan.unreadable { plan.problems.append(GuardProblem(path: url, message: why)) }
        }
        for scan in targetScans {
            if let p = scan.archivedIndex.problem { plan.problems.append(GuardProblem(path: scan.archivedIndex.url, message: p)) }
        }

        // Newest copy of each chat within the source account. Chats deleted there are not copied.
        var sourceMarkers = Set<String>()
        for scan in sourceScans { sourceMarkers.formUnion(scan.deletedMarkers.keys) }
        var best: [String: SessionRecord] = [:]
        for scan in sourceScans {
            for s in scan.sessions where !sourceMarkers.contains(s.uuid) {
                if !s.problems.isEmpty {
                    s.problems.forEach { plan.problems.append(GuardProblem(path: s.fileURL, message: $0)) }
                    continue
                }
                if let cur = best[s.sessionId], cur.fileMTime >= s.fileMTime { continue }
                best[s.sessionId] = s
            }
        }

        for scan in targetScans {
            var archived = Set(scan.archivedIndex.ids ?? [])
            let before = archived
            let mine = Dictionary(scan.sessions.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
            for (sid, src) in best.sorted(by: { $0.key < $1.key }) {
                // Deleted in this account: leave it deleted.
                if scan.deletedMarkers[src.uuid] != nil { continue }
                guard let data = try? Data(contentsOf: src.fileURL) else {
                    plan.problems.append(GuardProblem(path: src.fileURL, message: "could not read"))
                    continue
                }
                if let have = mine[sid] {
                    if !have.problems.isEmpty {
                        have.problems.forEach { plan.problems.append(GuardProblem(path: have.fileURL, message: $0)) }
                        continue
                    }
                    // This account already has the same or a newer copy: keep it.
                    if have.fileMTime >= src.fileMTime { continue }
                    if (try? Data(contentsOf: have.fileURL)) == data { continue }
                    plan.changes.append(PlannedChange(
                        folder: scan.folder, kind: .update, target: scan.folder.sessionURL(sid),
                        summary: quoted(src.title) + ": update from " + src.folder.shortLabel,
                        detail: "newer copy " + dateFmt.string(from: src.fileMTime) + " replaces " + dateFmt.string(from: have.fileMTime),
                        operation: .write(data, mtime: src.fileMTime)))
                } else {
                    plan.changes.append(PlannedChange(
                        folder: scan.folder, kind: .add, target: scan.folder.sessionURL(sid),
                        summary: quoted(src.title) + ": add from " + src.folder.shortLabel,
                        detail: (src.isArchived ? "archived" : "active") + ", last change " + dateFmt.string(from: src.fileMTime),
                        operation: .write(data, mtime: src.fileMTime)))
                }
                if src.isArchived { archived.insert(sid) } else { archived.remove(sid) }
                if data.count > 100_000 {
                    plan.warnings.append(quoted(src.title) + " is \(data.count / 1024) KB (connector config). A copy this big once failed to show in the sidebar.")
                }
            }
            if archived != before, scan.archivedIndex.ids != nil {
                let added = archived.subtracting(before).count, removed = before.subtracting(archived).count
                do {
                    plan.changes.append(PlannedChange(folder: scan.folder, kind: .archivedIndex, target: scan.archivedIndex.url,
                                                      summary: "Archived list: " + idxDelta(added, removed) + " (\(archived.count) total)",
                                                      detail: scan.archivedIndex.exists ? nil : "file will be created",
                                                      operation: .write(try SchemaGuard.encodeArchivedIndex(Array(archived)), mtime: nil)))
                } catch {
                    plan.problems.append(GuardProblem(path: scan.archivedIndex.url, message: error.localizedDescription))
                }
            }
        }
        plan.warnings = Array(Set(plan.warnings)).sorted()
        return plan
    }

    // MARK: Restore a backup

    static func planRestore(_ backup: BackupInfo, paths: HelperPaths) -> WritePlan {
        var plan = WritePlan(title: "Restore backup " + backup.id, reason: "restore-backup")
        let tmp: URL
        do {
            tmp = try BackupManager.extract(backup, paths: paths)
        } catch {
            plan.problems.append(GuardProblem(path: backup.snapshotURL, message: error.localizedDescription))
            return plan
        }
        let fm = FileManager.default
        for ref in backup.folders {
            let folder = SessionFolder(accountId: ref.accountId, orgId: ref.orgId,
                                       url: paths.sessionsRoot.appendingPathComponent(ref.accountId).appendingPathComponent(ref.orgId, isDirectory: true))
            plan.folders.append(folder)
            let snapDir = tmp.appendingPathComponent(ref.accountId).appendingPathComponent(ref.orgId)
            let snapFiles = Set(((try? fm.contentsOfDirectory(atPath: snapDir.path)) ?? []).filter(BackupManager.isManagedName))
            let curFiles = Set(((try? fm.contentsOfDirectory(atPath: folder.url.path)) ?? []).filter(BackupManager.isManagedName))
            for name in snapFiles.sorted() {
                let src = snapDir.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: src) else { continue }
                if name.hasPrefix("local_") {
                    let obj = try? JSONSerialization.jsonObject(with: data)
                    let problems = SchemaGuard.sessionProblems(obj, fileURL: src)
                    problems.forEach { plan.problems.append(GuardProblem(path: folder.url.appendingPathComponent(name), message: "in backup: " + $0)) }
                } else if name == "archived-sessions.idx", let p = SchemaGuard.parseArchivedIndex(data).problem {
                    plan.problems.append(GuardProblem(path: folder.url.appendingPathComponent(name), message: "in backup: " + p))
                }
                let target = folder.url.appendingPathComponent(name)
                let current = try? Data(contentsOf: target)
                if current == data { continue }
                let mtime = (try? fm.attributesOfItem(atPath: src.path)[.modificationDate] as? Date) ?? nil
                plan.changes.append(PlannedChange(folder: folder, kind: .putBack, target: target,
                                                  summary: (current == nil ? "Put back " : "Revert ") + describe(name, data),
                                                  detail: name, operation: .write(data, mtime: mtime)))
            }
            for name in curFiles.subtracting(snapFiles).sorted() {
                let target = folder.url.appendingPathComponent(name)
                let data = (try? Data(contentsOf: target)) ?? Data()
                plan.changes.append(PlannedChange(folder: folder, kind: .moveOut, target: target,
                                                  summary: "Move out " + describe(name, data) + " (not in the backup)",
                                                  detail: name, operation: .moveToBackup))
            }
        }
        try? fm.removeItem(at: tmp)
        return plan
    }

    static func describe(_ name: String, _ data: Data) -> String {
        if name.hasPrefix("local_"),
           let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = d["title"] as? String {
            return quoted(t)
        }
        return name
    }
}
