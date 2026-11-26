import AppKit
import SwiftUI

/// Environment flag: loops (pulse, glow, wave, orbit) run only when this is true.
/// False under Reduce Motion or Low Power Mode.
private struct LoopsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var loopsEnabled: Bool {
        get { self[LoopsEnabledKey.self] }
        set { self[LoopsEnabledKey.self] = newValue }
    }
}

/// opacity 0.35 → 1 and scale 0.8 → 1, 1.6 s ease-in-out, forever.
struct Pulse: ViewModifier {
    var minOpacity: Double = 0.35
    var minScale: CGFloat = 0.8
    var period: Double = 1.6
    @Environment(\.loopsEnabled) private var loops
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .opacity(loops ? (on ? 1 : minOpacity) : 1)
            .scaleEffect(loops ? (on ? 1 : minScale) : 1)
            .onAppear { start() }
            .onChange(of: loops) { start() }
    }

    private func start() {
        guard loops else { on = false; return }
        on = false
        withAnimation(.easeInOut(duration: period / 2).repeatForever(autoreverses: true)) { on = true }
    }
}

/// The amber halo around the shape while Claude needs you. The only glowing state.
struct NeedsYouGlow: ViewModifier {
    var active: Bool
    @Environment(\.loopsEnabled) private var loops
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .shadow(color: Theme.amber.opacity(active ? (loops ? (on ? 0.55 : 0) : 0.4) : 0),
                    radius: active ? (loops ? (on ? 28 : 2) : 18) : 0)
            .onChange(of: active, initial: true) { restart() }
            .onChange(of: loops) { restart() }
    }

    private func restart() {
        on = false
        guard active, loops else { return }
        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { on = true }
    }
}

extension View {
    func pulsing(minOpacity: Double = 0.35, minScale: CGFloat = 0.8) -> some View {
        modifier(Pulse(minOpacity: minOpacity, minScale: minScale))
    }
}

/// A status dot: amber pulsing while working.
/// The pulse is a Core Animation layer animation, so it runs in the render server and
/// costs the app ~nothing (a SwiftUI repeatForever re-evaluates the view every frame).
struct StatusDot: View {
    var color: Color
    var pulsing: Bool
    var size: CGFloat = 8
    /// Seconds per pulse (in and out).
    var period: Double = 1.6
    @Environment(\.loopsEnabled) private var loops

    var body: some View {
        PulsingDotLayer(color: NSColor(color), pulsing: pulsing && loops, period: period)
            .frame(width: size, height: size)
    }
}

private struct PulsingDotLayer: NSViewRepresentable {
    var color: NSColor
    var pulsing: Bool
    var period: Double

    func makeNSView(context: Context) -> DotView { DotView() }

    func updateNSView(_ view: DotView, context: Context) {
        view.update(color: color, pulsing: pulsing, period: period)
    }

    final class DotView: NSView {
        private let dot = CALayer()
        private var isPulsing = false
        private var period: Double = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(dot)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.frame = bounds
            dot.cornerRadius = bounds.width / 2
            CATransaction.commit()
        }

        func update(color: NSColor, pulsing: Bool, period: Double) {
            dot.backgroundColor = color.cgColor
            guard pulsing != isPulsing || (pulsing && abs(period - self.period) > 0.01) else { return }
            isPulsing = pulsing
            self.period = period
            dot.removeAllAnimations()
            guard pulsing else { return }
            // opacity 0.35 → 1 and scale 0.8 → 1, ease-in-out loop.
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 0.35
            opacity.toValue = 1
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.8
            scale.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [opacity, scale]
            group.duration = period / 2
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.isRemovedOnCompletion = false
            dot.add(group, forKey: "pulse")
        }
    }
}

/// An indeterminate arc that spins via Core Animation (render server, ~0 app CPU).
struct SpinnerRing: NSViewRepresentable {
    var color: NSColor
    var lineWidth: CGFloat = 2
    var spinning: Bool

    func makeNSView(context: Context) -> RingView { RingView() }

    func updateNSView(_ view: RingView, context: Context) {
        view.update(color: color, lineWidth: lineWidth, spinning: spinning)
    }

    final class RingView: NSView {
        private let ring = CAShapeLayer()
        private var isSpinning = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            ring.fillColor = nil
            ring.lineCap = .round
            ring.strokeStart = 0
            ring.strokeEnd = 0.28
            layer?.addSublayer(ring)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.frame = bounds
            let inset = ring.lineWidth / 2
            ring.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
            CATransaction.commit()
        }

        func update(color: NSColor, lineWidth: CGFloat, spinning: Bool) {
            ring.strokeColor = color.cgColor
            ring.lineWidth = lineWidth
            guard spinning != isSpinning else { return }
            isSpinning = spinning
            ring.removeAllAnimations()
            guard spinning else { ring.strokeEnd = 1; return }
            ring.strokeEnd = 0.28
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi // clockwise on screen (flipped layer space)
            spin.duration = 1.1
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            ring.add(spin, forKey: "spin")
        }
    }
}

/// The real icon of the terminal / IDE behind a session or command.
struct AppIconView: View {
    let icon: NSImage?
    var size: CGFloat = 18

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}

/// Behind-window blur in the island's exact outline. The mask is redrawn from `NotchShape`
/// on every layout, so it follows the morph (a SwiftUI clip would break behind-window blending).
struct IslandBlur: NSViewRepresentable {
    var bottomRadius: CGFloat
    var topRadius: CGFloat

    func makeNSView(context: Context) -> BlurView {
        let v = BlurView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }

    func updateNSView(_ view: BlurView, context: Context) {
        view.setRadii(bottom: bottomRadius, top: topRadius)
    }

    final class BlurView: NSVisualEffectView {
        private var bottom: CGFloat = 0
        private var top: CGFloat = 0

        func setRadii(bottom: CGFloat, top: CGFloat) {
            guard bottom != self.bottom || top != self.top else { return }
            self.bottom = bottom
            self.top = top
            updateMask()
        }

        override func layout() {
            super.layout()
            updateMask()
        }

        private func updateMask() {
            let size = bounds.size
            guard size.width > 1, size.height > 1 else { return }
            let b = bottom, t = top
            maskImage = NSImage(size: size, flipped: true) { rect in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.addPath(NotchShape(bottomRadius: b, topRadius: t).path(in: rect).cgPath)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillPath()
                return true
            }
        }
    }
}
