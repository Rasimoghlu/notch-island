import AppKit
import CoreServices
import NotchIslandCore

/// Runs a command synchronously with a timeout. Call from a background queue.
enum Shell {
    struct Result {
        let status: Int32
        let out: String
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 3) -> Result? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        let extra = ["/usr/local/bin", "/opt/homebrew/bin", NIPaths.home.appendingPathComponent(".docker/bin").path]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return Result(status: p.terminationStatus, out: String(decoding: data, as: UTF8.self))
    }

    static func firstExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// FSEvents with file-level events, delivered on the main queue after `latency`.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let handler: () -> Void

    init?(paths: [URL], latency: TimeInterval = 0.25, handler: @escaping () -> Void) {
        self.handler = handler
        let existing = paths.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().handler()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, existing as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}

enum ProcessControl {
    static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// The GUI app (terminal, IDE) that `pid` runs under, found by walking up the parent chain.
    static func terminalApp(for pid: pid_t) -> NSRunningApplication? {
        var current: pid_t? = pid
        for _ in 0..<16 {
            guard let p = current, p > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular {
                return app
            }
            current = parentPid(of: p)
        }
        return nil
    }

    /// Brings the terminal that runs `pid` forward.
    @discardableResult
    static func focusTerminal(for pid: pid_t) -> Bool {
        terminalApp(for: pid)?.activate() ?? false
    }

    /// True when the terminal running `pid` is the frontmost app.
    static func isTerminalFrontmost(for pid: pid_t) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication, let app = terminalApp(for: pid) else { return false }
        return front.processIdentifier == app.processIdentifier
    }

    static func terminate(pid: pid_t) -> Bool {
        guard pid > 1, pid != getpid() else { return false }
        return kill(pid, SIGTERM) == 0
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// Seconds since the last keyboard/mouse/trackpad input. No permission needed.
enum UserActivity {
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

enum Docker {
    static var cli: String? {
        Shell.firstExecutable([
            "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
            NIPaths.home.appendingPathComponent(".docker/bin/docker").path,
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ])
    }

    /// Only talk to Docker when a daemon socket exists, so a stopped Docker costs nothing.
    static var daemonLikelyRunning: Bool {
        let sockets = [
            NIPaths.home.appendingPathComponent(".docker/run/docker.sock").path,
            "/var/run/docker.sock",
            NIPaths.home.appendingPathComponent(".orbstack/run/docker.sock").path,
        ]
        return sockets.contains { path in
            var st = stat()
            return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
        }
    }

    static func publishes() -> [DockerPublish] {
        guard daemonLikelyRunning, let cli else { return [] }
        guard let r = Shell.run(cli, ["ps", "--format", DockerPortsParser.format], timeout: 2), r.status == 0 else { return [] }
        return DockerPortsParser.parse(r.out)
    }

    static func stop(_ container: String) -> Bool {
        guard let cli else { return false }
        return Shell.run(cli, ["stop", container], timeout: 20)?.status == 0
    }
}

struct GitStatus: Equatable {
    var repo: String
    var branch: String
    var changed: Int
    var ahead: Int?
    /// user.name / user.email as git resolves them in this repo (local, then global).
    var userName: String?
    var userEmail: String?
}

enum Git {
    static func status(at cwd: String) -> GitStatus? {
        let git = "/usr/bin/git"
        guard let top = Shell.run(git, ["-C", cwd, "rev-parse", "--show-toplevel"]), top.status == 0 else { return nil }
        let root = top.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = Shell.run(git, ["-C", root, "rev-parse", "--abbrev-ref", "HEAD"])?.out
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        let porcelain = Shell.run(git, ["-C", root, "status", "--porcelain=v1"], timeout: 5)?.out ?? ""
        let changed = porcelain.split(separator: "\n").count
        var ahead: Int?
        if let r = Shell.run(git, ["-C", root, "rev-list", "--count", "@{upstream}..HEAD"]), r.status == 0 {
            ahead = Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        func config(_ key: String) -> String? {
            let v = Shell.run(git, ["-C", root, "config", key])?.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty ?? true) ? nil : v
        }
        return GitStatus(repo: URL(fileURLWithPath: root).lastPathComponent, branch: branch, changed: changed, ahead: ahead,
                         userName: config("user.name"), userEmail: config("user.email"))
    }

    /// First folder in `candidates` that is inside a git repository.
    static func firstRepo(_ candidates: [String]) -> GitStatus? {
        var tried = Set<String>()
        for dir in candidates where tried.insert(dir).inserted {
            if let s = status(at: dir) { return s }
        }
        return nil
    }

    /// The account this Mac uses: gh's GitHub login (local file) and global git identity.
    static func identity() -> GitIdentity {
        let hosts = NIPaths.home.appendingPathComponent(".config/gh/hosts.yml")
        let gh = (try? String(contentsOf: hosts, encoding: .utf8)).flatMap(GitIdentity.githubUser(fromHostsYAML:))
        func global(_ key: String) -> String? {
            let v = Shell.run("/usr/bin/git", ["config", "--global", key])?.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty ?? true) ? nil : v
        }
        return GitIdentity(githubUser: gh, name: global("user.name"), email: global("user.email"))
    }
}

enum PortScanner {
    static func scan(projectsOnly: Bool, excludePids: Set<Int32>, agentSessions: [Int32: String]) -> [PortEntry] {
        guard let listen = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"], timeout: 4) else { return [] }
        let sockets = LsofParser.parseListen(listen.out)
        var cwds: [Int32: String] = [:]
        var args: [Int32: String] = [:]
        let pids = Set(sockets.map(\.pid)).map(String.init).joined(separator: ",")
        if !pids.isEmpty {
            if let r = Shell.run("/usr/sbin/lsof", ["-a", "-p", pids, "-d", "cwd", "-Fn"], timeout: 4) {
                cwds = LsofParser.parseCwd(r.out)
            }
            if let r = Shell.run("/bin/ps", ["-o", "pid=,args=", "-p", pids]) {
                args = PsParser.parse(r.out)
            }
        }
        // Whole process tree (one cheap ps call): links servers to the Claude session that
        // started them and spots orphans whose parent is gone.
        let parents = Shell.run("/bin/ps", ["-axo", "pid=,ppid="]).map { PsParser.parents($0.out) } ?? [:]
        return PortAssembler.assemble(sockets: sockets, cwds: cwds, args: args, docker: Docker.publishes(),
                                      projectsOnly: projectsOnly, excludePids: excludePids,
                                      parents: parents, agentSessions: agentSessions)
    }
}
