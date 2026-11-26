import Foundation

/// One JSON file in ~/.notch-island/events/. Written by `notch-hook` (Claude Code hooks)
/// and by the zsh hook; read and deleted by the app.
public struct AgentEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Blocking PermissionRequest hook is waiting for Allow/Deny (has `requestId`).
        case permission
        /// The permission hook gave up (timeout) or got its answer elsewhere.
        case permissionResolved = "permission_resolved"
        /// Notification hook: Claude is waiting for the user.
        case needsYou = "needs_you"
        case done
        case failed
        /// A shell command finished (zsh precmd).
        case commandEnd = "command_end"
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    public var v: Int?
    public var id: String
    /// Epoch seconds.
    public var ts: Double
    /// "claude", "codex" or "shell"
    public var source: String
    public var kind: Kind
    public var sessionId: String?
    public var cwd: String?
    public var title: String?
    public var message: String?
    public var command: String?
    public var tool: String?
    public var exitCode: Int?
    public var durationMs: Int?
    public var filesChanged: Int?
    public var requestId: String?
    public var shellPid: Int?

    public init(id: String = AgentEvent.newID(), ts: Double = Date().timeIntervalSince1970,
                source: String, kind: Kind, sessionId: String? = nil, cwd: String? = nil,
                title: String? = nil, message: String? = nil, command: String? = nil, tool: String? = nil,
                exitCode: Int? = nil, durationMs: Int? = nil, filesChanged: Int? = nil,
                requestId: String? = nil, shellPid: Int? = nil) {
        self.v = 1
        self.id = id
        self.ts = ts
        self.source = source
        self.kind = kind
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.message = message
        self.command = command
        self.tool = tool
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.filesChanged = filesChanged
        self.requestId = requestId
        self.shellPid = shellPid
    }

    public var date: Date { Date(timeIntervalSince1970: ts) }
    public var project: String? { Fmt.project(cwd) }

    /// Time-sortable unique id: milliseconds + random suffix.
    public static func newID() -> String {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        return "\(ms)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func decode(_ data: Data) -> AgentEvent? {
        try? decoder.decode(AgentEvent.self, from: data)
    }
}

/// ~/.notch-island/shell/<pid>.json — the command an interactive zsh is running right now.
public struct RunningCommand: Codable, Equatable, Identifiable, Sendable {
    public var pid: Int
    public var command: String
    public var cwd: String?
    /// Epoch seconds.
    public var started: Double

    public init(pid: Int, command: String, cwd: String?, started: Double) {
        self.pid = pid
        self.command = command
        self.cwd = cwd
        self.started = started
    }

    public var id: Int { pid }
    public var startDate: Date { Date(timeIntervalSince1970: started) }
}

public enum EventWriter {
    public static func write(_ event: AgentEvent) throws {
        NIPaths.ensureDirectories()
        let data = try AgentEvent.encoder.encode(event)
        try AtomicFile.write(data, to: NIPaths.events.appendingPathComponent("\(event.id).json"))
    }
}

/// The app's answer to a blocking permission request.
public struct PermissionResponse: Codable, Equatable, Sendable {
    public enum Decision: String, Codable, Sendable { case allow, deny }
    public var decision: Decision

    public init(decision: Decision) { self.decision = decision }

    public static func url(for requestId: String) -> URL {
        // requestId comes from our own hook (a UUID); strip anything path-like anyway.
        let safe = requestId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return NIPaths.responses.appendingPathComponent("\(safe).json")
    }
}
