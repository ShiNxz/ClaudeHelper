import Foundation

/// One `<accountId>/<orgId>` folder under claude-code-sessions.
public struct SessionFolder: Hashable, Identifiable, Sendable, Codable {
    public let accountId: String
    public let orgId: String
    public let url: URL

    public init(accountId: String, orgId: String, url: URL) {
        self.accountId = accountId
        self.orgId = orgId
        self.url = url
    }

    public var id: String { accountId + "/" + orgId }
    /// Folders like `<org>.backup-1792257286` are copies someone made by hand, not live folders.
    public var isBackupCopy: Bool { orgId.contains(".backup") }
    public var shortLabel: String { String(accountId.prefix(8)) + "/" + String(orgId.prefix(8)) + (isBackupCopy ? " (backup copy)" : "") }

    public var archivedIndexURL: URL { url.appendingPathComponent("archived-sessions.idx") }
    public func sessionURL(_ sessionId: String) -> URL { url.appendingPathComponent(sessionId + ".json") }
    public func markerURL(_ uuid: String) -> URL { url.appendingPathComponent("deleted_" + uuid) }
}

/// One desktop sidebar entry, i.e. one `local_<uuid>.json` file in one folder.
public struct SessionRecord: Identifiable, Hashable, Sendable {
    public let folder: SessionFolder
    public let fileURL: URL
    public let sessionId: String
    public let cliSessionId: String?
    public let priorCliSessionIds: [String]
    public let title: String
    public let titleSource: String?
    public let cwd: String
    public let isArchived: Bool
    public let isStarred: Bool
    public let lastActivityAt: Date?
    public let createdAt: Date?
    public let fileMTime: Date
    public let fileSize: Int
    public let inArchivedIndex: Bool
    public let model: String?
    /// Schema guard findings. Non-empty means the helper refuses to write this file.
    public let problems: [String]

    public var id: String { folder.id + "|" + sessionId }
    /// The uuid part of `local_<uuid>`; `deleted_<uuid>` markers use it.
    public var uuid: String { sessionId.hasPrefix("local_") ? String(sessionId.dropFirst(6)) : sessionId }
    public var openURL: URL? { URL(string: "claude://claude.ai/epitaxy/" + sessionId) }
    public var resumeCommand: String? {
        guard let cli = cliSessionId else { return nil }
        return "cd " + shellQuote(cwd) + " && claude --resume " + cli
    }
    public var allCliSessionIds: [String] { (cliSessionId.map { [$0] } ?? []) + priorCliSessionIds }
}

public func shellQuote(_ s: String) -> String {
    if s.isEmpty { return "''" }
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:@%+=")
    if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

public struct ArchivedIndex: Sendable {
    public let url: URL
    public let exists: Bool
    /// nil when the file exists but does not match `{"v":1,"archived":[...]}`.
    public let ids: [String]?
    public let problem: String?
}

public struct FolderScan: Identifiable, Sendable {
    public let folder: SessionFolder
    public var sessions: [SessionRecord]
    public let archivedIndex: ArchivedIndex
    /// uuid -> marker file
    public let deletedMarkers: [String: URL]
    /// Session files that could not be parsed at all (path, reason).
    public let unreadable: [(URL, String)]
    public var id: String { folder.id }
}

public struct Snapshot: Sendable {
    public let folders: [FolderScan]
    public let activeAccountId: String?
    public let scannedAt: Date

    public var allSessions: [SessionRecord] { folders.flatMap(\.sessions) }

    public func folder(id: String) -> FolderScan? { folders.first { $0.folder.id == id } }

    /// cli session id (current or prior) -> desktop sessions using it
    public func sessionsByCliId() -> [String: [SessionRecord]] {
        var map: [String: [SessionRecord]] = [:]
        for s in allSessions {
            for cli in s.allCliSessionIds { map[cli, default: []].append(s) }
        }
        return map
    }

    /// Best desktop session to open for a cli session id: signed-in account first, then live folders, then newest.
    public func preferredSession(forCli cli: String, in map: [String: [SessionRecord]]) -> SessionRecord? {
        guard let list = map[cli], !list.isEmpty else { return nil }
        return list.sorted { a, b in
            let aActive = a.folder.accountId == activeAccountId, bActive = b.folder.accountId == activeAccountId
            if aActive != bActive { return aActive }
            if a.folder.isBackupCopy != b.folder.isBackupCopy { return !a.folder.isBackupCopy }
            if (a.cliSessionId == cli) != (b.cliSessionId == cli) { return a.cliSessionId == cli }
            return a.fileMTime > b.fileMTime
        }.first
    }
}
