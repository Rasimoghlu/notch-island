import AppKit
import SwiftUI
import NotchIslandCore

struct IslandGeometry: Equatable {
    /// Hardware notch size, or the pill size on Macs without a notch.
    var notch: CGSize
    var hasNotch: Bool
}

struct CommandRecord: Identifiable, Equatable {
    let id: String
    var command: String
    var cwd: String?
    var exitCode: Int
    var duration: TimeInterval
    var finishedAt: Date
}

/// A Claude session's live state for the "Now" card.
struct LiveSession: Identifiable, Equatable {
    struct Agent: Identifiable, Equatable {
        var id: String
        var description: String
        var type: String?
        var running: Bool
        /// What the subagent itself is doing right now.
        var step: LiveStep?
    }

    var id: String            // session id
    var project: String
    var pid: Int32
    var busy: Bool
    var activity: LiveActivity
    var agents: [Agent]
}

struct AgentInfo: Identifiable, Equatable {
    enum State: Int { case needsYou, thinking, done, idle }
    var id: String
    var name: String
    var tool: String
    var state: State
    var since: Date
    var pid: Int32
}

/// The single store. Owns the island state machine and every data source.
/// All mutation happens on the main actor; slow work (lsof, git, log scans) runs on `work`.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var island = IslandState()
    @Published var geometry = IslandGeometry(notch: CGSize(width: 185, height: 32), hasNotch: true)

    @Published private(set) var claudeUsage: UsageSnapshot?
    @Published private(set) var codexUsage: UsageSnapshot?
    @Published private(set) var forecast: Forecast.Result = .unknown
    /// Tokens used in the current 5-hour window, from the session logs (fallback display).
    @Published private(set) var windowTokens: Double?
    @Published private(set) var ports: [PortEntry] = []
    @Published private(set) var portsLoaded = false
    @Published private(set) var runningCommands: [RunningCommand] = []
    @Published private(set) var finishedCommands: [CommandRecord] = []
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var lastDone: [String: Date] = [:]
    @Published private(set) var git: GitStatus?
    @Published private(set) var gitIdentity: GitIdentity?
    /// Extra Overview height for the ports strip.
    var overviewExtra: CGFloat { IslandLayout.portsExtra(ports) }

    /// Busy sessions (or the most recent one), with what they are doing right now.
    @Published private(set) var live: [LiveSession] = []
    /// session id → transcript file, found once.
    private var transcriptCache: [String: URL] = [:]
    /// Context-window use per Claude session id (from the status line).
    @Published private(set) var contextBySession: [String: Double] = [:]
    @Published private(set) var loopsEnabled = true
    /// The pointer is resting on the collapsed notch; it swells slightly before opening.
    @Published var hoverIntent = false
    /// A shell command that has been running for a few seconds: shown as the split-off bubble.
    @Published private(set) var bubbleCommand: RunningCommand?
    /// 5-hour burn rate in percent per minute (from the forecast).
    @Published private(set) var burnRate: Double?

    let settings = AppSettings()
    private(set) var isDemo = false
    /// Demo only: sessions drawn as "needs you" on the radar without opening an alert.
    private var demoWaiting: Set<String> = []

    private let claudeProvider = ClaudeStatuslineProvider()
    private let codexProvider = CodexUsageProvider()
    private let logScanner = ClaudeLogScanner()
    /// 5-hour percent samples (last 6 h), persisted. Drives the forecast and the sparkline.
    @Published private(set) var history: [UsageSample] = []
    private var tokenStats: (window: Double, recent: Double)?

    /// Server pid → name of the Claude session that started it; survives the session.
    private var portOwners: [Int32: String] = [:]
    /// Alerts held back while the user was away from the Mac.
    private var awayItems: [IslandAlert] = []
    private var awaySince: Date?
    private var returnTimer: DispatchSourceTimer?
    static let awayAfter: TimeInterval = 120

    private var limitWatch = LimitWatch()
    private var resetTimers: [DispatchWorkItem] = []

    private let work = DispatchQueue(label: "notch-island.work", qos: .utility)
    private var watchers: [FileWatcher] = []
    private var timer: DispatchSourceTimer?
    private var tickInterval: TimeInterval = 0
    private var tickCount = 0
    private var portsInFlight = false
    private var observers: [NSObjectProtocol] = []

    // MARK: - Lifecycle

    func start() {
        NIPaths.ensureDirectories()
        updateMotion()
        observeSystem()
        loadHistory()
        loadLimitWatch()
        HotKeys.shared.onAction = { [weak self] action in self?.hotKey(action) }
        reloadClaudeUsage()
        reloadCodexUsage()
        refreshSessions()
        reloadRunning()
        drainEvents(startup: true)
        clearStaleResponses()
        watch()
        refreshPorts()
        work.async { [logScanner] in logScanner.scan() }
        updateSchedule()
    }

    private func watch() {
        let w: [FileWatcher?] = [
            FileWatcher(paths: [NIPaths.events]) { [weak self] in MainActor.assumeIsolated { self?.drainEvents() } },
            FileWatcher(paths: [NIPaths.shell]) { [weak self] in MainActor.assumeIsolated { self?.reloadRunning() } },
            FileWatcher(paths: claudeProvider.watchedDirectories) { [weak self] in MainActor.assumeIsolated { self?.reloadClaudeUsage() } },
            FileWatcher(paths: [NIPaths.claudeSessions], latency: 0.4) { [weak self] in MainActor.assumeIsolated { self?.refreshSessions() } },
        ]
        watchers = w.compactMap { $0 }
    }

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMotion() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMotion() }
        })
    }

    private func updateMotion() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        loopsEnabled = !reduce && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    static let debug = ProcessInfo.processInfo.environment["NOTCH_ISLAND_DEBUG"] == "1"

    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: - State machine

    func send(_ input: IslandInput) {
        var next = island
        let effects = IslandMachine.reduce(&next, input)
        if next != island {
            let from = island.phase
            let to = next.phase
            withAnimation(animation(from: from, to: to)) { island = next }
            if Self.debug {
                FileHandle.standardError.write(Data("[island] \(input) → \(to) alerts=\(next.alerts.map(\.title))\n".utf8))
            }
            if from != to { phaseChanged(from: from, to: to) }
        }
        HotKeys.shared.setActive(settings.shortcutsEnabled && island.needsYou?.requestId != nil)
        for effect in effects {
            switch effect {
            case .scheduleAutoDismiss(let id, let after):
                guard !isDemo else { continue }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                    self?.send(.alertTimedOut(id))
                }
            }
        }
    }

    private func animation(from: IslandPhase, to: IslandPhase) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.18) }
        switch (from, to) {
        case (_, .alert) where from != .alert:
            return Motion.openHeightAlert
        case (_, .expanded):
            return Motion.openHeight
        default:
            return .spring(response: 0.26, dampingFraction: 0.9)
        }
    }

    private func phaseChanged(from: IslandPhase, to: IslandPhase) {
        if to == .expanded {
            refreshLive()
            refreshPorts()
            refreshGit()
            reloadCodexUsage()
            scanLogs()
        }
        updateSchedule()
    }

    // MARK: - Scheduling (3 s while expanded, 60 s otherwise)

    private func updateSchedule() {
        guard !isDemo else { return }
        let want: TimeInterval = island.phase == .expanded ? 3 : 60
        guard want != tickInterval else { return }
        tickInterval = want
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + want, repeating: want, leeway: .seconds(want >= 60 ? 10 : 1))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        t.resume()
        timer = t
    }

    private func tick() {
        tickCount += 1
        refreshPorts()
        refreshSessions()
        reloadRunning()
        let expanded = island.phase == .expanded
        if expanded { refreshLive() }
        if !expanded || tickCount % 3 == 0 { refreshGit(onlyIfExpanded: true) }
        // Codex and the log scan feed only the expanded card (opening it refreshes them at once).
        if expanded && tickCount % 10 == 0 {
            reloadCodexUsage()
            scanLogs()
        }
    }

    // MARK: - Usage

    private func reloadClaudeUsage() {
        guard !isDemo else { return }
        let ctx = ContextUsage.loadAll()
        if ctx != contextBySession { contextBySession = ctx }
        let snap = claudeProvider.load()
        claudeUsage = snap
        if let snap, let w = snap.fiveHour?.current(now: Date()) {
            let sample = UsageSample(t: snap.updatedAt.timeIntervalSince1970, pct: w.usedPercent,
                                     reset: w.resetsAt?.timeIntervalSince1970)
            let before = history.count
            Forecast.append(sample, to: &history)
            if history.count != before { saveHistory() }
        }
        recomputeForecast()
        evaluateLimits()
    }

    // MARK: - Limit alerts (80 / 90 / 95 %, and the reset)

    private func evaluateLimits() {
        guard !isDemo else { return }
        let now = Date()
        var signals = limitWatch.update(window: "claude.5h", usage: claudeUsage?.fiveHour?.current(now: now), now: now)
        signals += limitWatch.update(window: "claude.weekly", usage: claudeUsage?.weekly?.current(now: now), now: now)
        saveLimitWatch()
        scheduleResetTimers()
        for signal in signals { postLimitAlert(signal) }
    }

    private func postLimitAlert(_ signal: LimitWatch.Signal) {
        func label(_ window: String) -> String { window == "claude.5h" ? "5-hour" : "weekly" }
        switch signal {
        case let .crossed(window, threshold, percent, resetsAt):
            var subtitle = resetsAt.map { Fmt.resetsIn($0) } ?? ""
            if window == "claude.5h", case .hitsLimit(let at) = forecast {
                subtitle += " · at this pace full at \(Fmt.timeOfDay(at))"
            }
            present(IslandAlert(id: "limit-\(window)-\(threshold)-\(Int(resetsAt?.timeIntervalSince1970 ?? 0))",
                                    kind: threshold >= 95 ? .failed : .warning,
                                    title: "Claude \(label(window)) limit at \(Int(percent.rounded()))%",
                                    subtitle: subtitle))
        case let .reset(window):
            present(IslandAlert(id: "limit-reset-\(window)-\(Int(Date().timeIntervalSince1970))", kind: .done,
                                title: "Claude \(label(window)) limit reset",
                                subtitle: "Full limit available again"))
        }
    }

    /// One-shot timers at each warned window's reset time; no polling.
    private func scheduleResetTimers() {
        resetTimers.forEach { $0.cancel() }
        resetTimers = limitWatch.pendingResets.map { pending in
            let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluateLimits() } }
            let delay = max(1, pending.at.timeIntervalSinceNow + 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }

    private func loadLimitWatch() {
        if let data = UserDefaults.standard.data(forKey: "limitWatch"),
           let w = try? JSONDecoder().decode(LimitWatch.self, from: data) { limitWatch = w }
    }

    private func saveLimitWatch() {
        if let data = try? JSONEncoder().encode(limitWatch) { UserDefaults.standard.set(data, forKey: "limitWatch") }
    }

    // MARK: - Presenting results (mute, away digest)

    /// Done / failed / warning alerts go through here. While muted they are dropped; while
    /// you are away from the Mac they are held and shown as one summary when you return.
    private func present(_ alert: IslandAlert) {
        if settings.isMuted { return }
        if UserActivity.idleSeconds >= Self.awayAfter {
            if awaySince == nil { awaySince = Date().addingTimeInterval(-UserActivity.idleSeconds) }
            awayItems.append(alert)
            watchForReturn()
            return
        }
        send(.alert(alert))
    }

    /// Polls idle time every 2 s, only while something is waiting to be shown.
    private func watchForReturn() {
        guard returnTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, UserActivity.idleSeconds < 3 else { return }
                self.returnTimer?.cancel()
                self.returnTimer = nil
                let away = Date().timeIntervalSince(self.awaySince ?? Date())
                if let digest = AwayDigest.make(self.awayItems, awayFor: away) { self.send(.alert(digest)) }
                self.awayItems = []
                self.awaySince = nil
            }
        }
        t.resume()
        returnTimer = t
    }

    // MARK: - Quiet rules

    /// Done/failed alerts are skipped while muted, or when the terminal that ran the job is
    /// already in front (you are looking at the result). "Needs you" is never skipped.
    private func shouldQuiet(pid: Int32?) -> Bool {
        guard settings.quietWhenTerminalFront, let pid else { return false }
        return ProcessControl.isTerminalFrontmost(for: pid)
    }

    func mute(for duration: TimeInterval?) {
        settings.mutedUntil = duration.map { Date().addingTimeInterval($0) }
    }

    private func hotKey(_ action: HotKeys.Action) {
        guard let alert = island.needsYou, alert.requestId != nil else { return }
        switch action {
        case .allow: answer(alert, allow: true)
        case .deny: answer(alert, allow: false)
        case .openTerminal: openTerminal(for: alert)
        }
    }

    private func reloadCodexUsage() {
        guard !isDemo else { return }
        let provider = codexProvider
        work.async { [weak self] in
            let snap = provider.load()
            DispatchQueue.main.async { self?.codexUsage = snap }
        }
    }

    private func scanLogs() {
        guard !isDemo else { return }
        let scanner = logScanner
        let reset = claudeUsage?.fiveHour?.current().resetsAt
        work.async { [weak self] in
            scanner.scan()
            let now = Date()
            let windowStart = reset.map { $0.addingTimeInterval(-5 * 3600) } ?? now.addingTimeInterval(-5 * 3600)
            let stats = (window: scanner.tokens(since: windowStart), recent: scanner.tokens(since: now.addingTimeInterval(-30 * 60)))
            DispatchQueue.main.async {
                guard let self else { return }
                self.tokenStats = stats
                self.windowTokens = stats.window
                self.recomputeForecast()
            }
        }
    }

    private func recomputeForecast() {
        guard !isDemo else { return }
        let now = Date()
        guard let w = claudeUsage?.fiveHour?.current(now: now) else { forecast = .unknown; return }
        var rate = Forecast.ratePerMinute(samples: history, currentReset: w.resetsAt, now: now)
        if rate == nil, let t = tokenStats {
            rate = Forecast.tokenRatePerMinute(currentPercent: w.usedPercent, tokensInWindow: t.window,
                                               tokensRecent: t.recent, recentMinutes: 30)
        }
        forecast = Forecast.project(window: w, ratePerMinute: rate, now: now)
        burnRate = rate
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: NIPaths.claudeHistoryFile),
              let h = try? JSONDecoder().decode([UsageSample].self, from: data) else { return }
        history = h
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            try? AtomicFile.write(data, to: NIPaths.claudeHistoryFile)
        }
    }

    // MARK: - Ports

    func refreshPorts() {
        guard !isDemo, !portsInFlight else { return }
        portsInFlight = true
        let projectsOnly = settings.projectPortsOnly
        let agentPids = Set(sessions.map(\.pid))
        let agentSessions = Dictionary(sessions.map { ($0.pid, $0.sessionId) }, uniquingKeysWith: { a, _ in a })
        let names = Dictionary(sessions.map { ($0.sessionId, $0.project) }, uniquingKeysWith: { a, _ in a })
        work.async { [weak self] in
            let scanned = PortScanner.scan(projectsOnly: projectsOnly, excludePids: agentPids, agentSessions: agentSessions)
            DispatchQueue.main.async {
                guard let self else { return }
                self.portsInFlight = false
                self.portsLoaded = true
                let entries = scanned.map { entry -> PortEntry in
                    var e = entry
                    if let sid = e.ownerSession, let name = names[sid] { self.portOwners[e.pid] = name }
                    e.ownerName = self.portOwners[e.pid]
                    return e
                }
                let alive = Set(entries.map(\.pid))
                self.portOwners = self.portOwners.filter { alive.contains($0.key) }
                // First scan done: port folders are now known, so the git card can find a repo.
                if self.gitIdentity == nil { self.refreshGit() }
                if entries != self.ports {
                    self.ports = entries
                    if Self.debug {
                        let lines = entries.map { "\($0.port) \($0.project) owner=\($0.ownerName ?? "-") orphan=\($0.orphan)" }
                        FileHandle.standardError.write(Data("[ports] \(lines)\n".utf8))
                    }
                }
            }
        }
    }

    func kill(_ entry: PortEntry) {
        guard !isDemo else { ports.removeAll { $0.id == entry.id }; return }
        if let container = entry.container {
            work.async { [weak self] in
                _ = Docker.stop(container)
                DispatchQueue.main.async { self?.refreshPorts() }
            }
        } else {
            _ = ProcessControl.terminate(pid: entry.pid)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.refreshPorts() }
            }
        }
    }

    // MARK: - Live activity ("Now" card)

    /// A subagent counts as running while its own transcript was written in the last 30 s.
    nonisolated static let agentQuietAfter: TimeInterval = 30

    func refreshLive() {
        guard !isDemo else { return }
        let busy = sessions.filter(\.isBusy)
        let chosen = Array((busy.isEmpty ? Array(sessions.prefix(1)) : busy).prefix(3))
        let cache = transcriptCache
        work.async { [weak self] in
            var found: [String: URL] = [:]
            let result = chosen.compactMap { s -> LiveSession? in
                guard let url = cache[s.sessionId] ?? Self.findTranscript(s.sessionId) else { return nil }
                found[s.sessionId] = url
                guard let tail = CodexUsageProvider.tail(of: url, bytes: 768 * 1024) else { return nil }
                let activity = LiveActivity.parse(tail: tail)
                let agentDir = url.deletingPathExtension().appendingPathComponent("subagents")
                let agents = activity.agents.map { a -> LiveSession.Agent in
                    var running = !a.launched
                    var step: LiveStep?
                    if let id = a.agentId {
                        let file = agentDir.appendingPathComponent("agent-\(id).jsonl")
                        let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        running = running || Date().timeIntervalSince(mtime) < Self.agentQuietAfter
                        if running, let t = CodexUsageProvider.tail(of: file, bytes: 96 * 1024) { step = LiveActivity.lastStep(tail: t) }
                    }
                    return LiveSession.Agent(id: a.id, description: a.description, type: a.type, running: running, step: step)
                }
                return LiveSession(id: s.sessionId, project: s.project, pid: s.pid, busy: s.isBusy, activity: activity, agents: agents)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.transcriptCache.merge(found) { _, new in new }
                if result != self.live {
                    self.live = result
                    if Self.debug {
                        for l in result {
                            let agents = l.agents.map { "\($0.description)[\($0.running ? "running" : "done")]" }
                            FileHandle.standardError.write(Data("[live] \(l.project) busy=\(l.busy) now=\(l.activity.current?.title ?? "-") steps=\(l.activity.toolCalls) files=\(l.activity.filesChanged) agents=\(agents)\n".utf8))
                        }
                    }
                }
            }
        }
    }

    /// ~/.claude/projects/<any>/<session-id>.jsonl (the folder is named after the start directory).
    nonisolated static func findTranscript(_ sessionId: String) -> URL? {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: NIPaths.claudeProjects, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let f = dir.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: f.path) { return f }
        }
        return nil
    }

    // MARK: - Git

    var focusCwd: String? {
        (sessions.first(where: \.isBusy) ?? sessions.first)?.cwd ?? runningCommands.last?.cwd ?? finishedCommands.first?.cwd
    }

    /// Folders worth checking for a repo, most relevant first: busy session, other sessions,
    /// shell commands, then the folders behind open ports (dev servers, compose projects).
    private var gitCandidates: [String] {
        var dirs: [String] = []
        dirs += sessions.filter(\.isBusy).map(\.cwd)
        dirs += sessions.map(\.cwd)
        dirs += runningCommands.reversed().compactMap(\.cwd)
        dirs += finishedCommands.compactMap(\.cwd)
        dirs += ports.compactMap(\.cwd)
        return dirs.filter { !$0.isEmpty && $0 != "/" }
    }

    private func refreshGit(onlyIfExpanded: Bool = false) {
        guard !isDemo else { return }
        if onlyIfExpanded && island.phase != .expanded { return }
        let candidates = gitCandidates
        work.async { [weak self] in
            let status = Git.firstRepo(candidates)
            let identity = Git.identity()
            DispatchQueue.main.async {
                guard let self else { return }
                if self.git != status { self.git = status }
                if self.gitIdentity != identity { self.gitIdentity = identity }
                if Self.debug {
                    FileHandle.standardError.write(Data("[git] repo=\(status?.repo ?? "-") branch=\(status?.branch ?? "-") gh=\(identity.githubUser ?? "-") email=\(status?.userEmail ?? identity.email ?? "-")\n".utf8))
                }
            }
        }
    }

    // MARK: - Sessions

    private func refreshSessions() {
        guard !isDemo else { return }
        let fresh = ClaudeSession.loadAll()
        let wasBusy = Set(sessions.filter(\.isBusy).map(\.sessionId))
        for s in fresh where s.isBusy && !wasBusy.contains(s.sessionId) {
            send(.sessionResumed(s.sessionId))
        }
        if fresh != sessions { sessions = fresh }
        send(.busyChanged(settings.showWorking && fresh.contains(where: \.isBusy)))
    }

    func settingsChanged() {
        send(.busyChanged(settings.showWorking && sessions.contains(where: \.isBusy)))
        refreshPorts()
    }

    var agents: [AgentInfo] {
        let now = Date()
        return sessions.map { s -> AgentInfo in
            var state = AgentInfo.State.idle
            var since = s.statusSince
            if let a = island.alerts.first(where: { $0.kind == .needsYou && $0.sessionId == s.sessionId }) {
                state = .needsYou
                since = a.createdAt
            } else if demoWaiting.contains(s.sessionId) {
                state = .needsYou
            } else if s.isBusy {
                state = .thinking
            } else if let done = lastDone[s.sessionId], now.timeIntervalSince(done) < 600 {
                state = .done
                since = done
            }
            return AgentInfo(id: s.sessionId, name: s.project, tool: "Claude Code", state: state, since: since, pid: s.pid)
        }
        .sorted { ($0.state.rawValue, -$0.since.timeIntervalSince1970) < ($1.state.rawValue, -$1.since.timeIntervalSince1970) }
    }

    // MARK: - Shell commands

    private func reloadRunning() {
        guard !isDemo else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: NIPaths.shell, includingPropertiesForKeys: nil)) ?? []
        var running: [RunningCommand] = []
        for f in files where f.pathExtension == "json" && !f.lastPathComponent.hasPrefix(".") {
            guard let data = try? Data(contentsOf: f),
                  let cmd = try? JSONDecoder().decode(RunningCommand.self, from: data) else { continue }
            if AppLiveness.isAlive(Int32(cmd.pid)) {
                running.append(cmd)
            } else {
                try? FileManager.default.removeItem(at: f)
            }
        }
        running.sort { $0.started < $1.started }
        if running != runningCommands { runningCommands = running }
        updateBubble()
    }

    // MARK: - Events → alerts

    private func drainEvents(startup: Bool = false) {
        guard !isDemo else { return }
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: NIPaths.events, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            let data = try? Data(contentsOf: f)
            try? fm.removeItem(at: f)
            if let data, let event = AgentEvent.decode(data) { handle(event) }
        }
    }

    /// Answers nobody picked up (the hook timed out or was killed).
    private func clearStaleResponses() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: NIPaths.responses, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: f)
        }
    }

    private func handle(_ e: AgentEvent) {
        let age = Date().timeIntervalSince(e.date)
        let project = e.project ?? ""
        switch e.kind {
        case .permission:
            guard age < 60, let rid = e.requestId else { return }
            send(.alert(IslandAlert(id: e.id, kind: .needsYou, title: e.title ?? "Claude needs permission",
                                    subtitle: project, detail: e.command ?? e.tool, sessionId: e.sessionId,
                                    requestId: rid, cwd: e.cwd, createdAt: e.date)))

        case .permissionResolved:
            if let rid = e.requestId { send(.requestResolved(rid)) }

        case .needsYou:
            guard age < 120 else { return }
            send(.alert(IslandAlert(id: e.id, kind: .needsYou, title: e.title ?? "Claude needs you",
                                    subtitle: project, detail: e.message, sessionId: e.sessionId, cwd: e.cwd,
                                    createdAt: e.date)))

        case .done:
            if let sid = e.sessionId { lastDone[sid] = e.date }
            guard age < 120, !shouldQuiet(pid: sessionPid(e.sessionId)) else { return }
            var parts = [project]
            if let n = e.filesChanged, n > 0 { parts.append(n == 1 ? "1 file changed" : "\(n) files changed") }
            if let ms = e.durationMs { parts.append(Fmt.minutes(Double(ms) / 1000)) }
            present(IslandAlert(id: e.id, kind: .done, title: e.title ?? "Claude finished",
                                subtitle: parts.filter { !$0.isEmpty }.joined(separator: " · "),
                                sessionId: e.sessionId, cwd: e.cwd, createdAt: e.date))

        case .failed:
            guard age < 120, !shouldQuiet(pid: sessionPid(e.sessionId)) else { return }
            let parts = [project, e.message.map { Fmt.truncate($0, 60) } ?? ""].filter { !$0.isEmpty }
            present(IslandAlert(id: e.id, kind: .failed, title: e.title ?? "Claude stopped with an error",
                                subtitle: parts.joined(separator: " · "), sessionId: e.sessionId,
                                cwd: e.cwd, createdAt: e.date))

        case .commandEnd:
            guard let command = e.command else { return }
            let duration = Double(e.durationMs ?? 0) / 1000
            let record = CommandRecord(id: e.id, command: command, cwd: e.cwd, exitCode: e.exitCode ?? 0,
                                       duration: duration, finishedAt: e.date)
            finishedCommands.insert(record, at: 0)
            if finishedCommands.count > 20 { finishedCommands.removeLast(finishedCommands.count - 20) }
            let threshold = settings.commandAlertSeconds
            guard age < 120, threshold > 0, duration >= Double(threshold),
                  !shouldQuiet(pid: e.shellPid.map(Int32.init)) else { return }
            let ok = record.exitCode == 0
            var parts = [project]
            if !ok { parts.append("exit \(record.exitCode)") }
            parts.append(Fmt.clock(duration))
            let name = Fmt.truncate(command, 36)
            present(IslandAlert(id: e.id, kind: ok ? .done : .failed, title: ok ? "\(name) finished" : "\(name) failed",
                                subtitle: parts.filter { !$0.isEmpty }.joined(separator: " · "),
                                cwd: e.cwd, pid: e.shellPid.map(Int32.init), createdAt: e.date))

        case .unknown:
            return
        }
    }

    private func sessionPid(_ sessionId: String?) -> Int32? {
        guard let sessionId else { return nil }
        return sessions.first { $0.sessionId == sessionId }?.pid
    }

    // MARK: - Alert actions

    func answer(_ alert: IslandAlert, allow: Bool) {
        guard let rid = alert.requestId else { return }
        if !isDemo {
            let response = PermissionResponse(decision: allow ? .allow : .deny)
            if let data = try? JSONEncoder().encode(response) {
                try? AtomicFile.write(data, to: PermissionResponse.url(for: rid))
            }
        }
        send(.requestResolved(rid))
    }

    func openTerminal(for alert: IslandAlert) {
        if let pid = alert.pid ?? sessions.first(where: { $0.sessionId == alert.sessionId })?.pid {
            ProcessControl.focusTerminal(for: pid)
        }
        if alert.requestId == nil { send(.dismissAlert(alert.id)) }
    }

    func focus(_ agent: AgentInfo) {
        ProcessControl.focusTerminal(for: agent.pid)
    }

    // MARK: - App icons (terminal / IDE that runs a session or command)

    private var iconCache: [Int32: NSImage] = [:]

    func appIcon(forPid pid: Int32?) -> NSImage? {
        if isDemo { return NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Terminal.app") }
        guard let pid, pid > 0 else { return nil }
        if let cached = iconCache[pid] { return cached }
        let icon = ProcessControl.terminalApp(for: pid)?.icon
        if let icon {
            if iconCache.count > 64 { iconCache.removeAll() }
            iconCache[pid] = icon
        }
        return icon
    }

    func sessionPidFor(_ sessionId: String?) -> Int32? { sessionPid(sessionId) }

    // MARK: - Working-dot pulse follows the burn rate

    /// Seconds per pulse: calm when on pace, faster when spending ahead of the window.
    var pulsePeriod: Double {
        guard let five = claudeUsage?.fiveHour?.current(),
              let elapsed = Pace.elapsed(resetsAt: five.resetsAt, window: 5 * 3600, now: Date()) else { return 1.6 }
        let lead = Pace.lead(usedPercent: five.usedPercent, elapsed: elapsed)
        switch lead {
        case 15...: return 0.75
        case 5..<15: return 1.1
        case ..<(-5): return 2.2
        default: return 1.6
        }
    }

    // MARK: - Split-off bubble for a long-running shell command

    static let bubbleAfter: TimeInterval = 3
    private var bubbleTimer: DispatchSourceTimer?

    /// While commands run, re-check once a second which one (if any) earns the bubble.
    private func updateBubble() {
        let now = Date()
        let candidate = runningCommands.last { now.timeIntervalSince($0.startDate) >= Self.bubbleAfter }
        if candidate != bubbleCommand {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) { bubbleCommand = candidate }
        }
        if runningCommands.isEmpty {
            bubbleTimer?.cancel()
            bubbleTimer = nil
        } else if bubbleTimer == nil {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.updateBubble() } }
            t.resume()
            bubbleTimer = t
        }
    }

    // MARK: - Header text

    struct HeaderStatus {
        var title: String
        var detail: String
        var color: Color
        var pulsing: Bool
    }

    func headerStatus(now: Date) -> HeaderStatus {
        let busy = sessions.filter(\.isBusy)
        if let n = island.needsYou {
            return HeaderStatus(title: "Claude needs you", detail: n.subtitle, color: Theme.amber, pulsing: true)
        }
        if busy.count == 1, let s = busy.first {
            return HeaderStatus(title: "Claude is working", detail: "\(s.project) · \(Fmt.minutes(now.timeIntervalSince(s.statusSince)))",
                                color: Theme.amber, pulsing: true)
        }
        if busy.count > 1 {
            return HeaderStatus(title: "Claude is working", detail: "\(busy.count) sessions", color: Theme.amber, pulsing: true)
        }
        if let s = sessions.first {
            let detail = sessions.count == 1 ? s.project : "\(sessions.count) sessions"
            return HeaderStatus(title: "Claude is idle", detail: detail, color: Theme.idleDot, pulsing: false)
        }
        return HeaderStatus(title: "All quiet", detail: "", color: Theme.idleDot, pulsing: false)
    }
}

// MARK: - Demo data (for screenshots: `NotchIsland --demo overview`)

extension AppModel {
    func loadDemo(_ name: String) {
        isDemo = true
        let now = Date()
        claudeUsage = UsageSnapshot(providerID: "claude",
                                    fiveHour: UsageWindow(usedPercent: 68, resetsAt: now.addingTimeInterval(102 * 60)),
                                    weekly: UsageWindow(usedPercent: 41, resetsAt: now.addingTimeInterval(3 * 86400)),
                                    updatedAt: now)
        codexUsage = UsageSnapshot(providerID: "codex", fiveHour: UsageWindow(usedPercent: 22, resetsAt: nil),
                                   weekly: nil, updatedAt: now)
        forecast = .hitsLimit(at: now.addingTimeInterval(96 * 60))
        portsLoaded = true
        ports = [
            PortEntry(port: 3000, pid: 1, command: "node", project: "ade-frontend", detail: "node · vite", container: nil),
            PortEntry(port: 8000, pid: 2, command: "main", project: "ade-backend", detail: "go run", container: nil),
            PortEntry(port: 5432, pid: 0, command: "docker", project: "db", detail: "postgres:16", container: "eap-db-1"),
            PortEntry(port: 8080, pid: 0, command: "docker", project: "proxy", detail: "eap-proxy", container: "eap-proxy-1"),
            PortEntry(port: 8443, pid: 0, command: "docker", project: "proxy", detail: "eap-proxy", container: "eap-proxy-1"),
        ]
        runningCommands = [RunningCommand(pid: 99, command: "npm run build", cwd: "/x/ade-frontend",
                                          started: now.addingTimeInterval(-134).timeIntervalSince1970)]
        finishedCommands = [CommandRecord(id: "c1", command: "pytest", cwd: "/x/ade-backend", exitCode: 0,
                                          duration: 38, finishedAt: now.addingTimeInterval(-60))]
        git = GitStatus(repo: "ade-backend", branch: "feature/notch-ui", changed: 4, ahead: 2,
                        userName: "Dev", userEmail: nil)
        gitIdentity = GitIdentity(githubUser: "octo-dev", name: nil, email: nil)
        sessions = [
            ClaudeSession(pid: 11, sessionId: "a", cwd: "/x/ade-frontend", status: "busy", updatedAt: now, statusSince: now.addingTimeInterval(-60)),
            ClaudeSession(pid: 12, sessionId: "b", cwd: "/x/ade-backend", status: "busy", updatedAt: now, statusSince: now.addingTimeInterval(-180)),
            ClaudeSession(pid: 13, sessionId: "c", cwd: "/x/docs", status: "idle", updatedAt: now, statusSince: now.addingTimeInterval(-120)),
            ClaudeSession(pid: 14, sessionId: "d", cwd: "/x/infra", status: "idle", updatedAt: now, statusSince: now.addingTimeInterval(-1500)),
        ]
        lastDone = ["c": now.addingTimeInterval(-120)]
        contextBySession = ["a": 34, "b": 83, "c": 12]
        claudeUsage?.fiveHour?.resetsAt = now.addingTimeInterval(150 * 60) // 50% of the window passed, 68% used
        burnRate = 0.62
        live = [
            LiveSession(id: "b", project: "ade-backend", pid: 12, busy: true,
                        activity: LiveActivity(turnStart: now.addingTimeInterval(-252), steps: [
                            LiveStep(id: "1", kind: .read, title: "Reading Ports.swift", pending: false),
                            LiveStep(id: "2", kind: .search, title: "Searching DockerPorts", pending: false),
                            LiveStep(id: "3", kind: .agent, title: "Agent: Review the diff", pending: false),
                            LiveStep(id: "4", kind: .edit, title: "Editing Cards.swift", pending: true),
                        ], filesChanged: 6, toolCalls: 42),
                        agents: [
                            .init(id: "a1", description: "Review the diff", type: "code-reviewer", running: true,
                                  step: LiveStep(id: "s", kind: .read, title: "Reading Usage.swift", pending: true)),
                            .init(id: "a2", description: "Compare notch apps", type: "web-fetch", running: false, step: nil),
                        ]),
            LiveSession(id: "a", project: "ade-frontend", pid: 11, busy: true,
                        activity: LiveActivity(turnStart: now.addingTimeInterval(-60), steps: [
                            LiveStep(id: "5", kind: .run, title: "Run the unit tests", pending: true),
                        ], filesChanged: 0, toolCalls: 3),
                        agents: []),
        ]
        // A plausible 2.5 h of usage for the sparkline: slow start, then a steeper climb.
        if let reset = claudeUsage?.fiveHour?.resetsAt {
            let start = reset.addingTimeInterval(-5 * 3600).timeIntervalSince1970
            let points: [(Double, Double)] = [(0, 0), (20, 6), (45, 12), (70, 19), (95, 31), (110, 44), (125, 55), (140, 63), (150, 68)]
            history = points.map { UsageSample(t: start + $0.0 * 60, pct: $0.1, reset: reset.timeIntervalSince1970) }
        }
        bubbleCommand = runningCommands.first
        ports[0].ownerName = "ade-frontend"
        ports[1].orphan = true
        for i in 2..<ports.count { ports[i].composeGroup = "employee-access-panel" }

        switch name {
        case "idle":
            sessions = []
        case "compact":
            send(.busyChanged(true))
        case "radar", "settings", "overview":
            if name != "radar" { sessions.removeFirst() }
            send(.busyChanged(true))
            send(.selectTab(IslandTab(rawValue: name) ?? .overview))
            send(.setPinned(true))
            if name == "radar" { demoWaiting = ["a"] }
        case "needs":
            send(.alert(IslandAlert(id: "p", kind: .needsYou, title: "Claude needs permission", subtitle: "ade-backend",
                                    detail: "docker compose down -v", sessionId: "b", requestId: "r")))
        case "limits":
            send(.alert(IslandAlert(id: "w1", kind: .warning, title: "Claude weekly limit at 84%", subtitle: "Resets in 13h 50m")))
            send(.alert(IslandAlert(id: "w2", kind: .failed, title: "Claude 5-hour limit at 95%",
                                    subtitle: "Resets in 1h 12m · at this pace full at 15:20")))
            send(.alert(IslandAlert(id: "w3", kind: .done, title: "Claude 5-hour limit reset", subtitle: "Full limit available again")))
        case "done":
            send(.alert(IslandAlert(id: "d", kind: .done, title: "Claude finished", subtitle: "ade-backend · 6 files changed · 4 min")))
            send(.alert(IslandAlert(id: "f", kind: .failed, title: "npm run build failed", subtitle: "ade-frontend · exit 1 · 2:14")))
        default:
            break
        }
    }
}
