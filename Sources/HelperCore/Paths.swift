import Foundation

/// All locations the helper reads from or writes to.
/// Environment overrides exist so the CLI can be pointed at a copy of the real data for testing.
public struct HelperPaths: Sendable {
    /// ~/Library/Application Support/Claude/claude-code-sessions
    public var sessionsRoot: URL
    /// ~/Library/Application Support/Claude/config.json (only `lastKnownAccountUuid` is read)
    public var claudeConfig: URL
    /// ~/.claude/projects (transcripts, read-only)
    public var projectsRoot: URL
    /// ~/Library/Application Support/ClaudeHelper
    public var dataDir: URL

    public init(sessionsRoot: URL, claudeConfig: URL, projectsRoot: URL, dataDir: URL) {
        self.sessionsRoot = sessionsRoot
        self.claudeConfig = claudeConfig
        self.projectsRoot = projectsRoot
        self.dataDir = dataDir
    }

    public var backupsDir: URL { dataDir.appendingPathComponent("backups", isDirectory: true) }
    public var indexDB: URL { dataDir.appendingPathComponent("index.sqlite") }

    /// True when sessionsRoot is the live folder the Claude app uses.
    public var isLiveSessionsRoot: Bool {
        sessionsRoot.standardizedFileURL.path == HelperPaths.defaultSessionsRoot.standardizedFileURL.path
    }

    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static var defaultSessionsRoot: URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    public static func standard() -> HelperPaths {
        let env = ProcessInfo.processInfo.environment
        func url(_ key: String, _ fallback: URL) -> URL {
            if let v = env[key], !v.isEmpty { return URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true) }
            return fallback
        }
        return HelperPaths(
            sessionsRoot: url("CLAUDE_HELPER_SESSIONS_ROOT", defaultSessionsRoot),
            claudeConfig: home.appendingPathComponent("Library/Application Support/Claude/config.json"),
            projectsRoot: url("CLAUDE_HELPER_PROJECTS_ROOT", home.appendingPathComponent(".claude/projects", isDirectory: true)),
            dataDir: url("CLAUDE_HELPER_DATA_DIR", home.appendingPathComponent("Library/Application Support/ClaudeHelper", isDirectory: true))
        )
    }

    public func ensureDataDirs() throws {
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
    }

    /// Account the Claude app was last signed in to. Reads only one key from config.json.
    public func activeAccountId() -> String? {
        guard let data = try? Data(contentsOf: claudeConfig),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["lastKnownAccountUuid"] as? String
    }
}
