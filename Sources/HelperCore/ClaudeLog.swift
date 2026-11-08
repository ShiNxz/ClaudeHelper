import Foundation

/// Sign-in and sign-out events from Claude's own log (~/Library/Logs/Claude/main.log).
/// Only these two kinds of lines are parsed; nothing else from the log is kept. Best effort:
/// if Claude changes its log wording, the helper falls back to checking the login files.
public struct LoginEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Signed out. `from` is the account that was signed in, when the log says.
        case signedOut(from: String?)
        /// Signed in to `account`. `wasSignedOut` is true when this followed a signed-out state (a real sign-in).
        case signedIn(account: String, wasSignedOut: Bool)
    }
    public let date: Date
    public let kind: Kind

    public init(date: Date, kind: Kind) {
        self.date = date
        self.kind = kind
    }

    public var isSignOut: Bool { if case .signedOut = kind { return true } else { return false } }
}

public enum ClaudeLog {
    static let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    // "[account] Login-state transition (loggedOut: false → true, uuid: <id> → <none>), clearing oauth cache"
    static let transition = try! NSRegularExpression(
        pattern: #"Login-state transition \(loggedOut: (true|false) \S+ (true|false), uuid: (\S+) \S+ ([0-9a-f-]{36}|<none>)\)"#)

    /// Events at or after `since`, oldest first. Reads at most the last `tailBytes` of the log.
    public static func loginEvents(paths: HelperPaths, since: Date? = nil, tailBytes: Int = 8 << 20) -> [LoginEvent] {
        guard let fh = try? FileHandle(forReadingFrom: paths.claudeLog) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return [] }
        return parse(data, since: since)
    }

    static func parse(_ data: Data, since: Date? = nil) -> [LoginEvent] {
        let text = String(decoding: data, as: UTF8.self)
        var out: [LoginEvent] = []
        for line in text.split(separator: "\n") where line.contains("[account]") {
            guard line.count > 19, let date = stampFmt.date(from: String(line.prefix(19))) else { continue }
            if let since, date < since { continue }
            if line.contains("Navigated to /logout") {
                out.append(LoginEvent(date: date, kind: .signedOut(from: nil)))
                continue
            }
            let s = String(line)
            guard let m = transition.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges == 5,
                  let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s),
                  let r3 = Range(m.range(at: 3), in: s), let r4 = Range(m.range(at: 4), in: s) else { continue }
            let wasOut = s[r1] == "true", nowOut = s[r2] == "true"
            let from = String(s[r3]).trimmingCharacters(in: CharacterSet(charactersIn: ",")), to = String(s[r4])
            if nowOut {
                out.append(LoginEvent(date: date, kind: .signedOut(from: from == "<none>" ? nil : from)))
            } else if to != "<none>" {
                out.append(LoginEvent(date: date, kind: .signedIn(account: to, wasSignedOut: wasOut)))
            }
        }
        return out
    }

    /// True when the newest sign-in/sign-out event says Claude is signed out. Nil when the log has no such event.
    public static func lastStateIsSignedOut(paths: HelperPaths) -> Bool? {
        // The cached full history, so checking every minute does not re-read megabytes of log.
        allLoginEvents(paths: paths).last.map(\.isSignOut)
    }

    // MARK: Full history

    struct CachedFile {
        var inode: UInt64
        var size: UInt64
        var mtime: Date
        /// Bytes parsed so far, always at a line end.
        var offset: UInt64
        var events: [LoginEvent]
    }
    nonisolated(unsafe) static var cache: [String: CachedFile] = [:]
    static let cacheLock = NSLock()

    /// Claude's log and its rotated copies (main.log, main1.log, main2.log, ...).
    static func logFiles(_ paths: HelperPaths) -> [URL] {
        let dir = paths.claudeLog.deletingLastPathComponent()
        let stem = paths.claudeLog.deletingPathExtension().lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { n in
            guard n.hasPrefix(stem), n.hasSuffix(".log") else { return false }
            let mid = n.dropFirst(stem.count).dropLast(4)
            return mid.allSatisfy(\.isNumber)
        }.map { dir.appendingPathComponent($0) }
    }

    /// Every sign-in and sign-out event in the log and its rotated copies, oldest first. Files are parsed once
    /// and then only their new lines, so this is cheap to call every minute.
    public static func allLoginEvents(paths: HelperPaths) -> [LoginEvent] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        var all: [LoginEvent] = []
        for url in logFiles(paths) {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else { continue }
            let mtime = attrs[.modificationDate] as? Date ?? .distantPast
            var entry = cache[url.path]
            if let e = entry, e.inode == inode, e.size == size, e.mtime == mtime {
                all += e.events
                continue
            }
            if entry == nil || entry!.inode != inode || size < entry!.offset {
                entry = CachedFile(inode: inode, size: 0, mtime: .distantPast, offset: 0, events: [])
            }
            guard var e = entry, let fh = try? FileHandle(forReadingFrom: url) else { continue }
            try? fh.seek(toOffset: e.offset)
            let data = (try? fh.readToEnd()) ?? Data()
            try? fh.close()
            // Only whole lines; a line still being written is read next time.
            if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                let whole = data[data.startIndex...lastNewline]
                e.events += parse(Data(whole))
                e.offset += UInt64(whole.count)
            }
            e.size = size
            e.mtime = mtime
            cache[url.path] = e
            all += e.events
        }
        return all.sorted { $0.date < $1.date }
    }
}
