import Foundation

// MARK: - Model

public struct UsageWindow: Equatable, Sendable {
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// After the reset time the stored percent belongs to an old window.
    public func current(now: Date = Date()) -> UsageWindow {
        if let r = resetsAt, r <= now { return UsageWindow(usedPercent: 0, resetsAt: nil) }
        return self
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public var providerID: String
    public var fiveHour: UsageWindow?
    public var weekly: UsageWindow?
    /// When the source last wrote these numbers.
    public var updatedAt: Date

    public init(providerID: String, fiveHour: UsageWindow?, weekly: UsageWindow?, updatedAt: Date) {
        self.providerID = providerID
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.updatedAt = updatedAt
    }
}

/// A local source of rate-limit usage. New tools plug in by adding a provider.
public protocol UsageProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    /// Directories whose changes should trigger `load()`; empty means poll only.
    var watchedDirectories: [URL] { get }
    /// Reads local files only. Returns nil when the tool is not installed or has no data yet.
    func load() -> UsageSnapshot?
}

// MARK: - Claude Code (status-line snapshot)

/// Reads ~/.notch-island/usage/claude.json, which `notch-hook statusline` writes from the
/// `rate_limits` object Claude Code passes to status-line commands. No network, no tokens.
public final class ClaudeStatuslineProvider: UsageProvider, Sendable {
    public let id = "claude"
    public let displayName = "Claude"
    private let file: URL

    public init(file: URL = NIPaths.claudeUsageFile) { self.file = file }

    public var watchedDirectories: [URL] { [file.deletingLastPathComponent()] }

    public func load() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return Self.parse(data)
    }

    public static func parse(_ data: Data) -> UsageSnapshot? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rl = obj["rate_limits"] as? [String: Any]
        else { return nil }
        let five = window(rl["five_hour"])
        let week = window(rl["seven_day"])
        guard five != nil || week != nil else { return nil }
        let ts = Fmt.date(obj["ts"]) ?? Date()
        return UsageSnapshot(providerID: "claude", fiveHour: five, weekly: week, updatedAt: ts)
    }

    static func window(_ any: Any?) -> UsageWindow? {
        guard let d = any as? [String: Any],
              let pct = Fmt.double(d["used_percentage"] ?? d["used_percent"] ?? d["utilization"])
        else { return nil }
        return UsageWindow(usedPercent: pct, resetsAt: Fmt.date(d["resets_at"]))
    }
}

// MARK: - Codex CLI (session logs)

/// Codex CLI records `rate_limits` (primary = 5-hour, secondary = weekly) in its rollout logs
/// under ~/.codex/sessions/YYYY/MM/DD/*.jsonl. We read the tail of the newest file.
public final class CodexUsageProvider: UsageProvider, Sendable {
    public let id = "codex"
    public let displayName = "Codex"
    private let root: URL

    public init(root: URL = NIPaths.codexSessions) { self.root = root }

    public var watchedDirectories: [URL] { [] }

    public func load() -> UsageSnapshot? {
        guard let file = newestLog(), let tail = Self.tail(of: file, bytes: 512 * 1024) else { return nil }
        let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return Self.parse(tail: tail, fileDate: mtime)
    }

    public static func parse(tail: String, fileDate: Date) -> UsageSnapshot? {
        for line in tail.split(separator: "\n").reversed() where line.contains("rate_limits") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let rl = findKey("rate_limits", in: obj) as? [String: Any] else { continue }
            let lineDate = (findKey("timestamp", in: obj) as? String).flatMap(Fmt.isoDate) ?? fileDate
            let primary = window(rl["primary"], at: lineDate)
            let secondary = window(rl["secondary"], at: lineDate)
            if primary == nil && secondary == nil { continue }
            return UsageSnapshot(providerID: "codex", fiveHour: primary, weekly: secondary, updatedAt: lineDate)
        }
        return nil
    }

    static func window(_ any: Any?, at date: Date) -> UsageWindow? {
        guard let d = any as? [String: Any], let pct = Fmt.double(d["used_percent"]) else { return nil }
        var reset = Fmt.date(d["resets_at"])
        if reset == nil, let secs = Fmt.double(d["resets_in_seconds"]) {
            reset = date.addingTimeInterval(secs)
        }
        return UsageWindow(usedPercent: pct, resetsAt: reset)
    }

    static func findKey(_ key: String, in obj: Any, depth: Int = 0) -> Any? {
        guard depth < 6 else { return nil }
        if let d = obj as? [String: Any] {
            if let v = d[key] { return v }
            for v in d.values { if let f = findKey(key, in: v, depth: depth + 1) { return f } }
        } else if let a = obj as? [Any] {
            for v in a { if let f = findKey(key, in: v, depth: depth + 1) { return f } }
        }
        return nil
    }

    /// Walks YYYY/MM/DD newest-first instead of enumerating every log ever written.
    private func newestLog() -> URL? {
        let fm = FileManager.default
        func children(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        for year in children(root).prefix(2) {
            for month in children(year).prefix(2) {
                for day in children(month).prefix(3) {
                    let logs = children(day).filter { $0.pathExtension == "jsonl" }
                    let newest = logs.max {
                        let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        return a < b
                    }
                    if let newest { return newest }
                }
            }
        }
        return nil
    }

    public static func tail(of url: URL, bytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Forecast

public struct UsageSample: Codable, Equatable, Sendable {
    /// Epoch seconds.
    public var t: Double
    public var pct: Double
    /// Reset time of the window the sample belongs to (epoch seconds).
    public var reset: Double?

    public init(t: Double, pct: Double, reset: Double?) {
        self.t = t
        self.pct = pct
        self.reset = reset
    }
}

public enum Forecast {
    public enum Result: Equatable, Sendable {
        case hitsLimit(at: Date)
        case staysUnder
        case unknown
    }

    /// Percent per minute from a least-squares fit over recent samples of the current window.
    /// Needs at least two samples spanning four minutes, otherwise nil.
    public static func ratePerMinute(samples: [UsageSample], currentReset: Date?, now: Date,
                                     lookback: TimeInterval = 45 * 60) -> Double? {
        let from = now.timeIntervalSince1970 - lookback
        let resetT = currentReset?.timeIntervalSince1970
        let pts = samples.filter { s in
            guard s.t >= from else { return false }
            guard let resetT else { return true }
            // Same window: reset times agree within a minute.
            return s.reset.map { abs($0 - resetT) < 60 } ?? true
        }
        guard pts.count >= 2, let first = pts.first, let last = pts.last, last.t - first.t >= 240 else { return nil }
        let n = Double(pts.count)
        let xs = pts.map { ($0.t - first.t) / 60 }
        let ys = pts.map(\.pct)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) {
            num += (x - mx) * (y - my)
            den += (x - mx) * (x - mx)
        }
        guard den > 0 else { return nil }
        return num / den
    }

    /// Fallback when there are too few percent samples: scale recent token throughput
    /// by how many percent the tokens of this window have cost so far.
    public static func tokenRatePerMinute(currentPercent: Double, tokensInWindow: Double,
                                          tokensRecent: Double, recentMinutes: Double) -> Double? {
        guard currentPercent > 0, tokensInWindow > 0, recentMinutes > 0 else { return nil }
        let pctPerToken = currentPercent / tokensInWindow
        return tokensRecent / recentMinutes * pctPerToken
    }

    public static func project(window: UsageWindow, ratePerMinute: Double?, now: Date) -> Result {
        guard let rate = ratePerMinute else { return .unknown }
        if window.usedPercent >= 100 { return .hitsLimit(at: now) }
        guard rate > 0.0001 else { return .staysUnder }
        let minutes = (100 - window.usedPercent) / rate
        let at = now.addingTimeInterval(minutes * 60)
        if let reset = window.resetsAt, at >= reset { return .staysUnder }
        return .hitsLimit(at: at)
    }

    /// Keeps the history small: last 6 hours, and a sample only when the value moved
    /// or five minutes passed.
    public static func append(_ s: UsageSample, to history: inout [UsageSample]) {
        if let last = history.last, last.pct == s.pct, last.reset == s.reset, s.t - last.t < 300 { return }
        history.append(s)
        let cutoff = s.t - 6 * 3600
        history.removeAll { $0.t < cutoff }
    }
}

// MARK: - Pace

public enum Pace {
    /// How far through its window a limit is (0…1): where usage would be if spent evenly.
    public static func elapsed(resetsAt: Date?, window: TimeInterval, now: Date) -> Double? {
        guard let resetsAt else { return nil }
        let left = resetsAt.timeIntervalSince(now)
        guard left > 0, left <= window + 60 else { return nil }
        return min(max(1 - left / window, 0), 1)
    }

    /// Positive: used more than an even pace (percentage points).
    public static func lead(usedPercent: Double, elapsed: Double) -> Double {
        usedPercent - elapsed * 100
    }
}

// MARK: - Context window per session

/// ~/.notch-island/usage/context/<session-id>.json, written by the status-line command.
public enum ContextUsage {
    public static var directory: URL { NIPaths.usage.appendingPathComponent("context", isDirectory: true) }

    public static func url(for sessionId: String) -> URL {
        let safe = sessionId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appendingPathComponent("\(safe).json")
    }

    /// session id → used percent
    public static func loadAll(maxAge: TimeInterval = 86_400, now: Date = Date()) -> [String: Double] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var map: [String: Double] = [:]
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pct = Fmt.double(o["pct"]) else { continue }
            if let ts = Fmt.double(o["ts"]), now.timeIntervalSince1970 - ts > maxAge {
                try? FileManager.default.removeItem(at: f)
                continue
            }
            map[f.deletingPathExtension().lastPathComponent] = pct
        }
        return map
    }
}
