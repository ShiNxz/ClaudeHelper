import Foundation

public struct FolderRef: Codable, Hashable, Sendable {
    public let accountId: String
    public let orgId: String
    public var id: String { accountId + "/" + orgId }
}

public struct BackupInfo: Identifiable, Codable, Hashable, Sendable {
    public let id: String          // directory name
    public let created: Date
    public let reason: String
    public let title: String
    public let folders: [FolderRef]
    public let files: [String]     // paths relative to claude-code-sessions
    public var changes: [String]
    public var applied: Bool
    public var removed: [String]   // files moved into removed/ during apply
    public var dirPath: String

    public var dir: URL { URL(fileURLWithPath: dirPath, isDirectory: true) }
    public var snapshotURL: URL { dir.appendingPathComponent("snapshot.tar.gz") }
    public var manifestURL: URL { dir.appendingPathComponent("manifest.json") }
    public var removedDir: URL { dir.appendingPathComponent("removed", isDirectory: true) }

    public var sizeBytes: Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}

/// Timestamped tar backups of the session files in each touched folder.
/// Only the files the helper manages are included: local_*.json, archived-sessions.idx, deleted_*.
/// backlog/, waiting-input/ and scheduled-tasks.json are never archived or restored.
public enum BackupManager {
    public static func isManagedName(_ name: String) -> Bool {
        if name == "archived-sessions.idx" { return true }
        if name.hasPrefix("deleted_"), !name.contains("/") { return true }
        if name.hasPrefix("local_"), name.hasSuffix(".json"), !name.contains("/") { return true }
        return false
    }

    static let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static func create(folders: [SessionFolder], reason: String, title: String, changes: [String], paths: HelperPaths) throws -> BackupInfo {
        try paths.ensureDataDirs()
        let fm = FileManager.default
        var name = stampFmt.string(from: Date()) + "-" + reason
        var n = 2
        while fm.fileExists(atPath: paths.backupsDir.appendingPathComponent(name).path) {
            name = stampFmt.string(from: Date()) + "-" + reason + "-\(n)"; n += 1
        }
        let dir = paths.backupsDir.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var rel: [String] = []
        var refs: [FolderRef] = []
        for f in folders {
            refs.append(FolderRef(accountId: f.accountId, orgId: f.orgId))
            guard fm.fileExists(atPath: f.url.path) else { continue }
            let base = f.accountId + "/" + f.orgId
            if !rel.contains(f.accountId) { rel.append(f.accountId) }
            rel.append(base)
            let names = ((try? fm.contentsOfDirectory(atPath: f.url.path)) ?? []).filter(isManagedName).sorted()
            rel.append(contentsOf: names.map { base + "/" + $0 })
        }
        let listURL = dir.appendingPathComponent("files.txt")
        try (rel.joined(separator: "\n") + "\n").write(to: listURL, atomically: true, encoding: .utf8)
        let snapshot = dir.appendingPathComponent("snapshot.tar.gz")
        // -n: no recursion, so only the listed entries go in.
        try run("/usr/bin/tar", ["-c", "-z", "-n", "-f", snapshot.path, "-C", paths.sessionsRoot.path, "-T", listURL.path])
        let listed = try run("/usr/bin/tar", ["-t", "-z", "-f", snapshot.path])
        let entries = listed.split(separator: "\n").map { $0.hasSuffix("/") ? String($0.dropLast()) : String($0) }
        let missing = Set(rel).subtracting(entries)
        guard missing.isEmpty else {
            throw HelperError.message("Backup is missing \(missing.count) entries, not applying. First: \(missing.first!)")
        }
        try? fm.removeItem(at: listURL)
        let info = BackupInfo(id: name, created: Date(), reason: reason, title: title, folders: refs,
                              files: rel.filter { $0.split(separator: "/").count == 3 }, changes: changes,
                              applied: false, removed: [], dirPath: dir.path)
        try save(info)
        return info
    }

    public static func save(_ info: BackupInfo) throws {
        try jsonEncoder.encode(info).write(to: info.manifestURL, options: .atomic)
    }

    public static func list(paths: HelperPaths) -> [BackupInfo] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: paths.backupsDir, includingPropertiesForKeys: nil) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dirs.compactMap { d -> BackupInfo? in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("manifest.json")),
                  var info = try? dec.decode(BackupInfo.self, from: data) else { return nil }
            info.dirPath = d.path
            return info
        }.sorted { $0.created > $1.created }
    }

    /// Unpack a snapshot into a temp folder inside the helper's data dir.
    public static func extract(_ backup: BackupInfo, paths: HelperPaths) throws -> URL {
        let tmp = paths.dataDir.appendingPathComponent("tmp/restore-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try run("/usr/bin/tar", ["-x", "-z", "-f", backup.snapshotURL.path, "-C", tmp.path])
        return tmp
    }

    @discardableResult
    public static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw HelperError.message("\((tool as NSString).lastPathComponent) failed: " + String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: outData, as: UTF8.self)
    }
}
