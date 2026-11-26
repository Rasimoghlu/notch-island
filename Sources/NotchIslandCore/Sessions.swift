import Foundation

/// ~/.claude/sessions/<pid>.json — written by each running Claude Code process.
public struct ClaudeSession: Equatable, Identifiable, Sendable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String
    /// "busy" while a turn runs, "idle" otherwise.
    public var status: String
    public var name: String?
    public var kind: String?
    public var updatedAt: Date
    public var statusSince: Date

    public var id: String { sessionId }
    public var isBusy: Bool { status == "busy" }
    public var project: String { Fmt.project(cwd) ?? name ?? "claude" }

    public init(pid: Int32, sessionId: String, cwd: String, status: String, name: String? = nil,
                kind: String? = nil, updatedAt: Date, statusSince: Date) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.status = status
        self.name = name
        self.kind = kind
        self.updatedAt = updatedAt
        self.statusSince = statusSince
    }

    public static func parse(_ data: Data) -> ClaudeSession? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = Fmt.double(o["pid"]).map({ Int32($0) }),
              let sid = o["sessionId"] as? String
        else { return nil }
        let updated = Fmt.date(o["updatedAt"]) ?? Fmt.date(o["startedAt"]) ?? Date()
        return ClaudeSession(pid: pid, sessionId: sid, cwd: (o["cwd"] as? String) ?? "",
                             status: (o["status"] as? String) ?? "idle", name: o["name"] as? String,
                             kind: o["kind"] as? String, updatedAt: updated,
                             statusSince: Fmt.date(o["statusUpdatedAt"]) ?? updated)
    }

    public static func loadAll(from dir: URL = NIPaths.claudeSessions) -> [ClaudeSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap(parse) }
            .filter { AppLiveness.isAlive($0.pid) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// What happened in the turn that just ended, read from the tail of the transcript.
public struct TurnSummary: Equatable, Sendable {
    public var duration: TimeInterval?
    public var filesChanged: Int

    public init(duration: TimeInterval?, filesChanged: Int) {
        self.duration = duration
        self.filesChanged = filesChanged
    }

    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    public static func read(transcript url: URL, now: Date = Date()) -> TurnSummary {
        guard let h = try? FileHandle(forReadingFrom: url) else { return TurnSummary(duration: nil, filesChanged: 0) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let window: UInt64 = 4 * 1024 * 1024
        try? h.seek(toOffset: size > window ? size - window : 0)
        let data = (try? h.readToEnd()) ?? Data()
        return parse(tail: String(decoding: data, as: UTF8.self), now: now)
    }

    /// Walks back to the last real user prompt, collecting edited files on the way.
    public static func parse(tail: String, now: Date) -> TurnSummary {
        var files = Set<String>()
        for line in tail.split(separator: "\n").reversed() {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let type = o["type"] as? String
            let message = o["message"] as? [String: Any]
            if type == "assistant", let content = message?["content"] as? [[String: Any]] {
                for item in content where item["type"] as? String == "tool_use" {
                    guard let name = item["name"] as? String, editTools.contains(name),
                          let input = item["input"] as? [String: Any] else { continue }
                    if let p = (input["file_path"] ?? input["notebook_path"]) as? String { files.insert(p) }
                }
            } else if type == "user", isPrompt(o, message) {
                let start = (o["timestamp"] as? String).flatMap(Fmt.isoDate)
                return TurnSummary(duration: start.map { now.timeIntervalSince($0) }, filesChanged: files.count)
            }
        }
        return TurnSummary(duration: nil, filesChanged: files.count)
    }

    private static func isPrompt(_ o: [String: Any], _ message: [String: Any]?) -> Bool {
        if (o["isMeta"] as? Bool) == true || o["toolUseResult"] != nil { return false }
        switch message?["content"] {
        case is String:
            return true
        case let items as [[String: Any]]:
            return items.contains { $0["type"] as? String == "text" } && !items.contains { $0["type"] as? String == "tool_result" }
        default:
            return false
        }
    }
}

/// Who you are to git and GitHub on this Mac, read from local files only (no network).
public struct GitIdentity: Equatable, Sendable {
    public var githubUser: String?
    public var name: String?
    public var email: String?

    public init(githubUser: String?, name: String?, email: String?) {
        self.githubUser = githubUser
        self.name = name
        self.email = email
    }

    /// `user:` under `github.com:` in gh's ~/.config/gh/hosts.yml.
    public static func githubUser(fromHostsYAML text: String) -> String? {
        var inGitHub = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inGitHub = line.trimmingCharacters(in: .whitespaces).hasPrefix("github.com:")
                continue
            }
            guard inGitHub else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("user:") {
                let v = t.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }
}
