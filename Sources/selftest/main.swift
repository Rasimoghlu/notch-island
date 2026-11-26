import Foundation
import NotchIslandCore

// `swift run selftest` — assertion tests for the pure logic.
// (XCTest and swift-testing do not run with Command Line Tools alone.)

var failures = 0
var checks = 0

func check(_ ok: @autoclosure () -> Bool, _ what: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if !ok() {
        failures += 1
        print("FAIL \(file):\(line)  \(what)")
    }
}

func alert(_ id: String, _ kind: AlertKind, session: String? = nil, request: String? = nil) -> IslandAlert {
    IslandAlert(id: id, kind: kind, title: id, subtitle: "", sessionId: session, requestId: request)
}

// MARK: State machine

do {
    var s = IslandState()
    check(s.phase == .idle, "starts idle")
    IslandMachine.reduce(&s, .busyChanged(true))
    check(s.phase == .compact, "busy → compact")
    IslandMachine.reduce(&s, .hoverBegan)
    check(s.phase == .expanded, "hover → expanded")
    IslandMachine.reduce(&s, .hoverEnded)
    check(s.phase == .compact, "hover end → back to compact while busy")
    IslandMachine.reduce(&s, .busyChanged(false))
    check(s.phase == .idle, "not busy → idle")
}

do {
    var s = IslandState()
    let fx = IslandMachine.reduce(&s, .alert(alert("d1", .done)))
    check(s.phase == .alert, "done → alert")
    check(fx == [.scheduleAutoDismiss(id: "d1", after: 4)], "done schedules 4 s auto-close")
    IslandMachine.reduce(&s, .alertTimedOut("d1"))
    check(s.phase == .idle, "auto-close returns to idle")
    IslandMachine.reduce(&s, .alertTimedOut("d1"))
    check(s.alerts.isEmpty, "stale timer is harmless")
}

do {
    var s = IslandState()
    IslandMachine.reduce(&s, .alert(alert("f1", .failed)))
    IslandMachine.reduce(&s, .hoverBegan)
    IslandMachine.reduce(&s, .alertTimedOut("f1"))
    check(s.phase == .alert, "hovered alert stays open after timeout")
    IslandMachine.reduce(&s, .hoverEnded)
    check(s.alerts.isEmpty && s.phase == .idle, "expired alert closes when hover ends")
}

do {
    var s = IslandState()
    IslandMachine.reduce(&s, .alert(alert("p1", .needsYou, session: "A", request: "r1")))
    IslandMachine.reduce(&s, .alert(alert("n1", .needsYou, session: "A")))
    check(s.alerts.map(\.id) == ["p1"], "notification does not replace a pending permission")
    IslandMachine.reduce(&s, .alert(alert("d1", .done, session: "B")))
    check(s.visibleAlerts.map(\.id) == ["p1"], "needs-you is shown before results")
    let fx = IslandMachine.reduce(&s, .alertTimedOut("d1"))
    check(s.alerts.contains { $0.id == "d1" } && fx.count == 1, "hidden result gets rescheduled")
    IslandMachine.reduce(&s, .requestResolved("r1"))
    check(s.visibleAlerts.map(\.id) == ["d1"], "resolving the request reveals results")
}

do {
    var s = IslandState()
    IslandMachine.reduce(&s, .alert(alert("n1", .needsYou, session: "A")))
    IslandMachine.reduce(&s, .sessionResumed("A"))
    check(s.alerts.isEmpty, "session going busy clears its notification")
    IslandMachine.reduce(&s, .alert(alert("n2", .needsYou, session: "A")))
    IslandMachine.reduce(&s, .alert(alert("d", .done, session: "A")))
    check(s.alerts.map(\.id) == ["d"], "done clears the same session's needs-you")
    for i in 0..<5 { IslandMachine.reduce(&s, .alert(alert("x\(i)", .failed))) }
    check(s.alerts.count == 3 && s.alerts.last?.id == "x4", "at most three result rows, newest kept")
}

do {
    var s = IslandState()
    IslandMachine.reduce(&s, .setPinned(true))
    check(s.phase == .expanded, "pinned → expanded")
    IslandMachine.reduce(&s, .selectTab(.radar))
    check(s.tab == .radar, "tab selection")
}

// MARK: Parsers

do {
    let out = """
    p501
    cnode
    f23
    n*:3000
    f24
    n[::1]:3000
    p777
    ccom.docke
    f10
    n*:5432
    p900
    cpostgres
    f5
    n127.0.0.1:5433
    """
    let sockets = LsofParser.parseListen(out)
    check(sockets.count == 3, "lsof: IPv4 + IPv6 of one pid merge (got \(sockets.count))")
    check(sockets.first == ListeningSocket(pid: 501, command: "node", port: 3000), "lsof: first socket")
    let cwds = LsofParser.parseCwd("p501\nfcwd\nn/Users/me/www/ade-frontend\np900\nfcwd\nn/\n")
    check(cwds[501] == "/Users/me/www/ade-frontend", "lsof cwd")
    let args = PsParser.parse("  501 node /Users/me/www/ade-frontend/node_modules/.bin/vite --port 3000\n  900 postgres -D x\n")
    check(args[501]?.contains("vite") == true, "ps args")
    let docker = DockerPortsParser.parse("db\tpostgres:16\t0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp\ncache\tredis\t0.0.0.0:6379->6379/tcp\nnoports\tbusybox\t\n")
    check(docker == [DockerPublish(name: "db", image: "postgres:16", hostPort: 5432),
                     DockerPublish(name: "cache", image: "redis", hostPort: 6379)], "docker ports")
    let entries = PortAssembler.assemble(sockets: sockets, cwds: cwds, args: args, docker: docker, ownPid: 1)
    check(entries.map(\.port) == [3000, 5432, 5433, 6379], "assembled ports sorted: \(entries.map(\.port))")
    check(entries[0].project == "ade-frontend" && entries[0].detail == "node · vite", "node row: \(entries[0])")
    check(entries[1].container == "db" && entries[1].project == "db", "docker backend row becomes the container")
    check(entries[2].project == "postgres", "cwd / falls back to the command name")
    check(entries[3].pid == 0 && entries[3].container == "cache", "docker-only port is listed")
}

do {
    let json = #"{"ts": 1700000000, "rate_limits": {"five_hour": {"used_percentage": 68.4, "resets_at": 1700006000}, "seven_day": {"used_percentage": 41, "resets_at": "2023-11-20T10:00:00Z"}}}"#
    let snap = ClaudeStatuslineProvider.parse(Data(json.utf8))
    check(snap?.fiveHour?.usedPercent == 68.4, "statusline 5h percent")
    check(snap?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1700006000), "statusline epoch reset")
    check(snap?.weekly?.resetsAt != nil, "statusline ISO reset")
    let stale = UsageWindow(usedPercent: 90, resetsAt: Date(timeIntervalSince1970: 10)).current()
    check(stale.usedPercent == 0, "past reset means 0%")

    let codex = #"{"timestamp":"2026-11-25T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":22.0,"window_minutes":300,"resets_in_seconds":3600},"secondary":{"used_percent":9.5,"window_minutes":10080}}}}"#
    let c = CodexUsageProvider.parse(tail: "garbage\n" + codex + "\n", fileDate: Date())
    check(c?.fiveHour?.usedPercent == 22 && c?.weekly?.usedPercent == 9.5, "codex rate_limits")
    check(c?.fiveHour?.resetsAt == Fmt.isoDate("2026-11-25T11:00:00Z"), "codex resets_in_seconds")
}

do {
    let ev = AgentEvent.decode(Data(#"{"v":1,"id":"1-a","ts":12.5,"source":"shell","kind":"command_end","command":"npm run build","cwd":"/x/app","exit_code":1,"duration_ms":134000,"shell_pid":42}"#.utf8))
    check(ev?.kind == .commandEnd && ev?.exitCode == 1 && ev?.shellPid == 42 && ev?.project == "app", "zsh event decodes")
    check(AgentEvent.decode(Data(#"{"id":"x","ts":1,"source":"claude","kind":"brand_new"}"#.utf8))?.kind == .unknown, "unknown kind tolerated")
    let roundTrip = AgentEvent(source: "claude", kind: .permission, requestId: "r")
    check(AgentEvent.decode(try! AgentEvent.encoder.encode(roundTrip)) == roundTrip, "event round trip")
}

do {
    let session = ClaudeSession.parse(Data(#"{"pid":123,"sessionId":"s1","cwd":"/Users/me/www/verify","status":"busy","updatedAt":1795609976624,"statusUpdatedAt":1795609976000}"#.utf8))
    check(session?.isBusy == true && session?.project == "verify", "session parse")
    check(session.map { abs($0.statusSince.timeIntervalSince1970 - 1795609976) < 1 } == true, "ms timestamps")
}

do {
    let now = Fmt.isoDate("2026-11-25T12:10:00Z")!
    let tail = [
        #"{"type":"user","timestamp":"2026-11-25T11:00:00Z","message":{"content":"old prompt"}}"#,
        #"{"type":"user","timestamp":"2026-11-25T12:06:00Z","message":{"content":[{"type":"text","text":"fix it"}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/a.swift"}}]}}"#,
        #"{"type":"user","timestamp":"2026-11-25T12:07:00Z","toolUseResult":{},"message":{"content":[{"type":"tool_result"}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/b.swift"}},{"type":"tool_use","name":"Edit","input":{"file_path":"/a.swift"}},{"type":"tool_use","name":"Read","input":{"file_path":"/c"}}]}}"#,
    ].joined(separator: "\n")
    let t = TurnSummary.parse(tail: tail, now: now)
    check(t.filesChanged == 2, "turn edited 2 files (got \(t.filesChanged))")
    check(t.duration == 240, "turn took 4 min (got \(String(describing: t.duration)))")
}

do {
    let home = "/Users/me"
    check(PortAssembler.isProjectDirectory("/Users/me/www/app", home: home), "project dir under home")
    check(PortAssembler.isProjectDirectory("/Volumes/Dev/app", home: home), "project dir on a volume")
    check(!PortAssembler.isProjectDirectory("/", home: home), "/ is not a project")
    check(!PortAssembler.isProjectDirectory("/Users/me", home: home), "home itself is not a project")
    check(!PortAssembler.isProjectDirectory("/Users/me/Library/Containers/x", home: home), "~/Library is not a project")
    check(!PortAssembler.isProjectDirectory("/Users/me/.docker", home: home), "hidden folders are not projects")
    check(PortAssembler.isAgentProcess("2.1.330") && PortAssembler.isAgentProcess("claude"), "agent binaries")
    check(!PortAssembler.isAgentProcess("node"), "node is not an agent")

    let sockets = [
        ListeningSocket(pid: 10, command: "node", port: 3000),
        ListeningSocket(pid: 11, command: "webstorm", port: 63342),
        ListeningSocket(pid: 12, command: "2.1.330", port: 51974),
        ListeningSocket(pid: 13, command: "ControlCe", port: 7000),
        ListeningSocket(pid: 14, command: "python3", port: 8000),
        ListeningSocket(pid: 15, command: "com.docke", port: 5432),
    ]
    let cwds: [Int32: String] = [10: "/Users/me/www/web", 11: "/", 12: "/Users/me/www/web", 13: "/", 14: "/Users/me/www/api", 15: "/"]
    let docker = [DockerPublish(name: "db", image: "postgres", hostPort: 5432)]
    let all = PortAssembler.assemble(sockets: sockets, cwds: cwds, args: [:], docker: docker, ownPid: 1, home: "/Users/me")
    check(all.count == 6, "unfiltered keeps every port (got \(all.count))")
    let projects = PortAssembler.assemble(sockets: sockets, cwds: cwds, args: [:], docker: docker, ownPid: 1,
                                          projectsOnly: true, excludePids: [14], home: "/Users/me")
    check(projects.map(\.port) == [3000, 5432], "project-only: dev server + docker, no apps/agents (got \(projects.map(\.port)))")
}

// MARK: Forecast

do {
    let now = Date(timeIntervalSince1970: 100_000)
    let reset = now.addingTimeInterval(3 * 3600)
    let samples = (0..<6).map { i in
        UsageSample(t: now.timeIntervalSince1970 - Double(30 - i * 6) * 60, pct: 40 + Double(i) * 3, reset: reset.timeIntervalSince1970)
    }
    let rate = Forecast.ratePerMinute(samples: samples, currentReset: reset, now: now)
    check(rate.map { abs($0 - 0.5) < 0.0001 } == true, "regression: 3% per 6 min = 0.5%/min (got \(String(describing: rate)))")
    let win = UsageWindow(usedPercent: 55, resetsAt: reset)
    check(Forecast.project(window: win, ratePerMinute: 0.5, now: now) == .hitsLimit(at: now.addingTimeInterval(90 * 60)), "hits limit in 90 min")
    check(Forecast.project(window: win, ratePerMinute: 0.1, now: now) == .staysUnder, "slow pace stays under until reset")
    check(Forecast.project(window: win, ratePerMinute: nil, now: now) == .unknown, "no rate, no forecast")
    check(Forecast.ratePerMinute(samples: Array(samples.prefix(1)), currentReset: reset, now: now) == nil, "one sample is not enough")
    let tokenRate = Forecast.tokenRatePerMinute(currentPercent: 50, tokensInWindow: 1_000_000, tokensRecent: 300_000, recentMinutes: 30)
    check(tokenRate.map { abs($0 - 0.5) < 0.0001 } == true, "token-based rate")
    var history: [UsageSample] = []
    Forecast.append(UsageSample(t: 0, pct: 1, reset: 5), to: &history)
    Forecast.append(UsageSample(t: 10, pct: 1, reset: 5), to: &history)
    Forecast.append(UsageSample(t: 20, pct: 2, reset: 5), to: &history)
    check(history.count == 2, "history skips unchanged samples")
}

// MARK: Limit watch

do {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let reset = now.addingTimeInterval(3600)
    var w = LimitWatch()
    check(w.update(window: "5h", usage: UsageWindow(usedPercent: 70, resetsAt: reset), now: now).isEmpty, "below 80%: quiet")
    check(w.update(window: "5h", usage: UsageWindow(usedPercent: 83, resetsAt: reset), now: now)
          == [.crossed(window: "5h", threshold: 80, percent: 83, resetsAt: reset)], "80% crossed once")
    check(w.update(window: "5h", usage: UsageWindow(usedPercent: 86, resetsAt: reset), now: now).isEmpty, "no repeat for 80%")
    let jump = w.update(window: "5h", usage: UsageWindow(usedPercent: 97, resetsAt: reset), now: now)
    check(jump == [.crossed(window: "5h", threshold: 95, percent: 97, resetsAt: reset)], "a jump announces only the highest threshold")
    check(w.pendingResets.map(\.window) == ["5h"], "reset timer wanted")
    let after = reset.addingTimeInterval(5)
    check(w.update(window: "5h", usage: UsageWindow(usedPercent: 0, resetsAt: nil), now: after) == [.reset(window: "5h")], "reset announced")
    check(w.update(window: "5h", usage: nil, now: after).isEmpty && w.pendingResets.isEmpty, "reset announced once")

    var q = LimitWatch()
    _ = q.update(window: "wk", usage: UsageWindow(usedPercent: 50, resetsAt: reset), now: now)
    let later = now.addingTimeInterval(4000)
    check(q.update(window: "wk", usage: UsageWindow(usedPercent: 5, resetsAt: later.addingTimeInterval(86400)), now: later).isEmpty,
          "unwarned window resets silently")
    let data = try! JSONEncoder().encode(w)
    check((try? JSONDecoder().decode(LimitWatch.self, from: data)) == w, "LimitWatch round-trips")

    var s = IslandState()
    let fx = IslandMachine.reduce(&s, .alert(IslandAlert(id: "w", kind: .warning, title: "w", subtitle: "")))
    check(s.phase == .alert && fx.count == 1, "warning alerts auto-close like results")
}

// MARK: New features

do {
    let parents = PsParser.parents("  1     0\n 500     1\n 600   500\n 700   600\n 800     1\n")
    check(parents[700] == 600 && parents[800] == 1, "ps -axo pid,ppid parse")
    check(PortAssembler.owner(of: 700, parents: parents, agentSessions: [500: "S"]) == "S", "server under Claude is owned")
    check(PortAssembler.owner(of: 800, parents: parents, agentSessions: [500: "S"]) == nil, "unrelated server has no owner")
    let sockets = [ListeningSocket(pid: 700, command: "node", port: 3000), ListeningSocket(pid: 800, command: "node", port: 4000)]
    let cwds: [Int32: String] = [700: "/Users/me/a", 800: "/Users/me/b"]
    let e = PortAssembler.assemble(sockets: sockets, cwds: cwds, args: [:], docker: [], ownPid: 1, home: "/Users/me",
                                   parents: parents, agentSessions: [500: "S"])
    check(e[0].ownerSession == "S" && !e[0].orphan, "port 3000 owned by session S")
    check(e[1].ownerSession == nil && e[1].orphan, "port 4000 is an orphan (parent is launchd)")

    let now = Date(timeIntervalSince1970: 100_000)
    let el = Pace.elapsed(resetsAt: now.addingTimeInterval(3 * 3600), window: 5 * 3600, now: now)
    check(el.map { abs($0 - 0.4) < 0.0001 } == true, "2 h into a 5 h window = 40%")
    check(Pace.elapsed(resetsAt: now.addingTimeInterval(-1), window: 5 * 3600, now: now) == nil, "past reset: no pace")
    check(Pace.lead(usedPercent: 55, elapsed: 0.4) == 15, "15 points ahead of pace")

    let items = [IslandAlert(id: "a", kind: .done, title: "Claude finished", subtitle: ""),
                 IslandAlert(id: "b", kind: .failed, title: "npm run build failed", subtitle: ""),
                 IslandAlert(id: "c", kind: .warning, title: "w", subtitle: ""),
                 IslandAlert(id: "d", kind: .done, title: "x", subtitle: "")]
    let digest = AwayDigest.make(items, awayFor: 720, now: now)
    check(digest?.kind == .failed && digest?.title == "While you were away · 12 min", "digest kind and title")
    check(digest?.subtitle == "Claude finished · npm run build failed · w · +1 more", "digest subtitle: \(digest?.subtitle ?? "")")
    var st = IslandState()
    let fx = IslandMachine.reduce(&st, .alert(digest!))
    check(fx == [.scheduleAutoDismiss(id: digest!.id, after: 8)], "digest lingers 8 s")
    check(AwayDigest.make([], awayFor: 1) == nil, "no digest when nothing happened")
}

// MARK: Docker compose + git identity

do {
    let out = "eap-proxy-1\teap-proxy\t127.0.0.1:8080->8080/tcp, 127.0.0.1:8443->8443/tcp\teap\tproxy\t/Users/me/www/employee-access-panel\n"
            + "solo\tredis:7\t0.0.0.0:6379->6379/tcp\t\t\t\n"
    let d = DockerPortsParser.parse(out)
    check(d.count == 3 && d[0].service == "proxy" && d[1].hostPort == 8443 && d[2].composeProject == nil, "compose labels parsed")
    let sockets = [ListeningSocket(pid: 9, command: "com.docke", port: 8080), ListeningSocket(pid: 9, command: "com.docke", port: 8443)]
    let e = PortAssembler.assemble(sockets: sockets, cwds: [:], args: [:], docker: d, ownPid: 1)
    let byPort = Dictionary(uniqueKeysWithValues: e.map { ($0.port, $0) })
    check(byPort[8080]?.project == "proxy" && byPort[8443]?.project == "proxy" && byPort[6379]?.project == "solo",
          "compose rows named by service: \(e.map(\.project))")
    check(byPort[8080]?.composeGroup == "employee-access-panel" && byPort[6379]?.composeGroup == nil, "grouped by project folder")

    let yaml = "gitlab.com:\n    user: other\ngithub.com:\n    git_protocol: https\n    user: octo-dev\n"
    check(GitIdentity.githubUser(fromHostsYAML: yaml) == "octo-dev", "gh hosts.yml user")
    check(GitIdentity.githubUser(fromHostsYAML: "gitlab.com:\n    user: x\n") == nil, "no github.com entry")
}

// MARK: Live activity

do {
    let tail = [
        #"{"type":"user","timestamp":"2026-11-26T10:00:00Z","message":{"content":"old"}}"#,
        #"{"type":"user","timestamp":"2026-11-26T10:05:00Z","message":{"content":[{"type":"text","text":"add a Now card"}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x/Ports.swift"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"..."}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Agent","input":{"description":"Compare apps","subagent_type":"web-fetch","prompt":"p"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"Running. agentId: a50181b2 (use SendMessage)"}]}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Edit","input":{"file_path":"/x/Cards.swift"}},{"type":"tool_use","id":"t4","name":"Bash","input":{"command":"swift build","description":"build the app"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"ok"}]}}"#,
    ].joined(separator: "\n")
    let a = LiveActivity.parse(tail: tail)
    check(a.turnStart == Fmt.isoDate("2026-11-26T10:05:00Z"), "turn starts at the last prompt")
    check(a.steps.map(\.id) == ["t1", "t2", "t3", "t4"], "steps in order: \(a.steps.map(\.id))")
    check(a.current?.title == "Build the app" && a.current?.pending == true && a.current?.kind == .run, "current step from Bash description")
    check(a.steps[0].title == "Reading Ports.swift" && !a.steps[0].pending, "read step")
    check(a.filesChanged == 1 && a.toolCalls == 4, "files and tool calls")
    check(a.agents.count == 1 && a.agents[0].agentId == "a50181b2" && a.agents[0].type == "web-fetch" && a.agents[0].launched, "agent with id")
    let mcp = LiveActivity.step(name: "mcp__claude-in-chrome__computer", input: [:], id: "m", pending: false)
    check(mcp.title == "computer · claude-in-chrome" && mcp.kind == .web, "mcp tool title: \(mcp.title)")
    let sub = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"s1","name":"WebFetch","input":{"url":"https://github.com/x"}}]}}"#
    check(LiveActivity.lastStep(tail: sub)?.title == "Reading github.com", "subagent's latest step")
}

// MARK: Port URLs

do {
    func url(_ port: Int) -> String? {
        PortEntry(port: port, pid: 1, command: "x", project: "p", detail: "", container: nil).url?.absoluteString
    }
    check(url(3000) == "http://localhost:3000", "plain dev server is http")
    check(url(8443) == "https://localhost:8443" && url(443) == "https://localhost:443", "x443 ports open as https")
    check(url(5432) == nil && url(6379) == nil && url(8025) == "http://localhost:8025", "databases have no browser link; mailpit does")
}

// MARK: Formatting

check(Fmt.clock(134) == "2:14" && Fmt.clock(38) == "38s", "clock format")
check(Fmt.minutes(180) == "3 min" && Fmt.minutes(6120) == "1h 42m", "minutes format")
check(Fmt.resetsIn(Date(timeIntervalSince1970: 6120), now: Date(timeIntervalSince1970: 0)) == "Resets in 1h 42m", "resets format")

print(failures == 0 ? "selftest: all \(checks) checks passed" : "selftest: \(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
