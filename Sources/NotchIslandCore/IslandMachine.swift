import Foundation

public enum IslandTab: String, CaseIterable, Sendable {
    case overview, radar, settings
    public var title: String { rawValue.capitalized }
}

public enum AlertKind: Sendable {
    case needsYou, done, failed
    /// Informational, e.g. a usage limit crossing 80%.
    case warning
}

public struct IslandAlert: Equatable, Identifiable, Sendable {
    public let id: String
    public var kind: AlertKind
    public var title: String
    public var subtitle: String
    /// The command or file the permission is about (shown in SF Mono).
    public var detail: String?
    public var sessionId: String?
    /// Set only for blocking permission requests: Allow/Deny are possible.
    public var requestId: String?
    public var cwd: String?
    /// A process to bring forward with "Open terminal" (shell commands).
    public var pid: Int32?
    public var createdAt: Date
    /// done/failed whose 4 s ran out while the pointer was over it; removed on hover end.
    public var expired = false
    /// Auto-close delay for this alert when it should stay longer than the default 4 s.
    public var lingers: TimeInterval?

    public init(id: String, kind: AlertKind, title: String, subtitle: String, detail: String? = nil,
                sessionId: String? = nil, requestId: String? = nil, cwd: String? = nil,
                pid: Int32? = nil, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.sessionId = sessionId
        self.requestId = requestId
        self.cwd = cwd
        self.pid = pid
        self.createdAt = createdAt
    }
}

public enum IslandPhase: Equatable, Sendable { case idle, compact, expanded, alert }

/// The whole island state. `phase` is derived, so there is exactly one source of truth.
/// Priority: alert > expanded > compact > idle.
public struct IslandState: Equatable, Sendable {
    public var busy = false
    public var hovering = false
    /// Opened from the menu bar item; stays open until a click outside.
    public var pinned = false
    public var tab: IslandTab = .overview
    /// needs-you alerts first, then done/failed in arrival order.
    public var alerts: [IslandAlert] = []

    public init() {}

    public var phase: IslandPhase {
        if !alerts.isEmpty { return .alert }
        if hovering || pinned { return .expanded }
        return busy ? .compact : .idle
    }

    public var needsYou: IslandAlert? { alerts.first { $0.kind == .needsYou } }

    /// What the alert view shows: the needs-you card alone, or up to three done/failed rows.
    public var visibleAlerts: [IslandAlert] {
        if let n = needsYou { return [n] }
        return Array(alerts.suffix(IslandMachine.maxResultRows))
    }
}

public enum IslandInput: Equatable, Sendable {
    case hoverBegan
    case hoverEnded
    case busyChanged(Bool)
    case alert(IslandAlert)
    case alertTimedOut(String)
    case dismissAlert(String)
    /// A session went busy again: its plain "needs you" notifications are stale.
    case sessionResumed(String)
    /// A blocking permission request was answered or timed out.
    case requestResolved(String)
    case selectTab(IslandTab)
    case setPinned(Bool)
}

public enum IslandEffect: Equatable, Sendable {
    case scheduleAutoDismiss(id: String, after: TimeInterval)
}

public enum IslandMachine {
    public static let autoDismiss: TimeInterval = 4
    public static let maxResultRows = 3

    /// Pure reducer. Timers are returned as effects and run by the caller,
    /// which feeds `.alertTimedOut` back in; a stale timer finds no alert and does nothing.
    @discardableResult
    public static func reduce(_ s: inout IslandState, _ input: IslandInput) -> [IslandEffect] {
        switch input {
        case .hoverBegan:
            s.hovering = true

        case .hoverEnded:
            s.hovering = false
            s.alerts.removeAll { $0.expired }

        case .busyChanged(let busy):
            s.busy = busy

        case .alert(let a):
            return receive(a, into: &s)

        case .alertTimedOut(let id):
            guard let i = s.alerts.firstIndex(where: { $0.id == id }) else { return [] }
            guard s.alerts[i].kind != .needsYou else { return [] }
            // Hidden behind a needs-you card: give it its full 4 s once it is visible.
            if s.needsYou != nil { return [.scheduleAutoDismiss(id: id, after: autoDismiss)] }
            if s.hovering { s.alerts[i].expired = true } else { s.alerts.remove(at: i) }

        case .dismissAlert(let id):
            s.alerts.removeAll { $0.id == id }

        case .sessionResumed(let sid):
            s.alerts.removeAll { $0.kind == .needsYou && $0.requestId == nil && $0.sessionId == sid }

        case .requestResolved(let rid):
            s.alerts.removeAll { $0.requestId == rid }

        case .selectTab(let tab):
            s.tab = tab

        case .setPinned(let pinned):
            s.pinned = pinned
            if pinned { s.alerts.removeAll { $0.kind != .needsYou } }
        }
        return []
    }

    private static func receive(_ a: IslandAlert, into s: inout IslandState) -> [IslandEffect] {
        switch a.kind {
        case .needsYou:
            if let sid = a.sessionId {
                // A plain notification never replaces a pending Allow/Deny for the same session.
                if a.requestId == nil,
                   s.alerts.contains(where: { $0.kind == .needsYou && $0.sessionId == sid && $0.requestId != nil }) {
                    return []
                }
                s.alerts.removeAll { $0.kind == .needsYou && $0.sessionId == sid && $0.requestId == nil }
            }
            s.alerts.removeAll { $0.id == a.id }
            let insertAt = s.alerts.firstIndex { $0.kind != .needsYou } ?? s.alerts.endIndex
            s.alerts.insert(a, at: insertAt)
            return []

        case .done, .failed, .warning:
            if let sid = a.sessionId {
                // The turn ended, so whatever it was waiting for is over.
                s.alerts.removeAll { $0.kind == .needsYou && $0.sessionId == sid }
            }
            s.alerts.removeAll { $0.id == a.id }
            s.alerts.append(a)
            // Keep at most three result rows.
            let results = s.alerts.filter { $0.kind != .needsYou }
            if results.count > maxResultRows {
                let drop = Set(results.prefix(results.count - maxResultRows).map(\.id))
                s.alerts.removeAll { drop.contains($0.id) }
            }
            return [.scheduleAutoDismiss(id: a.id, after: a.lingers ?? autoDismiss)]
        }
    }
}

// MARK: - While you were away

/// Collapses alerts that arrived while the user was away into one summary row.
public enum AwayDigest {
    public static func make(_ items: [IslandAlert], awayFor: TimeInterval, now: Date = Date()) -> IslandAlert? {
        guard !items.isEmpty else { return nil }
        let kind: AlertKind = items.contains { $0.kind == .failed } ? .failed
            : items.contains { $0.kind == .warning } ? .warning : .done
        var parts = items.prefix(3).map(\.title)
        if items.count > 3 { parts.append("+\(items.count - 3) more") }
        var alert = IslandAlert(id: "away-\(Int(now.timeIntervalSince1970))", kind: kind,
                                title: "While you were away · \(Fmt.minutes(awayFor))",
                                subtitle: parts.joined(separator: " · "), createdAt: now)
        alert.lingers = 8
        return alert
    }
}
