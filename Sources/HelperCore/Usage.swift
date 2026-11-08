import Foundation

/// Plan usage as Claude itself records it in `plan-usage-history.json`: the percent used of the five-hour and
/// the weekly limit, per organization, sampled about every 30 minutes while Claude runs. The helper only reads
/// this file. A sample names an organization, not an account, so the helper works out the account from the
/// sign-in lines in Claude's log: the account that was signed in when the sample was taken.
public struct UsageSample: Sendable, Hashable {
    public let org: String
    public let date: Date
    /// nil when the sample has no five-hour window (nothing used in the last five hours).
    public let fiveHour: Int?
    public let sevenDay: Int?

    public init(org: String, date: Date, fiveHour: Int?, sevenDay: Int?) {
        self.org = org
        self.date = date
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

/// The latest known usage of one account, and what it is most likely now.
public struct AccountUsage: Sendable, Hashable {
    public let accountId: String
    public let org: String
    public let sampledAt: Date
    /// Percent of the five-hour limit used when sampled (0 when no window was open).
    public let fiveHour: Int
    public let sevenDay: Int?
    /// Latest time the five-hour window that was open at `sampledAt` can end, when the samples show when it began.
    public let fiveHourResetsBy: Date?
    /// A time the weekly limit reset at or before, learned from a drop in the weekly figure. Weekly limits reset
    /// at the same time every week, so later resets are this plus whole weeks.
    public let weekAnchor: Date?

    public init(accountId: String, org: String, sampledAt: Date, fiveHour: Int, sevenDay: Int?,
                fiveHourResetsBy: Date?, weekAnchor: Date?) {
        self.accountId = accountId
        self.org = org
        self.sampledAt = sampledAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fiveHourResetsBy = fiveHourResetsBy
        self.weekAnchor = weekAnchor
    }

    static let week: TimeInterval = 7 * 86400
    static let fiveHours: TimeInterval = 5 * 3600

    /// When the five-hour window seen in the sample ends at the latest.
    public var fiveHourWindowEnd: Date? {
        guard fiveHour > 0 else { return nil }
        let cap = sampledAt.addingTimeInterval(Self.fiveHours)
        return fiveHourResetsBy.map { min($0, cap) } ?? cap
    }

    /// First estimated weekly reset after `date`.
    public func weekReset(after date: Date) -> Date? {
        guard let a = weekAnchor else { return nil }
        let k = (date.timeIntervalSince(a) / Self.week).rounded(.down) + 1
        return a.addingTimeInterval(max(1, k) * Self.week)
    }

    /// Five-hour usage now: 0 once the window seen in the sample has surely ended.
    public func fiveHourNow(_ now: Date = Date()) -> Int {
        guard let end = fiveHourWindowEnd else { return 0 }
        return now >= end ? 0 : fiveHour
    }

    /// The latest time the open five-hour window resets, while it is still open.
    public func fiveHourReset(_ now: Date = Date()) -> Date? {
        guard let end = fiveHourWindowEnd, end > now else { return nil }
        return end
    }

    /// Weekly usage now: 0 once a week passed since the sample or the estimated weekly reset passed.
    public func sevenDayNow(_ now: Date = Date()) -> Int? {
        guard let s = sevenDay else { return nil }
        if now.timeIntervalSince(sampledAt) >= Self.week { return 0 }
        if let r = weekReset(after: sampledAt), r <= now { return 0 }
        return s
    }

    /// The next estimated weekly reset after now.
    public func weekReset(_ now: Date = Date()) -> Date? { weekReset(after: now) }

    /// Highest of the two limits now, what auto-switch compares with its threshold.
    public func peakNow(_ now: Date = Date()) -> Int { max(fiveHourNow(now), sevenDayNow(now) ?? 0) }
}

public enum PlanUsage {
    public static func historyURL(_ paths: HelperPaths) -> URL { paths.claudeDir.appendingPathComponent("plan-usage-history.json") }

    /// Samples in Claude's usage history, oldest first. Empty when the file is missing or in an unknown format.
    public static func readSamples(paths: HelperPaths) -> [UsageSample] {
        guard let data = try? Data(contentsOf: historyURL(paths)) else { return [] }
        return parseSamples(data)
    }

    static func int(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return max(0, min(100, Int(n.doubleValue.rounded())))
    }

    /// `{"version":2,"samples":[{"org":"<uuid>","t":<ms>,"u":{"fh":<pct>,"sd":<pct>}}]}`
    public static func parseSamples(_ data: Data) -> [UsageSample] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["samples"] as? [[String: Any]] else { return [] }
        var out: [UsageSample] = []
        for s in list {
            guard let org = s["org"] as? String, let t = (s["t"] as? NSNumber)?.doubleValue,
                  let u = s["u"] as? [String: Any] else { continue }
            // Milliseconds since 1970; accept seconds too.
            let date = Date(timeIntervalSince1970: t > 1e11 ? t / 1000 : t)
            out.append(UsageSample(org: org, date: date, fiveHour: int(u["fh"]), sevenDay: int(u["sd"])))
        }
        return out.sorted { $0.date < $1.date }
    }

    /// Who was signed in at each moment, from Claude's sign-in and sign-out lines.
    struct Timeline {
        let events: [LoginEvent]

        /// The account signed in at `date`, or nil when Claude was signed out or the log does not go back that far.
        func account(at date: Date) -> String? {
            // The log has whole seconds; a sample taken in the same second as a sign-in belongs to it.
            let limit = date.addingTimeInterval(1)
            guard let e = events.last(where: { $0.date <= limit }) else { return nil }
            if case .signedIn(let a, _) = e.kind { return a }
            return nil
        }

        /// The account's latest sign-in, Claude reopening on a switched login included.
        func lastSignIn(of account: String) -> Date? {
            events.last { if case .signedIn(let a, _) = $0.kind { return a == account } else { return false } }?.date
        }
    }

    /// Each sample with the account it belongs to. A sample the timeline cannot place (older than the log, or
    /// right after a switch Claude did not log) is matched by its organization, when the placed samples show
    /// that organization belongs to one account.
    public static func attribute(_ samples: [UsageSample], events: [LoginEvent]) -> [(sample: UsageSample, account: String)] {
        let timeline = Timeline(events: events)
        var direct: [(UsageSample, String?)] = samples.map { ($0, timeline.account(at: $0.date)) }
        var owners: [String: [String: Int]] = [:]
        for (s, a) in direct { if let a { owners[s.org, default: [:]][a, default: 0] += 1 } }
        func owner(_ org: String) -> String? {
            guard let counts = owners[org], let top = counts.max(by: { $0.value < $1.value }) else { return nil }
            let total = counts.values.reduce(0, +)
            return Double(top.value) >= 0.75 * Double(total) ? top.key : nil
        }
        for i in direct.indices where direct[i].1 == nil {
            direct[i].1 = owner(direct[i].0.org)
        }
        return direct.compactMap { s, a in a.map { (s, $0) } }
    }

    /// Everything known about who was signed in when: Claude's log, the helper's own record of the signed-in
    /// account, and the helper's login backups (each one marks a moment the login files were swapped).
    public static func timelineEvents(paths: HelperPaths) -> [LoginEvent] {
        let boundaries = LoginProfiles.loginSwapDates(paths: paths).map { LoginEvent(date: $0, kind: .signedOut(from: nil)) }
        // Sorted so that at the same moment a swap comes before the sign-in it led to.
        return (ClaudeLog.allLoginEvents(paths: paths) + AccountHistory.events(paths: paths) + boundaries).sorted { a, b in
            a.date != b.date ? a.date < b.date : (a.isSignOut && !b.isSignOut)
        }
    }

    /// Latest usage per account id.
    public static func accountUsage(samples: [UsageSample], events: [LoginEvent]) -> [String: AccountUsage] {
        let attributed = attribute(samples, events: events)
        let byAccount = Dictionary(grouping: attributed, by: \.account).mapValues { $0.map(\.sample).sorted { $0.date < $1.date } }
        var out: [String: AccountUsage] = [:]
        for (account, list) in byAccount {
            guard let last = list.last else { continue }
            // Only the latest organization's samples describe the same limits.
            let same = list.filter { $0.org == last.org }
            out[account] = AccountUsage(accountId: account, org: last.org, sampledAt: last.date,
                                        fiveHour: last.fiveHour ?? 0, sevenDay: last.sevenDay,
                                        fiveHourResetsBy: fiveHourEnd(same), weekAnchor: weekAnchor(same))
        }
        return out
    }

    public static func accountUsage(paths: HelperPaths) -> [String: AccountUsage] {
        accountUsage(samples: readSamples(paths: paths), events: timelineEvents(paths: paths))
    }

    /// Latest end of the five-hour window open at the last sample: five hours after the earliest sample that is
    /// surely in the same window (samples close together, the figure never dropping, under five hours apart).
    static func fiveHourEnd(_ list: [UsageSample]) -> Date? {
        guard let last = list.last, let lastValue = last.fiveHour, lastValue > 0 else { return nil }
        var earliest = last
        var i = list.count - 1
        while i > 0 {
            let cur = list[i], prev = list[i - 1]
            guard let pv = prev.fiveHour, pv > 0, pv <= (cur.fiveHour ?? 0),
                  cur.date.timeIntervalSince(prev.date) <= 45 * 60,
                  last.date.timeIntervalSince(prev.date) < AccountUsage.fiveHours else { break }
            earliest = prev
            i -= 1
        }
        return earliest.date.addingTimeInterval(AccountUsage.fiveHours)
    }

    /// The latest weekly reset seen in the samples: the weekly figure dropping between two samples at most six
    /// hours apart. The later sample's time is used, so the real reset is at or before it.
    static func weekAnchor(_ list: [UsageSample]) -> Date? {
        guard list.count >= 2 else { return nil }
        for i in stride(from: list.count - 1, to: 0, by: -1) {
            let cur = list[i], prev = list[i - 1]
            guard let c = cur.sevenDay, let p = prev.sevenDay else { continue }
            if p - c >= 3, cur.date.timeIntervalSince(prev.date) <= 6 * 3600 { return cur.date }
        }
        return nil
    }

    /// True when `usage` was sampled after the account's latest sign-in, so it describes this session and not
    /// an earlier one. Auto-switch only acts on such samples.
    public static func isCurrent(_ usage: AccountUsage, events: [LoginEvent]) -> Bool {
        guard let signIn = Timeline(events: events).lastSignIn(of: usage.accountId) else { return true }
        return usage.sampledAt >= signIn
    }
}

/// The helper's own record of which account Claude was signed in to, in ClaudeHelper/account-history.json.
/// Claude does not always log a sign-in when it opens on a switched login, so the helper notes the account
/// itself: when it switches, and whenever it sees the signed-in account change. Only account ids and times.
public enum AccountHistory {
    struct Entry: Codable {
        var t: Date
        var account: String?
    }

    static func url(_ paths: HelperPaths) -> URL { paths.dataDir.appendingPathComponent("account-history.json") }
    static let lock = NSLock()

    static func load(_ paths: HelperPaths) -> [Entry] {
        guard let data = try? Data(contentsOf: url(paths)) else { return [] }
        return (try? LoginProfiles.jsonDecoder.decode([Entry].self, from: data)) ?? []
    }

    /// Note that `account` (nil: signed out) is signed in from `date` on. Nothing is written when it is already
    /// the last entry. Keeps the last 1000 entries.
    public static func record(_ account: String?, at date: Date = Date(), paths: HelperPaths) {
        lock.lock()
        defer { lock.unlock() }
        var list = load(paths)
        if let last = list.last, last.account == account { return }
        list.append(Entry(t: date, account: account))
        if list.count > 1000 { list.removeFirst(list.count - 1000) }
        try? paths.ensureDataDirs()
        if let data = try? LoginProfiles.jsonEncoder.encode(list) { try? LoginProfiles.writePrivate(data, to: url(paths)) }
    }

    /// Record the account Claude is signed in to now.
    public static func noteCurrent(paths: HelperPaths) {
        record(LoginProfiles.isSignedIn(paths: paths) ? paths.activeAccountId() : nil, paths: paths)
    }

    public static func events(paths: HelperPaths) -> [LoginEvent] {
        load(paths).map { e in
            LoginEvent(date: e.t, kind: e.account.map { .signedIn(account: $0, wasSignedOut: false) } ?? .signedOut(from: nil))
        }
    }
}

/// Picks the account to move to when the signed-in one runs low.
public enum AutoSwitch {
    public struct Candidate: Sendable {
        public let accountId: String
        public let usage: AccountUsage?
        public init(accountId: String, usage: AccountUsage?) {
            self.accountId = accountId
            self.usage = usage
        }
    }

    /// Why the signed-in account should be left, or nil when it is under the threshold.
    public static func reason(_ usage: AccountUsage, threshold: Int, now: Date = Date()) -> String? {
        let week = usage.sevenDayNow(now) ?? 0, five = usage.fiveHourNow(now)
        if week >= threshold { return "its weekly limit is at \(week)%" }
        if five >= threshold { return "its 5-hour limit is at \(five)%" }
        return nil
    }

    /// The least used account under the threshold: lowest weekly use first, then lowest 5-hour use.
    /// Accounts without any usage data come last.
    public static func pick(_ candidates: [Candidate], threshold: Int, now: Date = Date()) -> Candidate? {
        let eligible = candidates.filter { c in
            guard let u = c.usage else { return true }
            return (u.sevenDayNow(now) ?? 0) < threshold && u.fiveHourNow(now) < threshold
        }
        return eligible.min { a, b in
            switch (a.usage, b.usage) {
            case (nil, nil): return a.accountId < b.accountId
            case (nil, _): return false
            case (_, nil): return true
            case (let ua?, let ub?):
                let wa = ua.sevenDayNow(now) ?? 0, wb = ub.sevenDayNow(now) ?? 0
                if wa != wb { return wa < wb }
                let fa = ua.fiveHourNow(now), fb = ub.fiveHourNow(now)
                if fa != fb { return fa < fb }
                return a.accountId < b.accountId
            }
        }
    }
}

/// Chats that are in the middle of a turn, judged by the end of their transcripts.
public enum ChatActivity {
    /// Of the given cli session ids, the ones whose transcript changed in the last `window` seconds and ends
    /// mid-turn: a prompt or tool result Claude has not answered yet, or a tool call still running. A turn left
    /// mid-way for longer than `window` (a crash, a permission prompt nobody answered) does not count.
    public static func busyTranscripts(paths: HelperPaths, among ids: Set<String>, window: TimeInterval = 1800,
                                       now: Date = Date()) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        var out = Set<String>()
        let dirs = (try? fm.contentsOfDirectory(at: paths.projectsRoot, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            // A folder's date changes when a file is added, not when one grows, so every folder is listed.
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))) ?? []
            for f in files where f.pathExtension == "jsonl" {
                let id = f.deletingPathExtension().lastPathComponent
                guard ids.contains(id), let m = try? f.resourceValues(forKeys: keys).contentModificationDate,
                      now.timeIntervalSince(m) < window, endsMidTurn(f) else { continue }
                out.insert(id)
            }
        }
        return out
    }

    /// Reads the last 512 KB of a transcript and looks at its last prompt or reply.
    public static func endsMidTurn(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > 512 * 1024 ? size - 512 * 1024 : 0)
        guard let data = try? fh.readToEnd() else { return false }
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let d = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = d["type"] as? String else { continue }
            let msg = d["message"] as? [String: Any]
            let blocks = msg?["content"] as? [[String: Any]] ?? []
            switch type {
            case "assistant":
                // An API error or a hit limit ends the turn.
                if d["error"] != nil || (d["isApiErrorMessage"] as? Bool) == true { return false }
                switch msg?["stop_reason"] as? String {
                case "tool_use": return true
                case nil: return true   // still streaming
                default: return false   // end_turn, stop_sequence, max_tokens, refusal
                }
            case "user":
                if (d["isMeta"] as? Bool) == true { continue }
                let text = (msg?["content"] as? String) ?? blocks.compactMap { $0["text"] as? String }.joined()
                return !text.contains("[Request interrupted by user")
            default:
                continue
            }
        }
        return false
    }
}
