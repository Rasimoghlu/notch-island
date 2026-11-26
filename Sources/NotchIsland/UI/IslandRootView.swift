import SwiftUI
import NotchIslandCore

/// The island: a body with rounded bottom corners whose top corners flare outward with a
/// concave curve ("ears"), the way the hardware notch meets the screen edge. The rect passed
/// in includes the ears (body width + 2 × topRadius). Both radii animate, so every state change
/// is one continuous morph of the same outline.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set { bottomRadius = newValue.first; topRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let left = rect.minX + t
        let right = rect.maxX - t
        let b = max(0, min(bottomRadius, (rect.height - t), (right - left) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: left, y: rect.minY + t), control: CGPoint(x: left, y: rect.minY))
        p.addLine(to: CGPoint(x: left, y: rect.maxY - b))
        p.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: left + b, y: rect.maxY), radius: b)
        p.addLine(to: CGPoint(x: right - b, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.maxY - b), radius: b)
        p.addLine(to: CGPoint(x: right, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// The island outline without its top edge: down the left side, along the bottom,
/// up the right side. Trimmed from 0 to the usage fraction, it fills like a fuse.
struct EdgePath: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat
    var inset: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set { bottomRadius = newValue.first; topRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + topRadius + inset
        let right = rect.maxX - topRadius - inset
        let top = rect.minY + topRadius
        let bottom = rect.maxY - inset
        let r = max(0, min(bottomRadius - inset, (bottom - top) / 2, (right - left) / 2))
        var p = Path()
        p.move(to: CGPoint(x: left, y: top))
        p.addLine(to: CGPoint(x: left, y: bottom - r))
        p.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left + r, y: bottom), radius: r)
        p.addLine(to: CGPoint(x: right - r, y: bottom))
        p.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right, y: bottom - r), radius: r)
        p.addLine(to: CGPoint(x: right, y: top))
        return p
    }
}

/// 5-hour usage drawn along the edge of the working notch, like a burning fuse.
/// The white "ghost" dot marks where even pacing would be by now: if the fuse runs ahead of
/// it you are spending faster than the window allows, and it turns red.
struct EdgeProgress: View {
    var fraction: Double
    var bottomRadius: CGFloat
    var topRadius: CGFloat
    /// Elapsed share of the 5-hour window (0…1), or nil when unknown.
    var ghost: Double?
    private let lineWidth: CGFloat = 2.5

    var body: some View {
        let f = min(max(fraction, 0), 1)
        let ahead = ghost.map { f - $0 } ?? 0
        let color = (f >= 0.9 || ahead > 0.15) ? Theme.red : Theme.amber
        let edge = EdgePath(bottomRadius: bottomRadius, topRadius: topRadius, inset: lineWidth / 2 + 1)
        ZStack {
            edge.stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            edge.trim(from: 0, to: f)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .shadow(color: color.opacity(0.45), radius: 3)
                .animation(.easeInOut(duration: 1.2), value: f)
            if let g = ghost {
                edge.trim(from: max(0, g - 0.001), to: min(1, g + 0.001))
                    .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

struct IslandRootView: View {
    @EnvironmentObject private var model: AppModel
    @Namespace private var ns

    // The drawn shape. Width, height and radius animate separately so the island
    // stretches sideways first and then drops down (and reverses on close).
    @State private var w: CGFloat = 0
    @State private var h: CGFloat = 0
    @State private var r: CGFloat = 10
    @State private var ear: CGFloat = 6
    /// The edge fuse is shown only once the shape has settled in the compact state, so it
    /// (and its pace dot) never rides along a contour that is still morphing.
    @State private var edgeReady = false
    @State private var edgeToken = 0
    /// Bumped on click to play the "squish".
    @State private var squish = 0
    /// Bumped when a success alert arrives, to sweep a shine across the island once.
    @State private var shine = 0

    var body: some View {
        let state = model.island
        let shape = NotchShape(bottomRadius: r, topRadius: ear)
        let fullW = w + 2 * ear

        let collapsed = state.phase == .idle || state.phase == .compact
        let elevated = state.phase == .expanded || state.phase == .alert
        ZStack(alignment: .top) {
            // Open: a frosted, slightly see-through island. The notch row stays solid black so it
            // still merges with the hardware notch; below it the black thins out over a
            // behind-window blur. Collapsed: solid black, exactly like the notch.
            if elevated {
                IslandBlur(bottomRadius: r, topRadius: ear)
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }
            shape
                .fill(LinearGradient(stops: frostStops(notch: model.geometry.notch.height, height: h),
                                     startPoint: .top, endPoint: .bottom))
                // Floats above the windows below it when open, like a real overlay.
                .shadow(color: .black.opacity(elevated ? 0.35 : 0), radius: elevated ? 24 : 0, x: 0, y: elevated ? 12 : 0)
            shape
                .fill(Theme.shape)
                .opacity(elevated ? 0 : 1)
                .animation(.easeOut(duration: 0.18), value: elevated)
                .modifier(NeedsYouGlow(active: state.phase == .alert && state.needsYou != nil))
                .contentShape(shape)
                .onTapGesture {
                    // Click: open now, with a little squish.
                    guard collapsed else { return }
                    squish += 1
                    model.hoverIntent = false
                    model.send(.hoverBegan)
                }

            content(state.phase)
                .frame(width: fullW, height: h, alignment: .top)
                .clipShape(shape)

            // Glass rim: a hairline of light along the sides and bottom, brightest at the bottom.
            EdgePath(bottomRadius: r, topRadius: ear, inset: 0.5)
                .stroke(LinearGradient(colors: [.white.opacity(0.0), .white.opacity(0.07), .white.opacity(0.2)],
                                       startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                .opacity(elevated ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: elevated)
                .allowsHitTesting(false)

            // One soft diagonal shine across the island when something succeeds.
            ShineSweep(trigger: shine, width: fullW)
                .frame(width: fullW, height: h)
                .clipShape(shape)
                .allowsHitTesting(false)

            if state.phase == .compact, edgeReady, let five = model.claudeUsage?.fiveHour?.current() {
                // Re-evaluated once a minute so the pace ghost creeps along.
                TimelineView(.periodic(from: .now, by: 60)) { ctx in
                    EdgeProgress(fraction: five.usedPercent / 100, bottomRadius: r, topRadius: ear,
                                 ghost: Pace.elapsed(resetsAt: five.resetsAt, window: 5 * 3600, now: ctx.date))
                }
                .frame(width: fullW, height: h)
                .transition(.opacity.animation(.easeOut(duration: 0.18)))
            }
        }
        .frame(width: fullW, height: h)
        .keyframeAnimator(initialValue: CGFloat(1), trigger: squish) { view, scale in
            view.scaleEffect(scale, anchor: .top)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(0.93, duration: 0.07)
                SpringKeyframe(1, duration: 0.32, spring: .bouncy)
            }
        }
        .overlay(alignment: .top) {
            // The split-off bubble lives beside the island, never inside its clip.
            if let cmd = model.bubbleCommand, collapsed {
                SplitBubble(command: cmd)
                    .offset(x: IslandLayout.bubbleOffset(IslandLayout.Spec(size: CGSize(width: w, height: h), bottomRadius: r, topRadius: ear), model.geometry))
                    .transition(.modifier(active: BubbleEmerge(t: 0), identity: BubbleEmerge(t: 1)))
            }
        }
        .overlay(alignment: .top) {
            if Snapshot.showNotchHole {
                Rectangle().fill(Color.red.opacity(0.45))
                    .frame(width: model.geometry.notch.width, height: model.geometry.notch.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.loopsEnabled, model.loopsEnabled)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Theme.text)
        .onAppear {
            let t = target
            w = t.size.width; h = t.size.height; r = t.bottomRadius; ear = t.topRadius
            edgeReady = true
        }
        .onChange(of: state.alerts.last?.id) { _, _ in
            // A new success (and nothing waiting on you): play the shine after the bounce.
            if let last = state.alerts.last, last.kind == .done, state.needsYou == nil, model.loopsEnabled {
                shine += 1
            }
        }
        .onChange(of: state.phase) { _, _ in
            // Hide the fuse at once, bring it back after the morph has settled.
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { edgeReady = false }
            edgeToken += 1
            let token = edgeToken
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.edgeSettle) {
                guard token == edgeToken else { return }
                withAnimation(.easeOut(duration: 0.18)) { edgeReady = true }
            }
        }
        .onChange(of: target) { old, new in morph(from: old, to: new) }
    }

    /// Solid black through the notch row, then a quick fade into an even, frosted body.
    private func frostStops(notch: CGFloat, height: CGFloat) -> [Gradient.Stop] {
        let h = max(height, 1)
        let solidEnd = min(0.9, notch / h)
        let fadeEnd = min(0.97, (notch + Theme.islandFade) / h)
        return [
            .init(color: .black, location: 0),
            .init(color: .black, location: solidEnd),
            .init(color: .black.opacity(Theme.islandOpacity), location: max(fadeEnd, solidEnd + 0.01)),
            .init(color: .black.opacity(Theme.islandOpacity), location: 1),
        ]
    }

    /// Final shape for the current state, plus a small swell while the pointer rests on
    /// the collapsed notch (it is about to open).
    private var target: IslandLayout.Spec {
        var spec = IslandLayout.spec(model.island, model.geometry, extra: model.overviewExtra)
        let collapsed = model.island.phase == .idle || model.island.phase == .compact
        if model.hoverIntent && collapsed {
            spec.size.width += 16
            spec.size.height += 4
            spec.bottomRadius += 2
        }
        return spec
    }

    private func morph(from old: IslandLayout.Spec, to new: IslandLayout.Spec) {
        func apply() {
            w = new.size.width; h = new.size.height; r = new.bottomRadius; ear = new.topRadius
        }
        if model.reduceMotion {
            withAnimation(.easeInOut(duration: 0.2)) { apply() }
            return
        }
        let growing = new.size.height > old.size.height + 0.5 || new.size.width > old.size.width + 0.5
        if growing {
            // Open: quick springs on every edge at once; the width settles a touch sooner than
            // the height, which reads as spreading from the notch edges. Alerts keep a small bounce.
            let bouncy = model.island.phase == .alert
            withAnimation(Motion.openWidth) { w = new.size.width; ear = new.topRadius }
            withAnimation(bouncy ? Motion.openHeightAlert : Motion.openHeight) {
                h = new.size.height
                r = new.bottomRadius
            }
        } else {
            // Close: the content blinks out, then every edge converges onto the notch outline at
            // once. Critically damped, so it never undershoots and slips behind the cut-out.
            withAnimation(Motion.close) { apply() }
        }
    }

    @ViewBuilder
    private func content(_ phase: IslandPhase) -> some View {
        switch phase {
        case .idle:
            Color.clear
        case .compact:
            CompactView(ns: ns)
                .transition(.asymmetric(insertion: .opacity.animation(Motion.compactIn),
                                        removal: .opacity.animation(Motion.contentOut)))
        case .expanded:
            // ExpandedView sequences its own entrance once the shape has opened.
            ExpandedView(ns: ns)
                .transition(.asymmetric(insertion: .identity,
                                        removal: .opacity.animation(Motion.contentOut)))
        case .alert:
            AlertView()
                .transition(.asymmetric(insertion: .opacity.animation(Motion.alertIn),
                                        removal: .opacity.animation(Motion.contentOut)))
        }
    }
}

/// Working: pulsing amber dot in the left wing, tiny usage bar and percent in the right wing.
/// The middle is left empty: that is where the camera cut-out is.
struct CompactView: View {
    let ns: Namespace.ID
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let pct = model.claudeUsage?.fiveHour?.current().usedPercent
        let wing = IslandLayout.compactWing
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                StatusDot(color: Theme.amber, pulsing: true, period: model.pulsePeriod)
                    .matchedGeometryEffect(id: "status-dot", in: ns)
                SessionStack()
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .frame(width: wing)

            Color.clear.frame(width: model.geometry.notch.width)

            HStack(spacing: 5) {
                Spacer(minLength: 0)
                if let pct {
                    Text("\(Int(pct.rounded()))%")
                        .font(.ui(12, .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .contentTransition(.numericText(value: pct))
                        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: Int(pct.rounded()))
                } else {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.amber)
                }
            }
            .padding(.trailing, 14)
            .frame(width: wing)
        }
        .frame(width: IslandLayout.compactWidth(model.geometry), height: model.geometry.notch.height)
    }
}

/// A second, smaller island that splits off to the right while a shell command runs:
/// the terminal's icon inside a spinning amber ring. It merges back when the command ends.
struct SplitBubble: View {
    let command: RunningCommand
    @EnvironmentObject private var model: AppModel
    @Environment(\.loopsEnabled) private var loops

    var body: some View {
        let size = IslandLayout.bubbleSize(model.geometry)
        let ear = IslandLayout.bubbleEar
        ZStack {
            NotchShape(bottomRadius: size / 2, topRadius: ear)
                .fill(Theme.shape)
            ZStack {
                SpinnerRing(color: NSColor(Theme.amber), lineWidth: 2, spinning: loops)
                    .frame(width: size - 12, height: size - 12)
                if let icon = model.appIcon(forPid: Int32(command.pid)) {
                    AppIconView(icon: icon, size: size - 22)
                } else {
                    Image(systemName: "terminal").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
            }
            .offset(y: -1)
        }
        .frame(width: size + 2 * ear, height: size)
        .help("\(command.command) — running")
        .allowsHitTesting(false)
    }
}

/// Bubble enters from inside the island's right edge, small and transparent, and springs out.
struct BubbleEmerge: ViewModifier {
    var t: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(0.35 + 0.65 * t, anchor: .leading)
            .offset(x: -28 * (1 - t))
            .opacity(Double(min(1, t * 1.6)))
    }
}

/// A bright diagonal band that crosses the island once per `trigger` change.
struct ShineSweep: View {
    let trigger: Int
    let width: CGFloat

    var body: some View {
        LinearGradient(colors: [.clear, .white.opacity(0.16), .white.opacity(0.24), .white.opacity(0.16), .clear],
                       startPoint: .leading, endPoint: .trailing)
            .frame(width: 110)
            .rotationEffect(.degrees(18))
            .blendMode(.plusLighter)
            .keyframeAnimator(initialValue: CGFloat(-1), trigger: trigger) { view, p in
                view.offset(x: p * (width / 2 + 120)).opacity(abs(p) < 1 ? 1 : 0)
            } keyframes: { _ in
                KeyframeTrack {
                    MoveKeyframe(-1)
                    LinearKeyframe(-1, duration: 0.3)       // let the bounce land first
                    CubicKeyframe(1, duration: 0.85)        // sweep left → right
                }
            }
    }
}

/// When more than one Claude session is working: their app icons, overlapped, plus a count.
struct SessionStack: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let busy = model.sessions.filter(\.isBusy)
        if busy.count > 1 {
            // One icon per distinct app (two WebStorm sessions show one WebStorm icon).
            var seen = Set<ObjectIdentifier>()
            let icons = busy.compactMap { model.appIcon(forPid: $0.pid) }
                .filter { seen.insert(ObjectIdentifier($0)).inserted }
                .prefix(2)
            HStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    ForEach(Array(icons.enumerated()), id: \.offset) { i, icon in
                        AppIconView(icon: icon, size: 15)
                            .background(Circle().fill(Theme.shape).padding(-1))
                            .offset(x: CGFloat(i) * 9)
                    }
                }
                .frame(width: icons.isEmpty ? 0 : 15 + CGFloat(icons.count - 1) * 9, alignment: .leading)
                Text("\(busy.count)")
                    .font(.ui(12, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.amberLight)
                    .contentTransition(.numericText())
            }
            .help(busy.map(\.project).joined(separator: ", "))
            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
        }
    }
}
