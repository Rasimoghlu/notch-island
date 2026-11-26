import Foundation

/// One thing Claude did (or is doing) in the current turn, in human words.
public struct LiveStep: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case edit, write, read, run, search, web, agent, plan, ask, message, other }

    public var id: String
    public var kind: Kind
    public var title: String
    /// No tool result yet: this step is in progress.
    public var pending: Bool

    public init(id: String, kind: Kind, title: String, pending: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.pending = pending
    }
}

/// A subagent launched with the `Agent` tool in the current turn.
public struct LiveAgent: Equatable, Sendable, Identifiable {
    /// The tool_use id of the launch.
    public var id: String
    public var description: String
    public var type: String?
    /// From the launch result ("agentId: …"); names the subagent's own transcript.
    public var agentId: String?
    /// The launch call has returned. Background agents return at once, so the app also
    /// checks the subagent transcript's last write time.
    public var launched: Bool
}

/// What Claude is doing in a session right now, read from the tail of its transcript.
public struct LiveActivity: Equatable, Sendable {
    public var turnStart: Date?
    /// Chronological; the last one is the current step.
    public var steps: [LiveStep]
    public var filesChanged: Int
    public var toolCalls: Int
    public var agents: [LiveAgent]

    public init(turnStart: Date? = nil, steps: [LiveStep] = [], filesChanged: Int = 0, toolCalls: Int = 0, agents: [LiveAgent] = []) {
        self.turnStart = turnStart
        self.steps = steps
        self.filesChanged = filesChanged
        self.toolCalls = toolCalls
        self.agents = agents
    }

    public var current: LiveStep? { steps.last }

    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// Walks back to the last real user prompt and collects the tool calls of this turn.
    public static func parse(tail: String) -> LiveActivity {
        var results: [String: String] = [:]   // tool_use_id → result text
        var uses: [(id: String, name: String, input: [String: Any])] = []
        var start: Date?

        for line in tail.split(separator: "\n").reversed() {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let type = o["type"] as? String
            let content = (o["message"] as? [String: Any])?["content"]
            if type == "assistant", let items = content as? [[String: Any]] {
                for item in items.reversed() where item["type"] as? String == "tool_use" {
                    guard let id = item["id"] as? String, let name = item["name"] as? String else { continue }
                    uses.append((id, name, (item["input"] as? [String: Any]) ?? [:]))
                }
            } else if type == "user" {
                if let items = content as? [[String: Any]], items.contains(where: { $0["type"] as? String == "tool_result" }) {
                    for item in items where item["type"] as? String == "tool_result" {
                        if let id = item["tool_use_id"] as? String { results[id] = text(of: item["content"]) }
                    }
                } else if isPrompt(o, content) {
                    start = (o["timestamp"] as? String).flatMap(Fmt.isoDate)
                    break
                }
            }
        }

        uses.reverse()
        var files = Set<String>()
        var agents: [LiveAgent] = []
        let steps = uses.map { use -> LiveStep in
            if editTools.contains(use.name), let p = (use.input["file_path"] ?? use.input["notebook_path"]) as? String { files.insert(p) }
            if use.name == "Agent" || use.name == "Task" {
                let result = results[use.id]
                agents.append(LiveAgent(id: use.id,
                                        description: (use.input["description"] as? String) ?? "agent",
                                        type: use.input["subagent_type"] as? String,
                                        agentId: result.flatMap(agentId(in:)),
                                        launched: result != nil))
            }
            return step(name: use.name, input: use.input, id: use.id, pending: results[use.id] == nil)
        }
        return LiveActivity(turnStart: start, steps: steps, filesChanged: files.count, toolCalls: uses.count, agents: agents)
    }

    /// The latest tool call in a (sub)agent transcript.
    public static func lastStep(tail: String) -> LiveStep? {
        for line in tail.split(separator: "\n").reversed() where line.contains("\"tool_use\"") {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let items = (o["message"] as? [String: Any])?["content"] as? [[String: Any]],
                  let use = items.last(where: { $0["type"] as? String == "tool_use" }),
                  let name = use["name"] as? String else { continue }
            return step(name: name, input: (use["input"] as? [String: Any]) ?? [:], id: (use["id"] as? String) ?? "", pending: true)
        }
        return nil
    }

    /// Tool call → "Editing Cards.swift", "Running swift build", "computer · claude-in-chrome".
    public static func step(name: String, input: [String: Any], id: String, pending: Bool) -> LiveStep {
        func file(_ key: String = "file_path") -> String {
            ((input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }) ?? "a file"
        }
        func str(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        let kind: LiveStep.Kind
        let title: String
        switch name {
        case "Edit", "MultiEdit": kind = .edit; title = "Editing \(file())"
        case "NotebookEdit": kind = .edit; title = "Editing \(file("notebook_path"))"
        case "Write": kind = .write; title = "Writing \(file())"
        case "Read": kind = .read; title = "Reading \(file())"
        case "Bash":
            kind = .run
            if let d = str("description") { title = d.prefix(1).uppercased() + d.dropFirst() }
            else { title = "Running \(Fmt.truncate(str("command") ?? "a command", 40))" }
        case "Grep", "Glob": kind = .search; title = "Searching \(Fmt.truncate(str("pattern") ?? "files", 30))"
        case "WebSearch": kind = .web; title = "Searching the web"
        case "WebFetch":
            kind = .web
            title = "Reading \(str("url").flatMap { URL(string: $0)?.host } ?? "a web page")"
        case "Agent", "Task": kind = .agent; title = "Agent: \(str("description") ?? "working")"
        case "TodoWrite": kind = .plan; title = "Updating the plan"
        case "AskUserQuestion": kind = .ask; title = "Asking you a question"
        case "SendMessage": kind = .message; title = "Messaging \(str("to") ?? "an agent")"
        case "Skill": kind = .plan; title = "Skill: \(str("skill") ?? "running")"
        case "ToolSearch": kind = .other; title = "Loading tools"
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
                // mcp__server__tool → "tool · server"
                let pieces = name.dropFirst(5).components(separatedBy: "__")
                let server = pieces.first ?? parts.last ?? "mcp"
                let tool = pieces.count > 1 ? pieces[1].replacingOccurrences(of: "_", with: " ") : server
                kind = tool.contains("navigate") || tool.contains("browser") || server.contains("chrome") ? .web : .other
                title = "\(tool) · \(server)"
            } else {
                kind = .other
                title = name
            }
        }
        return LiveStep(id: id, kind: kind, title: title, pending: pending)
    }

    static func agentId(in text: String) -> String? {
        guard let r = text.range(of: #"agentId: ([A-Za-z0-9]+)"#, options: .regularExpression) else { return nil }
        return String(text[r].dropFirst("agentId: ".count))
    }

    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        if let items = content as? [[String: Any]] {
            return items.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    private static func isPrompt(_ o: [String: Any], _ content: Any?) -> Bool {
        if (o["isMeta"] as? Bool) == true || o["toolUseResult"] != nil { return false }
        switch content {
        case let s as String: return !s.hasPrefix("<")   // skip system-reminder / command wrappers
        case let items as [[String: Any]]: return items.contains { $0["type"] as? String == "text" }
        default: return false
        }
    }
}
