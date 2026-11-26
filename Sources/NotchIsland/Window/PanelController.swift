import AppKit
import Combine
import SwiftUI
import NotchIslandCore

/// Borderless, non-activating panel above the menu bar, on every Space and over full-screen apps.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(origin: .zero, size: IslandLayout.panelSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }

    // Key status lets buttons and toggles work; the panel never activates the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Positions the panel and decides when it catches the mouse.
///
/// The panel is a fixed transparent rectangle, so by default it ignores the mouse and clicks
/// fall through to the menu bar. A mouse-moved monitor turns hit-testing on only while the
/// pointer is inside the current shape, and drives hover with a short enter delay and leave grace
/// (see `Motion`).
@MainActor
final class PanelController {
    private let model: AppModel
    private let panel = NotchPanel()
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var enterWork: DispatchWorkItem?
    private var exitWork: DispatchWorkItem?
    private var inside = false
    private var screenTop: CGFloat = 0
    private var centerX: CGFloat = 0

    static let enterDelay = Motion.hoverDelay
    static let leaveGrace = Motion.leaveGrace

    init(model: AppModel) {
        self.model = model
        let root = IslandRootView().environmentObject(model)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: IslandLayout.panelSize)
        panel.contentView = host
        layout()
        panel.orderFrontRegardless()

        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: moved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateMouse() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: moved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.evaluateMouse() }
            return event
        }) { monitors.append(l) }
        // A click anywhere else closes a panel opened from the menu bar.
        if let c = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) { monitors.append(c) }

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.layout() } }
            .store(in: &cancellables)
        // @Published fires before the value changes; re-check on the next run-loop turn.
        model.settings.$hideFromScreenSharing
            .sink { [weak self] hide in self?.panel.sharingType = hide ? .none : .readOnly }
            .store(in: &cancellables)
        model.$island
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.evaluateMouse() } } }
            .store(in: &cancellables)
        model.$bubbleCommand
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.evaluateMouse() } } }
            .store(in: &cancellables)
    }

    func layout() {
        guard let g = ScreenGeometry.detect() else { return }
        if model.geometry != g.island { model.geometry = g.island }
        screenTop = g.screen.frame.maxY
        centerX = g.centerX
        let size = IslandLayout.panelSize
        panel.setFrame(NSRect(x: (g.centerX - size.width / 2).rounded(), y: g.screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    /// The shape's rectangle in global screen coordinates.
    private func hotRect() -> NSRect {
        let spec = IslandLayout.spec(model.island, model.geometry, extra: model.overviewExtra)
        var r = NSRect(x: centerX - spec.size.width / 2, y: screenTop - spec.size.height,
                       width: spec.size.width, height: spec.size.height)
        if model.island.phase == .idle || model.island.phase == .compact {
            // A little slack so the small shape is easy to hit.
            r = r.insetBy(dx: -8, dy: 0)
            r.origin.y -= 6
            r.size.height += 6
        }
        r.size.height += 2 // include the very top pixel row
        if model.bubbleCommand != nil, model.island.phase == .idle || model.island.phase == .compact {
            let size = IslandLayout.bubbleSize(model.geometry)
            let cx = centerX + IslandLayout.bubbleOffset(spec, model.geometry)
            r = r.union(NSRect(x: cx - size / 2 - 6, y: screenTop - size - 4, width: size + 12, height: size + 6))
        }
        return r
    }

    private func evaluateMouse() {
        let now = hotRect().contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !now
        guard now != inside else { return }
        inside = now
        if now {
            exitWork?.cancel()
            guard !model.island.hovering else { return }
            if model.island.phase == .idle || model.island.phase == .compact { model.hoverIntent = true }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.inside else { return }
                    self.model.send(.hoverBegan)
                    self.model.hoverIntent = false
                }
            }
            enterWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.enterDelay, execute: work)
        } else {
            enterWork?.cancel()
            if model.hoverIntent { model.hoverIntent = false }
            guard model.island.hovering else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.inside else { return }
                    self.model.send(.hoverEnded)
                }
            }
            exitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaveGrace, execute: work)
        }
    }

    private func clickedOutside() {
        guard model.island.pinned, !hotRect().contains(NSEvent.mouseLocation) else { return }
        model.send(.setPinned(false))
    }
}
