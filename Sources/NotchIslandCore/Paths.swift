import Foundation

/// Every file location the app and the hook CLI agree on.
public enum NIPaths {
    public static var home: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

    /// ~/.notch-island — owned by this app.
    public static var root: URL { home.appendingPathComponent(".notch-island", isDirectory: true) }
    /// Hooks drop one JSON file per event here; the app consumes and deletes them.
    public static var events: URL { root.appendingPathComponent("events", isDirectory: true) }
    /// The app writes Allow/Deny answers here; the blocking PermissionRequest hook polls for them.
    public static var responses: URL { root.appendingPathComponent("responses", isDirectory: true) }
    /// Rate-limit snapshots written by the status-line command.
    public static var usage: URL { root.appendingPathComponent("usage", isDirectory: true) }
    /// One file per interactive zsh with the command that is currently running.
    public static var shell: URL { root.appendingPathComponent("shell", isDirectory: true) }
    public static var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
    public static var pidFile: URL { root.appendingPathComponent("app.pid") }
    public static var claudeUsageFile: URL { usage.appendingPathComponent("claude.json") }
    public static var claudeHistoryFile: URL { usage.appendingPathComponent("claude-history.json") }
    /// An existing status-line command that ours should run and print instead of its own line.
    public static var statuslineChainFile: URL { root.appendingPathComponent("statusline-chain") }

    public static var claudeHome: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    public static var claudeSessions: URL { claudeHome.appendingPathComponent("sessions", isDirectory: true) }
    public static var claudeProjects: URL { claudeHome.appendingPathComponent("projects", isDirectory: true) }
    public static var claudeSettings: URL { claudeHome.appendingPathComponent("settings.json") }
    public static var codexSessions: URL { home.appendingPathComponent(".codex/sessions", isDirectory: true) }

    public static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [root, events, responses, usage, shell, bin] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Write-then-rename so readers never see half-written JSON.
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: tmp)
        if rename(tmp.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

/// Whether the app is running, judged by its pid file. Hooks use this to stay silent otherwise.
public enum AppLiveness {
    public static func runningPid() -> Int32? {
        guard let text = try? String(contentsOf: NIPaths.pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return nil }
        return isAlive(pid) ? pid : nil
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
