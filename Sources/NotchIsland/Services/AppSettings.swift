import Foundation
import NotchIslandCore
import ServiceManagement

/// The few user preferences, stored in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Shell commands at least this long pop a done/failed alert. 0 = never.
    @Published var commandAlertSeconds: Int {
        didSet { defaults.set(commandAlertSeconds, forKey: "commandAlertSeconds") }
    }

    /// Show the compact "working" notch while Claude runs.
    @Published var showWorking: Bool {
        didSet { defaults.set(showWorking, forKey: "showWorking") }
    }

    /// Ports card lists only dev servers started from project folders (plus Docker).
    @Published var projectPortsOnly: Bool {
        didSet { defaults.set(projectPortsOnly, forKey: "projectPortsOnly") }
    }

    /// Skip done/failed alerts when the terminal that ran the job is already the front app.
    @Published var quietWhenTerminalFront: Bool {
        didSet { defaults.set(quietWhenTerminalFront, forKey: "quietWhenTerminalFront") }
    }

    /// Exclude the island from screenshots, screen recording and screen sharing.
    @Published var hideFromScreenSharing: Bool {
        didSet { defaults.set(hideFromScreenSharing, forKey: "hideFromScreenSharing") }
    }

    /// ⌃⌥Y / ⌃⌥N / ⌃⌥T while a permission request is showing.
    @Published var shortcutsEnabled: Bool {
        didSet { defaults.set(shortcutsEnabled, forKey: "shortcutsEnabled") }
    }

    /// Alerts other than "needs you" are muted until this time.
    @Published var mutedUntil: Date? {
        didSet { defaults.set(mutedUntil, forKey: "mutedUntil") }
    }

    var isMuted: Bool { (mutedUntil ?? .distantPast) > Date() }

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginError: String?

    init() {
        defaults.register(defaults: ["commandAlertSeconds": 30, "showWorking": true, "projectPortsOnly": true,
                                     "quietWhenTerminalFront": true, "hideFromScreenSharing": true, "shortcutsEnabled": true])
        commandAlertSeconds = defaults.integer(forKey: "commandAlertSeconds")
        showWorking = defaults.bool(forKey: "showWorking")
        projectPortsOnly = defaults.bool(forKey: "projectPortsOnly")
        quietWhenTerminalFront = defaults.bool(forKey: "quietWhenTerminalFront")
        hideFromScreenSharing = defaults.bool(forKey: "hideFromScreenSharing")
        shortcutsEnabled = defaults.bool(forKey: "shortcutsEnabled")
        mutedUntil = defaults.object(forKey: "mutedUntil") as? Date
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not change login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Read-only check of what the install script has set up. Never writes.
struct HookStatus: Equatable {
    var claudeHooks = false
    var permissionHook = false
    var statusLine = false
    var zsh = false
    var usageData = false

    static func detect() -> HookStatus {
        var s = HookStatus()
        if let text = try? String(contentsOf: NIPaths.claudeSettings, encoding: .utf8) {
            let ours = text.contains("notch-hook")
            s.claudeHooks = ours && text.contains("claude Stop")
            s.permissionHook = ours && text.contains("claude PermissionRequest")
            s.statusLine = ours && text.contains("\" statusline")
        }
        if let zshrc = try? String(contentsOf: NIPaths.home.appendingPathComponent(".zshrc"), encoding: .utf8) {
            s.zsh = zshrc.contains("notch-island.zsh")
        }
        s.usageData = FileManager.default.fileExists(atPath: NIPaths.claudeUsageFile.path)
        return s
    }
}
