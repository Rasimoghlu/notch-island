import Foundation

public struct ListeningSocket: Equatable, Sendable {
    public var pid: Int32
    public var command: String
    public var port: Int

    public init(pid: Int32, command: String, port: Int) {
        self.pid = pid
        self.command = command
        self.port = port
    }
}

public struct DockerPublish: Equatable, Sendable {
    public var name: String
    public var image: String
    public var hostPort: Int
    /// docker compose labels, when the container belongs to a compose project.
    public var composeProject: String?
    public var service: String?
    public var workingDir: String?

    public init(name: String, image: String, hostPort: Int,
                composeProject: String? = nil, service: String? = nil, workingDir: String? = nil) {
        self.name = name
        self.image = image
        self.hostPort = hostPort
        self.composeProject = composeProject
        self.service = service
        self.workingDir = workingDir
    }
}

public struct PortEntry: Equatable, Identifiable, Sendable {
    public var port: Int
    /// 0 for Docker ports with no visible host process.
    public var pid: Int32
    public var command: String
    /// Project folder name (from the process cwd) or container name.
    public var project: String
    /// "node · vite", "docker · postgres:16"
    public var detail: String
    /// Set for Docker-published ports: "Kill" stops the container instead of signalling a pid.
    public var container: String?
    /// Compose project folder name (or project label) for grouping Docker rows.
    public var composeGroup: String?
    /// Working directory of the server process, or the compose project folder.
    public var cwd: String?
    /// The Claude Code session whose process tree started this server (session id), if any.
    public var ownerSession: String?
    /// Display name of the Claude session that started it (kept after the session ends).
    public var ownerName: String?
    /// The process that started the server is gone (it was re-parented to launchd).
    public var orphan = false

    public init(port: Int, pid: Int32, command: String, project: String, detail: String, container: String?) {
        self.port = port
        self.pid = pid
        self.command = command
        self.project = project
        self.detail = detail
        self.container = container
    }

    public var id: String { "\(port)-\(pid)-\(container ?? "")" }

    /// Ports that speak a database / broker protocol, not HTTP: no "open in browser".
    static let nonHTTPPorts: Set<Int> = [
        22, 25, 465, 587, 1025, 1433, 1521, 2181, 3306, 3893, 5432, 5433, 5672, 6379, 6380,
        9042, 9092, 9200, 9300, 11211, 27017, 27018, 389, 636, 4222, 61616, 1883,
    ]

    /// http://localhost:PORT, https for ports ending in 443, nil for non-HTTP services.
    public var url: URL? {
        if Self.nonHTTPPorts.contains(port) { return nil }
        let scheme = (port == 443 || port % 1000 == 443) ? "https" : "http"
        return URL(string: "\(scheme)://localhost:\(port)")
    }
}

public enum LsofParser {
    /// Parses `lsof -nP -iTCP -sTCP:LISTEN -F pcn`. One entry per (pid, port).
    public static func parseListen(_ out: String) -> [ListeningSocket] {
        var result: [ListeningSocket] = []
        var seen = Set<String>()
        var pid: Int32 = 0
        var command = ""
        for line in out.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int32(value) ?? 0
                command = ""
            case "c":
                command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let key = "\(pid):\(port)"
                if pid > 0, seen.insert(key).inserted {
                    result.append(ListeningSocket(pid: pid, command: command, port: port))
                }
            default:
                continue
            }
        }
        return result
    }

    /// Parses `lsof -a -p PIDS -d cwd -Fn` into pid → cwd.
    public static func parseCwd(_ out: String) -> [Int32: String] {
        var map: [Int32: String] = [:]
        var pid: Int32 = 0
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n"), pid > 0 { map[pid] = String(line.dropFirst()) }
        }
        return map
    }
}

public enum PsParser {
    /// Parses `ps -o pid=,args= -p PIDS`.
    /// Parses `ps -axo pid=,ppid=` into pid → parent pid.
    public static func parents(_ out: String) -> [Int32: Int32] {
        var map: [Int32: Int32] = [:]
        for raw in out.split(separator: "\n") {
            let cols = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2, let pid = Int32(cols[0]), let ppid = Int32(cols[1]) else { continue }
            map[pid] = ppid
        }
        return map
    }

    public static func parse(_ out: String) -> [Int32: String] {
        var map: [Int32: String] = [:]
        for raw in out.split(separator: "\n") {
            let line = raw.drop { $0 == " " }
            guard let space = line.firstIndex(of: " "), let pid = Int32(line[..<space]) else { continue }
            map[pid] = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        }
        return map
    }

    /// Recognisable dev-server names found in a command line.
    static let hints: [(needle: String, label: String)] = [
        ("vite", "vite"), ("next", "next"), ("nuxt", "nuxt"), ("astro", "astro"), ("remix", "remix"),
        ("webpack", "webpack"), ("storybook", "storybook"), ("expo", "expo"), ("nodemon", "nodemon"),
        ("tsx", "tsx"), ("bun", "bun"), ("deno", "deno"),
        ("uvicorn", "uvicorn"), ("gunicorn", "gunicorn"), ("flask", "flask"), ("manage.py", "django"),
        ("rails", "rails"), ("puma", "puma"), ("artisan", "laravel"), ("hugo", "hugo"), ("jekyll", "jekyll"),
        ("go-build", "go run"), ("cargo", "cargo"), ("mvn", "maven"), ("gradle", "gradle"),
    ]

    public static func hint(for args: String, command: String) -> String? {
        let lower = args.lowercased()
        for h in hints where h.label != command.lowercased() {
            if lower.contains(h.needle) { return h.label }
        }
        return nil
    }
}

public enum DockerPortsParser {
    /// The `docker ps --format` template `parse` expects.
    public static let format = "{{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Label \"com.docker.compose.project\"}}\t{{.Label \"com.docker.compose.service\"}}\t{{.Label \"com.docker.compose.project.working_dir\"}}"

    /// Parses `docker ps --format format` (the last three label columns are optional).
    /// Ports look like "0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp".
    public static func parse(_ out: String) -> [DockerPublish] {
        var result: [DockerPublish] = []
        var seen = Set<Int>()
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 3 else { continue }
            for mapping in cols[2].split(separator: ",") {
                let m = mapping.trimmingCharacters(in: .whitespaces)
                guard let arrow = m.range(of: "->") else { continue }
                let host = m[..<arrow.lowerBound]
                guard let colon = host.lastIndex(of: ":"),
                      let port = Int(host[host.index(after: colon)...]) else { continue }
                if seen.insert(port).inserted {
                    func col(_ i: Int) -> String? { cols.count > i && !cols[i].isEmpty ? cols[i] : nil }
                    result.append(DockerPublish(name: cols[0], image: cols[1], hostPort: port,
                                                composeProject: col(3), service: col(4), workingDir: col(5)))
                }
            }
        }
        return result
    }
}

public enum PortAssembler {
    static let dockerBackends = ["com.docke", "com.docker", "vpnkit", "docker", "OrbStack", "limactl", "colima"]

    /// A process counts as a project server when its working directory is a project folder:
    /// inside home (not home itself, ~/Library or a hidden ~/.folder), or on an external volume.
    /// Apps and system daemons run from "/" and are left out.
    public static func isProjectDirectory(_ cwd: String?, home: String = NSHomeDirectory()) -> Bool {
        guard let cwd, !cwd.isEmpty else { return false }
        if cwd.hasPrefix("/Volumes/") { return true }
        guard cwd.hasPrefix(home + "/") else { return false }
        let rest = cwd.dropFirst(home.count + 1)
        let first = rest.split(separator: "/").first.map(String.init) ?? ""
        return !first.isEmpty && !first.hasPrefix(".") && first != "Library" && first != "Applications"
    }

    /// Coding agents listen on localhost for their own IDE/MCP plumbing; those are not project ports.
    /// Claude Code's native binary is named after its version, e.g. "2.1.330".
    public static func isAgentProcess(_ command: String) -> Bool {
        let c = command.lowercased()
        if c == "claude" || c == "codex" { return true }
        return command.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
    }

    public static func assemble(sockets: [ListeningSocket], cwds: [Int32: String], args: [Int32: String],
                                docker: [DockerPublish], ownPid: Int32 = getpid(),
                                projectsOnly: Bool = false, excludePids: Set<Int32> = [],
                                home: String = NSHomeDirectory(),
                                parents: [Int32: Int32] = [:], agentSessions: [Int32: String] = [:]) -> [PortEntry] {
        let dockerByPort = Dictionary(docker.map { ($0.hostPort, $0) }, uniquingKeysWith: { a, _ in a })
        var entries: [PortEntry] = []
        var usedDockerPorts = Set<Int>()
        // One row per port; IPv4/IPv6 listeners of the same pid are already merged.
        var seenPorts = Set<Int>()
        for s in sockets.sorted(by: { $0.port < $1.port }) where s.pid != ownPid {
            if let d = dockerByPort[s.port],
               dockerBackends.contains(where: { s.command.localizedCaseInsensitiveContains($0) }) {
                guard seenPorts.insert(s.port).inserted else { continue }
                usedDockerPorts.insert(s.port)
                entries.append(dockerEntry(d, pid: s.pid))
                continue
            }
            if projectsOnly {
                if excludePids.contains(s.pid) || isAgentProcess(s.command) { continue }
                if !isProjectDirectory(cwds[s.pid], home: home) { continue }
            }
            guard seenPorts.insert(s.port).inserted else { continue }
            let command = s.command.replacingOccurrences(of: "\\x20", with: " ")
            let project = Fmt.project(cwds[s.pid]).flatMap { $0 == NSUserName() ? nil : $0 } ?? command
            var detail = command.lowercased()
            if let a = args[s.pid], let h = PsParser.hint(for: a, command: command) { detail += " · \(h)" }
            var entry = PortEntry(port: s.port, pid: s.pid, command: command, project: project,
                                  detail: detail, container: nil)
            entry.ownerSession = owner(of: s.pid, parents: parents, agentSessions: agentSessions)
            entry.cwd = cwds[s.pid]
            entry.orphan = !parents.isEmpty && parents[s.pid] == 1
            entries.append(entry)
        }
        for d in docker where !usedDockerPorts.contains(d.hostPort) && !seenPorts.contains(d.hostPort) {
            entries.append(dockerEntry(d, pid: 0))
        }
        return entries.sorted { $0.port < $1.port }
    }

    /// Walks up the process tree from `pid` to the first Claude Code session process.
    public static func owner(of pid: Int32, parents: [Int32: Int32], agentSessions: [Int32: String]) -> String? {
        var current: Int32? = parents[pid]
        for _ in 0..<32 {
            guard let p = current, p > 1 else { return nil }
            if let sid = agentSessions[p] { return sid }
            current = parents[p]
        }
        return nil
    }

    /// Compose containers are named by service ("app", "db"); grouped by project folder.
    private static func dockerEntry(_ d: DockerPublish, pid: Int32) -> PortEntry {
        let image = d.image.split(separator: "/").last.map(String.init) ?? d.image
        var e = PortEntry(port: d.hostPort, pid: pid, command: "docker", project: d.service ?? d.name,
                          detail: image, container: d.name)
        e.composeGroup = Fmt.project(d.workingDir) ?? d.composeProject
        e.cwd = d.workingDir
        return e
    }
}
