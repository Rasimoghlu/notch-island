import AppKit
import SwiftUI
import NotchIslandCore

/// Developer tool: renders the island offscreen to PNG files, no Screen Recording permission needed.
///
///   NotchIsland --snapshot overview out.png
///   NotchIsland --snapshot-morph compact:expanded out-prefix   (frames during the transition)
@MainActor
enum Snapshot {
    /// Snapshots draw the camera cut-out in red so overlaps are easy to spot.
    static var showNotchHole = false

    static func run(args: [String], model: AppModel) -> Bool {
        guard args.contains("--snapshot") || args.contains("--snapshot-morph") else { return false }
        showNotchHole = !args.contains("--no-notch")
        if let g = ScreenGeometry.detect() { model.geometry = g.island } // this Mac's real notch
        if let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count {
            model.loadDemo(args[i + 1])
            render(model: model, frames: [1.4], prefix: args[i + 2], change: nil)
            return true
        }
        if let i = args.firstIndex(of: "--snapshot-morph"), i + 2 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 2 else { return false }
            model.loadDemo(parts[0])
            // NOTCH_SNAPSHOT_TIMES="0.15,0.3" captures at those offsets after the change.
            var times: [Double] = [0.9, 1.0, 1.08, 1.16, 1.24, 1.34, 1.5, 2.2]
            if let custom = ProcessInfo.processInfo.environment["NOTCH_SNAPSHOT_TIMES"] {
                times = [0.9] + custom.split(separator: ",").compactMap { Double($0) }.map { 0.9 + $0 }
            }
            render(model: model, frames: times, prefix: args[i + 2]) {
                switch parts[1] {
                case "expanded": model.send(.hoverBegan)
                case "collapsed": model.send(.hoverEnded); model.send(.setPinned(false))
                case "done":
                    model.send(.alert(IslandAlert(id: "d", kind: .done, title: "Claude finished",
                                                  subtitle: "ade-backend · 6 files changed · 4 min")))
                case "needs":
                    model.send(.alert(IslandAlert(id: "p", kind: .needsYou, title: "Claude needs permission",
                                                  subtitle: "ade-backend", detail: "docker compose down -v",
                                                  sessionId: "b", requestId: "r")))
                default: break
                }
            }
            return true
        }
        return false
    }

    /// `change` fires at 0.9 s; frames are captured at the given absolute times.
    private static func render(model: AppModel, frames: [Double], prefix: String, change: (() -> Void)?) {
        let size = NSSize(width: IslandLayout.panelSize.width, height: IslandLayout.panelSize.height)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        let host = NSHostingView(rootView: IslandRootView().environmentObject(model))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()

        let start = Date()
        if let change {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                change()
            }
        }
        for (n, t) in frames.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                let path = frames.count == 1 ? prefix : "\(prefix)-\(n)-\(Int((Date().timeIntervalSince(start) - 0.9) * 1000))ms.png"
                save(host, to: path)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (frames.last ?? 1) + 0.3) { NSApp.terminate(nil) }
    }

    private static func save(_ view: NSView, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
