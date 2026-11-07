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
        loginEvents(paths: paths).last.map(\.isSignOut)
    }
}
