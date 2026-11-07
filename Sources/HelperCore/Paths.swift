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
    /// ~/Library/Logs/Claude/main.log (read only for sign-in and sign-out events)
    public var claudeLog: URL

    public init(sessionsRoot: URL, claudeConfig: URL, projectsRoot: URL, dataDir: URL, claudeLog: URL? = nil) {
        self.sessionsRoot = sessionsRoot
        self.claudeConfig = claudeConfig
        self.projectsRoot = projectsRoot
        self.dataDir = dataDir
        self.claudeLog = claudeLog ?? HelperPaths.home.appendingPathComponent("Library/Logs/Claude/main.log")
    }

    /// ~/Library/Application Support/Claude (holds config.json and the Cookies database)
    public var claudeDir: URL { claudeConfig.deletingLastPathComponent() }
    public var profilesDir: URL { dataDir.appendingPathComponent("profiles", isDirectory: true) }
    public var isLiveClaudeDir: Bool {
        claudeDir.standardizedFileURL.path == HelperPaths.home.appendingPathComponent("Library/Application Support/Claude").standardizedFileURL.path
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
            claudeConfig: url("CLAUDE_HELPER_CLAUDE_DIR", home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true))
                .appendingPathComponent("config.json"),
            projectsRoot: url("CLAUDE_HELPER_PROJECTS_ROOT", home.appendingPathComponent(".claude/projects", isDirectory: true)),
            dataDir: url("CLAUDE_HELPER_DATA_DIR", home.appendingPathComponent("Library/Application Support/ClaudeHelper", isDirectory: true)),
            claudeLog: env["CLAUDE_HELPER_CLAUDE_LOG"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        )
    }

    /// The helper's folder holds backups and saved logins, so only this user may read it.
    public func ensureDataDirs() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        for dir in [dataDir, backupsDir, profilesDir] {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    /// Account the Claude app was last signed in to. Reads only one key from config.json.
    public func activeAccountId() -> String? {
        guard let data = try? Data(contentsOf: claudeConfig),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["lastKnownAccountUuid"] as? String
    }
}
