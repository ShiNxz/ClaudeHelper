import Foundation

/// Read-only checks the helper runs before it will write anything.
public enum SchemaGuard {
    /// Problems with a parsed session file. Empty means it is safe to edit.
    public static func sessionProblems(_ obj: Any?, fileURL: URL) -> [String] {
        guard let dict = obj as? [String: Any] else { return ["not a JSON object"] }
        var problems: [String] = []
        let stem = fileURL.deletingPathExtension().lastPathComponent
        switch dict["sessionId"] {
        case let s as String where !s.isEmpty:
            if s != stem { problems.append("sessionId \"\(s)\" does not match the file name") }
        case nil: problems.append("missing sessionId")
        default: problems.append("sessionId is not a string")
        }
        switch dict["cliSessionId"] {
        case let s as String where !s.isEmpty: break
        case nil: problems.append("missing cliSessionId")
        default: problems.append("cliSessionId is not a string")
        }
        if let a = dict["isArchived"], !(a is Bool) && !isBoolNumber(a) { problems.append("isArchived is not true/false") }
        if let a = dict["isStarred"], !(a is Bool) && !isBoolNumber(a) { problems.append("isStarred is not true/false") }
        if let t = dict["title"], !(t is String) { problems.append("title is not a string") }
        return problems
    }

    static func isBoolNumber(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// Parse `archived-sessions.idx`. Only `{"v":1,"archived":["local_...", ...]}` is accepted.
    public static func parseArchivedIndex(_ data: Data) -> (ids: [String]?, problem: String?) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            return (nil, "not valid JSON")
        }
        guard let dict = obj as? [String: Any] else { return (nil, "not a JSON object") }
        let keys = Set(dict.keys)
        if keys != ["v", "archived"] {
            return (nil, "expected exactly the keys v and archived, found: " + dict.keys.sorted().joined(separator: ", "))
        }
        guard let v = dict["v"] as? NSNumber, !isBoolNumber(v), v.intValue == 1, v.doubleValue == 1 else {
            return (nil, "v is \(String(describing: dict["v"]!)), expected 1")
        }
        guard let arr = dict["archived"] as? [Any] else { return (nil, "archived is not an array") }
        var ids: [String] = []
        for item in arr {
            guard let s = item as? String else { return (nil, "archived contains a non-string entry") }
            ids.append(s)
        }
        return (ids, nil)
    }

    /// The exact format the Claude app writes: compact, sorted, no trailing newline.
    public static func encodeArchivedIndex(_ ids: [String]) throws -> Data {
        let sorted = Array(Set(ids)).sorted()
        let arr = try TopLevelJSON.encode(sorted)
        return Data("{\"v\":1,\"archived\":".utf8) + arr + Data("}".utf8)
    }
}

public enum SessionScanner {
    static let fm = FileManager.default

    public static func listFolders(root: URL) -> [SessionFolder] {
        guard let accounts = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [SessionFolder] = []
        for acc in accounts where isDir(acc) {
            guard let orgs = try? fm.contentsOfDirectory(at: acc, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for org in orgs where isDir(org) {
                out.append(SessionFolder(accountId: acc.lastPathComponent, orgId: org.lastPathComponent, url: org))
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    static func isDir(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    public static func scan(paths: HelperPaths) -> Snapshot {
        let folders = listFolders(root: paths.sessionsRoot).map(scanFolder)
        return Snapshot(folders: folders, activeAccountId: paths.activeAccountId(), scannedAt: Date())
    }

    public static func readArchivedIndex(_ folder: SessionFolder) -> ArchivedIndex {
        let url = folder.archivedIndexURL
        guard fm.fileExists(atPath: url.path) else { return ArchivedIndex(url: url, exists: false, ids: [], problem: nil) }
        guard let data = try? Data(contentsOf: url) else {
            return ArchivedIndex(url: url, exists: true, ids: nil, problem: "could not read the file")
        }
        let parsed = SchemaGuard.parseArchivedIndex(data)
        return ArchivedIndex(url: url, exists: true, ids: parsed.ids, problem: parsed.problem)
    }

    public static func scanFolder(_ folder: SessionFolder) -> FolderScan {
        let idx = readArchivedIndex(folder)
        let archivedSet = Set(idx.ids ?? [])
        var sessions: [SessionRecord] = []
        var markers: [String: URL] = [:]
        var unreadable: [(URL, String)] = []
        let names = (try? fm.contentsOfDirectory(atPath: folder.url.path)) ?? []
        for name in names.sorted() {
            let url = folder.url.appendingPathComponent(name)
            if name.hasPrefix("deleted_") {
                markers[String(name.dropFirst(8))] = url
                continue
            }
            guard name.hasPrefix("local_"), name.hasSuffix(".json") else { continue }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            guard let data = try? Data(contentsOf: url) else {
                unreadable.append((url, "could not read")); continue
            }
            let obj = try? JSONSerialization.jsonObject(with: data)
            guard let dict = obj as? [String: Any] else {
                unreadable.append((url, "not valid JSON")); continue
            }
            sessions.append(record(dict, url: url, folder: folder, mtime: mtime, size: size, archivedSet: archivedSet))
        }
        return FolderScan(folder: folder, sessions: sessions, archivedIndex: idx, deletedMarkers: markers, unreadable: unreadable)
    }

    static func date(_ v: Any?) -> Date? {
        guard let n = v as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: n.doubleValue / 1000)
    }

    static func record(_ d: [String: Any], url: URL, folder: SessionFolder, mtime: Date, size: Int, archivedSet: Set<String>) -> SessionRecord {
        let sid = d["sessionId"] as? String ?? url.deletingPathExtension().lastPathComponent
        return SessionRecord(
            folder: folder,
            fileURL: url,
            sessionId: sid,
            cliSessionId: d["cliSessionId"] as? String,
            priorCliSessionIds: d["priorCliSessionIds"] as? [String] ?? [],
            title: (d["title"] as? String) ?? "(untitled)",
            titleSource: d["titleSource"] as? String,
            cwd: d["cwd"] as? String ?? "",
            isArchived: (d["isArchived"] as? Bool) ?? false,
            isStarred: (d["isStarred"] as? Bool) ?? false,
            lastActivityAt: date(d["lastActivityAt"]),
            createdAt: date(d["createdAt"]),
            fileMTime: mtime,
            fileSize: size,
            inArchivedIndex: archivedSet.contains(sid),
            model: d["model"] as? String,
            problems: SchemaGuard.sessionProblems(d, fileURL: url)
        )
    }
}
