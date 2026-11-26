import SwiftUI
import NotchIslandCore

/// Thick capsule with a liquid fill: a lighter wave slides sideways in a 3 s linear loop.
/// The fill level animates when the value changes. The wave runs only while this view is
/// on screen (the expanded panel) and loops are enabled.
struct LiquidBar: View {
    var fraction: Double
    var color: Color = Theme.amber
    var highlight: Color = Theme.amberLight
    var height: CGFloat = 22
    @Environment(\.loopsEnabled) private var loops

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                ZStack {
                    Rectangle().fill(color)
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: !loops)) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let phase = loops ? (t.truncatingRemainder(dividingBy: 3) / 3) : 0.25
                        Wave(phase: phase, amplitude: height * 0.16, baseline: 0.42)
                            .fill(highlight)
                    }
                }
                .frame(width: w)
                .clipShape(Capsule())
                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: fraction)
            }
        }
        .frame(height: height)
    }
}

/// Fills everything below a sine line; `phase` in 0...1 shifts the wave by one period.
struct Wave: Shape {
    var phase: Double
    var amplitude: CGFloat
    /// Vertical position of the wave's midline as a fraction of height.
    var baseline: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let wavelength = max(rect.height * 3.2, 40)
        let mid = rect.minY + rect.height * baseline
        let shift = CGFloat(phase) * wavelength
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        var x = rect.minX
        while x <= rect.maxX + 2 {
            let y = mid + sin((x + shift) / wavelength * 2 * .pi) * amplitude
            p.addLine(to: CGPoint(x: x, y: y))
            x += 2
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Thin 6 pt bar for weekly / Codex.
struct ThinBar: View {
    var fraction: Double?
    var color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                if let fraction {
                    Capsule().fill(color)
                        .frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
                        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: fraction)
                }
            }
        }
        .frame(height: height)
    }
}

/// Running command: the bar pulses like the working dot until the command ends.
struct RunningBar: View {
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule().fill(Theme.amber.opacity(0.75))
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: geo.size.width * 0.06)
                    .pulsing(minOpacity: 0.35, minScale: 1)
            }
        }
        .frame(height: 6)
    }
}

/// Usage across the current 5-hour window: x = time from window start to reset, y = 0…100 %.
/// The dashed diagonal is even pacing; a curve above it is burning faster than the window allows.
struct UsageSparkline: View {
    let samples: [UsageSample]
    let resetsAt: Date
    let now: Date
    var current: Double?
    var window: TimeInterval = 5 * 3600

    var body: some View {
        Canvas { ctx, size in
            let end = resetsAt.timeIntervalSince1970
            let start = end - window
            func point(_ t: Double, _ pct: Double) -> CGPoint {
                CGPoint(x: CGFloat((t - start) / window) * size.width,
                        y: size.height - CGFloat(min(max(pct, 0), 100) / 100) * size.height)
            }

            // Even pace: 0 % at the start, 100 % at the reset.
            var pace = Path()
            pace.move(to: point(start, 0))
            pace.addLine(to: point(end, 100))
            ctx.stroke(pace, with: .color(.white.opacity(0.14)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

            var pts = samples
                .filter { $0.t >= start && $0.t <= end && ($0.reset.map { abs($0 - end) < 60 } ?? true) }
                .sorted { $0.t < $1.t }
                .map { point($0.t, $0.pct) }
            if let current { pts.append(point(now.timeIntervalSince1970, current)) }
            guard pts.count >= 2, let first = pts.first, let last = pts.last else { return }

            var line = Path()
            line.move(to: first)
            for p in pts.dropFirst() { line.addLine(to: p) }
            var fill = line
            fill.addLine(to: CGPoint(x: last.x, y: size.height))
            fill.addLine(to: CGPoint(x: first.x, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [Theme.amber.opacity(0.28), Theme.amber.opacity(0)]),
                                                 startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(Theme.amber), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)), with: .color(Theme.amberLight))
        }
    }
}
