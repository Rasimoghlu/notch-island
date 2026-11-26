import AppKit
import NotchIslandCore

@main
enum NotchIslandMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // also LSUIElement in Info.plist: no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var panel: PanelController?
    private var statusItem: NSStatusItem?
    private var signalSources: [DispatchSourceSignal] = []
    private weak var muteItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if Snapshot.run(args: args, model: model) { return }
        if let i = args.firstIndex(of: "--demo"), i + 1 < args.count {
            // Sample data for screenshots; no files are read or written.
            model.loadDemo(args[i + 1])
        } else {
            NIPaths.ensureDirectories()
            writePidFile()
            linkHookBinary()
            model.start()
        }
        panel = PanelController(model: model)
        setUpStatusItem()
        handleTerminationSignals()
    }

    /// `kill` / Ctrl-C: quit normally so the pid file is removed and hooks go quiet.
    private func handleTerminationSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !model.isDemo { try? FileManager.default.removeItem(at: NIPaths.pidFile) }
    }

    private func writePidFile() {
        try? AtomicFile.write(Data("\(getpid())\n".utf8), to: NIPaths.pidFile)
    }

    /// ~/.notch-island/bin/notch-hook → the copy inside this app bundle, so the hook path in
    /// Claude's settings stays stable when the app is rebuilt or moved.
    private func linkHookBinary() {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/notch-hook")
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("notch-hook")
        let fm = FileManager.default
        guard let target = [bundled, sibling].compactMap({ $0 }).first(where: { fm.isExecutableFile(atPath: $0.path) }) else { return }
        let link = NIPaths.bin.appendingPathComponent("notch-hook")
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == target.path { return }
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(at: link, withDestinationURL: target)
    }

    // MARK: Menu bar item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Notch Island")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Island", action: #selector(showIsland), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        let mute = menu.addItem(withTitle: "Mute Alerts for 1 Hour", action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        muteItem = mute
        menu.addItem(withTitle: "Open ~/.notch-island", action: #selector(openFolder), keyEquivalent: "").target = self
        menu.delegate = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Notch Island", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func showIsland() {
        model.send(.selectTab(.overview))
        model.send(.setPinned(true))
    }

    @objc private func showSettings() {
        model.send(.selectTab(.settings))
        model.send(.setPinned(true))
    }

    @objc private func toggleMute() {
        model.mute(for: model.settings.isMuted ? nil : 3600)
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(NIPaths.root)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if model.settings.isMuted, let until = model.settings.mutedUntil {
            muteItem?.title = "Unmute Alerts (muted until \(Fmt.timeOfDay(until)))"
        } else {
            muteItem?.title = "Mute Alerts for 1 Hour"
        }
    }
}
