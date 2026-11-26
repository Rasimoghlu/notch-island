import Foundation
import NotchIslandCore

// notch-hook — called by Claude Code, never by the user directly.
//
//   notch-hook claude Notification|Stop|StopFailure|PermissionRequest   (hook JSON on stdin)
//   notch-hook statusline                                              (status-line JSON on stdin)
//
// Rules: always exit 0 (exit code 2 would block Claude), print nothing unless Claude
// should read it, and stay silent when the app is not running.

setvbuf(stdout, nil, _IOFBF, 0)

let args = Array(CommandLine.arguments.dropFirst())

func readStdin() -> [String: Any] {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
}

func emit(_ event: AgentEvent) {
    try? EventWriter.write(event)
}

func printJSON(_ obj: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: obj) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

// MARK: - Claude Code hooks

func describeTool(_ name: String, _ input: [String: Any]) -> String {
    for key in ["command", "file_path", "notebook_path", "url", "pattern", "path", "query"] {
        if let v = input[key] as? String, !v.isEmpty { return v }
    }
    return name
}

func claudeHook(_ event: String) {
    let json = readStdin()
    guard AppLiveness.runningPid() != nil else { return }
    let sid = json["session_id"] as? String
    let cwd = json["cwd"] as? String

    switch event {
    case "Notification":
        // The idle reminder follows a Stop we already announced.
        if (json["notification_type"] as? String) == "idle_prompt" { return }
        let message = (json["message"] as? String) ?? "Claude is waiting for you"
        let title = message.localizedCaseInsensitiveContains("permission") ? "Claude needs permission" : "Claude needs you"
        emit(AgentEvent(source: "claude", kind: .needsYou, sessionId: sid, cwd: cwd, title: title, message: message))

    case "Stop":
        var summary = TurnSummary(duration: nil, filesChanged: 0)
        if let path = json["transcript_path"] as? String {
            summary = TurnSummary.read(transcript: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        emit(AgentEvent(source: "claude", kind: .done, sessionId: sid, cwd: cwd, title: "Claude finished",
                        durationMs: summary.duration.map { Int($0 * 1000) }, filesChanged: summary.filesChanged))

    case "StopFailure":
        let reason = ["error", "message", "reason", "error_type"].lazy.compactMap { json[$0] as? String }.first
        emit(AgentEvent(source: "claude", kind: .failed, sessionId: sid, cwd: cwd,
                        title: "Claude stopped with an error", message: reason))

    case "PermissionRequest":
        permissionRequest(json, sid: sid, cwd: cwd)

    default:
        return
    }
}

/// Shows Allow/Deny in the notch and waits for the answer. On timeout (or if the app quits)
/// it prints nothing, so Claude Code falls back to its normal terminal prompt.
func permissionRequest(_ json: [String: Any], sid: String?, cwd: String?) {
    let requestId = UUID().uuidString.lowercased()
    let tool = (json["tool_name"] as? String) ?? "tool"
    let input = (json["tool_input"] as? [String: Any]) ?? [:]
    let timeout = Double(ProcessInfo.processInfo.environment["NOTCH_ISLAND_PERMISSION_TIMEOUT"] ?? "") ?? 20

    emit(AgentEvent(source: "claude", kind: .permission, sessionId: sid, cwd: cwd,
                    title: "Claude needs permission", message: tool, command: describeTool(tool, input),
                    tool: tool, requestId: requestId))

    let responseURL = PermissionResponse.url(for: requestId)
    let deadline = Date().addingTimeInterval(timeout)
    var polls = 0
    while Date() < deadline {
        // A half-written file fails to decode: keep polling and only delete a valid answer.
        if let data = try? Data(contentsOf: responseURL),
           let response = try? JSONDecoder().decode(PermissionResponse.self, from: data) {
            try? FileManager.default.removeItem(at: responseURL)
            var decision: [String: Any] = ["behavior": response.decision.rawValue]
            if response.decision == .deny { decision["message"] = "Denied from Notch Island." }
            printJSON(["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]])
            // Clears the alert even if the answer came from somewhere other than the notch.
            emit(AgentEvent(source: "claude", kind: .permissionResolved, sessionId: sid, cwd: cwd, requestId: requestId))
            return
        }
        usleep(150_000)
        polls += 1
        if polls % 20 == 0, AppLiveness.runningPid() == nil { break }
    }
    emit(AgentEvent(source: "claude", kind: .permissionResolved, sessionId: sid, cwd: cwd, requestId: requestId))
}

// MARK: - Status line

/// Saves `rate_limits` for the app, then prints a status line (or runs the user's previous one).
func statusline() {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    let model = ((json["model"] as? [String: Any])?["display_name"] as? String) ?? "Claude"
    let rateLimits = json["rate_limits"] as? [String: Any]

    if let rateLimits {
        saveUsage(rateLimits, model: model)
    }
    if let sid = json["session_id"] as? String,
       let pct = Fmt.double((json["context_window"] as? [String: Any])?["used_percentage"]) {
        saveContext(sessionId: sid, percent: pct)
    }

    if let chain = try? String(contentsOf: NIPaths.statuslineChainFile, encoding: .utf8),
       !chain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        runChained(chain, input: data)
        return
    }

    var parts = [model]
    if let five = (rateLimits?["five_hour"] as? [String: Any]).flatMap({ Fmt.double($0["used_percentage"]) }) {
        parts.append("5h \(Int(five.rounded()))%")
    }
    if let week = (rateLimits?["seven_day"] as? [String: Any]).flatMap({ Fmt.double($0["used_percentage"]) }) {
        parts.append("wk \(Int(week.rounded()))%")
    }
    if let dir = (json["workspace"] as? [String: Any])?["current_dir"] as? String, let p = Fmt.project(dir) {
        parts.append(p)
    }
    print(parts.joined(separator: " · "))
}

func saveUsage(_ rateLimits: [String: Any], model: String) {
    NIPaths.ensureDirectories()
    let url = NIPaths.claudeUsageFile
    let newLimits = (try? JSONSerialization.data(withJSONObject: rateLimits, options: [.sortedKeys])) ?? Data()
    // The status line re-renders often: rewrite only when the numbers change or every minute.
    if let old = try? Data(contentsOf: url),
       let obj = (try? JSONSerialization.jsonObject(with: old)) as? [String: Any],
       let oldLimits = obj["rate_limits"],
       let oldData = try? JSONSerialization.data(withJSONObject: oldLimits, options: [.sortedKeys]),
       oldData == newLimits,
       let ts = Fmt.double(obj["ts"]), Date().timeIntervalSince1970 - ts < 60 {
        return
    }
    let out: [String: Any] = ["ts": Date().timeIntervalSince1970, "model": model, "rate_limits": rateLimits]
    if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) {
        try? AtomicFile.write(data, to: url)
    }
}

/// Per-session context-window use, rewritten only when the whole-number percent changes.
func saveContext(sessionId: String, percent: Double) {
    let url = ContextUsage.url(for: sessionId)
    try? FileManager.default.createDirectory(at: ContextUsage.directory, withIntermediateDirectories: true)
    let rounded = percent.rounded()
    if let old = try? Data(contentsOf: url),
       let o = (try? JSONSerialization.jsonObject(with: old)) as? [String: Any],
       Fmt.double(o["pct"]) == rounded,
       let ts = Fmt.double(o["ts"]), Date().timeIntervalSince1970 - ts < 600 {
        return
    }
    let out: [String: Any] = ["pct": rounded, "ts": Date().timeIntervalSince1970]
    if let data = try? JSONSerialization.data(withJSONObject: out) {
        try? AtomicFile.write(data, to: url)
    }
}

func runChained(_ command: String, input: Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    let stdin = Pipe()
    p.standardInput = stdin
    p.standardOutput = FileHandle.standardOutput
    p.standardError = FileHandle.standardError
    guard (try? p.run()) != nil else { return }
    stdin.fileHandleForWriting.write(input)
    try? stdin.fileHandleForWriting.close()
    p.waitUntilExit()
}

// MARK: - Entry

switch args.first {
case "claude" where args.count >= 2:
    claudeHook(args[1])
case "statusline":
    statusline()
case "version":
    print("notch-hook 1")
default:
    FileHandle.standardError.write(Data("usage: notch-hook claude <Event> | statusline | version\n".utf8))
}
fflush(stdout)
exit(0)
