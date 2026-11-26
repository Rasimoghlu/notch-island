import Foundation

/// Small, locale-light formatting helpers shared by the UI and the hook.
public enum Fmt {
    /// "38s", "3 min", "1h 42m"
    public static func minutes(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h)h" : "\(h)h \(r)m"
    }

    /// Stopwatch style: "38s", "2:14", "1:02:03"
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    public static func resetsIn(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let h = s / 3600, m = (s % 3600) / 60
        if h >= 24 { return "Resets in \(h / 24)d \(h % 24)h" }
        return h > 0 ? "Resets in \(h)h \(m)m" : "Resets in \(m)m"
    }

    public static func ago(_ seconds: TimeInterval) -> String {
        seconds < 45 ? "just now" : "\(minutes(seconds)) ago"
    }

    public static func timeOfDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    public static func project(_ path: String?) -> String? {
        guard let path, !path.isEmpty, path != "/" else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Accepts epoch seconds, epoch milliseconds, numeric strings and ISO-8601 strings.
    public static func date(_ any: Any?) -> Date? {
        switch any {
        case let n as NSNumber:
            let v = n.doubleValue
            guard v > 0 else { return nil }
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        case let s as String:
            if let v = Double(s) { return date(NSNumber(value: v)) }
            return isoDate(s)
        default:
            return nil
        }
    }

    public static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    public static func double(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    public static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }
}
