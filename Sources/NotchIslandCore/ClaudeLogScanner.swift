import Foundation

/// Incrementally reads Claude Code session logs (~/.claude/projects/**/*.jsonl) and keeps
/// per-request token counts for the last few hours. Only new bytes are read on each scan.
/// Used for the burn rate and as a fallback when no rate-limit percent is available.
/// Not thread-safe: the app confines each instance to one serial queue.
public final class ClaudeLogScanner: @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public var t: Double
        public var tokens: Double
    }

    private let root: URL
    private let horizon: TimeInterval
    private var offsets: [String: UInt64] = [:]
    private var seen = Set<String>()
    public private(set) var entries: [Entry] = []

    public init(root: URL = NIPaths.claudeProjects, horizon: TimeInterval = 5 * 3600) {
        self.root = root
        self.horizon = horizon
    }

    /// Cache reads are cheap for limits, so they are weighted down.
    public static func weightedTokens(_ usage: [String: Any]) -> Double {
        func n(_ k: String) -> Double { Fmt.double(usage[k]) ?? 0 }
        return n("input_tokens") + n("output_tokens") + n("cache_creation_input_tokens") + 0.1 * n("cache_read_input_tokens")
    }

    public func scan(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-horizon)
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let m = v.contentModificationDate, m >= cutoff else { continue }
            read(url, since: cutoff.timeIntervalSince1970)
        }
        entries.removeAll { $0.t < cutoff.timeIntervalSince1970 }
        if seen.count > 50_000 { seen.removeAll() }
    }

    public func tokens(since: Date) -> Double {
        let t = since.timeIntervalSince1970
        return entries.reduce(0) { $1.t >= t ? $0 + $1.tokens : $0 }
    }

    private func read(_ url: URL, since: Double) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var start = offsets[url.path] ?? 0
        if start > size { start = 0 } // truncated or replaced
        guard size > start else { return }
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd(), let lastNL = data.lastIndex(of: 0x0A) else { return }
        // Only consume complete lines; a half-written last line is read next time.
        let complete = data[data.startIndex...lastNL]
        offsets[url.path] = start + UInt64(complete.count)
        for line in complete.split(separator: 0x0A) {
            guard line.count > 20, let entry = parse(Data(line), since: since) else { continue }
            entries.append(entry)
        }
    }

    private func parse(_ line: Data, since: Double) -> Entry? {
        // Cheap pre-filter before JSON parsing.
        guard line.range(of: Data("\"usage\"".utf8)) != nil,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let ts = (obj["timestamp"] as? String).flatMap(Fmt.isoDate)?.timeIntervalSince1970,
              ts >= since
        else { return nil }
        // Streaming writes the same message more than once; count each request once.
        let key = (obj["requestId"] as? String) ?? (msg["id"] as? String) ?? (obj["uuid"] as? String) ?? ""
        if !key.isEmpty {
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
        }
        let tokens = Self.weightedTokens(usage)
        return tokens > 0 ? Entry(t: ts, tokens: tokens) : nil
    }
}
