import Foundation

/// Decides when to warn about usage limits: once per threshold per window, and once when a
/// window you were warned about resets. Pure and Codable so it survives app restarts.
public struct LimitWatch: Codable, Equatable, Sendable {
    public struct Track: Codable, Equatable, Sendable {
        /// Reset time of the window being tracked (epoch seconds).
        public var reset: Double
        /// Highest threshold already announced for this window (0 = none).
        public var notified: Int
    }

    public enum Signal: Equatable, Sendable {
        case crossed(window: String, threshold: Int, percent: Double, resetsAt: Date?)
        case reset(window: String)
    }

    public static let thresholds = [80, 90, 95]

    public private(set) var tracks: [String: Track] = [:]

    public init() {}

    /// `window` is a stable key such as "claude.5h". `usage` is the current reading
    /// (already reset-adjusted), or nil when nothing is known.
    public mutating func update(window: String, usage: UsageWindow?, now: Date) -> [Signal] {
        var signals: [Signal] = []
        let t = now.timeIntervalSince1970

        // The tracked window has ended.
        if let track = tracks[window], track.reset <= t {
            if track.notified > 0 { signals.append(.reset(window: window)) }
            tracks[window] = nil
        }

        guard let usage, let reset = usage.resetsAt?.timeIntervalSince1970, reset > t else { return signals }

        // A different window (reset time moved by more than a minute): start fresh.
        if let track = tracks[window], abs(track.reset - reset) > 60 {
            tracks[window] = nil
        }
        var track = tracks[window] ?? Track(reset: reset, notified: 0)
        track.reset = reset

        // Announce only the highest newly crossed threshold, so a jump from 70% to 96% is one alert.
        if let hit = Self.thresholds.last(where: { Double($0) <= usage.usedPercent }), hit > track.notified {
            track.notified = hit
            signals.append(.crossed(window: window, threshold: hit, percent: usage.usedPercent, resetsAt: usage.resetsAt))
        }
        tracks[window] = track
        return signals
    }

    /// Windows that will need a `.reset` signal, with their reset times (for a one-shot timer).
    public var pendingResets: [(window: String, at: Date)] {
        tracks.filter { $0.value.notified > 0 }
            .map { ($0.key, Date(timeIntervalSince1970: $0.value.reset)) }
    }
}
