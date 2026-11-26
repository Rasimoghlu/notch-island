import SwiftUI
import NotchIslandCore

/// Agent sessions as dots around "You". The dashed rings turn slowly in opposite directions
/// (18 s and 30 s per turn); the dots stay put so they remain readable.
struct RadarTab: View {
    let appeared: Bool
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let agents = model.agents
        HStack(alignment: .top, spacing: 30) {
            Orbit(agents: Array(agents.prefix(8)))
                .frame(width: 340, height: 340)
                .modifier(Stagger(index: 0, appeared: appeared))
            VStack(alignment: .leading, spacing: 12) {
                if agents.isEmpty {
                    Text("No Claude Code sessions are running")
                        .font(.ui(13))
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 8)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 12) {
                            ForEach(Array(agents.enumerated()), id: \.element.id) { i, agent in
                                AgentRow(agent: agent)
                                    .modifier(Stagger(index: i + 1, appeared: appeared))
                            }
                        }
                    }
                    .frame(maxHeight: 290)
                }
                Text("Amber — needs you · orange — thinking · green — done · grey — idle · ring — context used")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

extension AgentInfo.State {
    var color: Color {
        switch self {
        case .needsYou: return Theme.amber
        case .thinking: return Theme.orange
        case .done: return Theme.green
        case .idle: return Theme.idleDot
        }
    }

    func label(since: Date, now: Date) -> String {
        let d = now.timeIntervalSince(since)
        switch self {
        case .needsYou: return "Waiting for approval · \(Fmt.minutes(d))"
        case .thinking: return "Thinking · \(Fmt.minutes(d))"
        case .done: return "Done · \(Fmt.ago(d))"
        case .idle: return "Idle · \(Fmt.minutes(d))"
        }
    }
}

struct AgentRow: View {
    let agent: AgentInfo
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let icon = model.appIcon(forPid: agent.pid) {
                    AppIconView(icon: icon, size: 24)
                        .overlay(alignment: .bottomTrailing) {
                            StatusDot(color: agent.state.color, pulsing: agent.state == .thinking || agent.state == .needsYou, size: 8)
                                .padding(1.5)
                                .background(Circle().fill(Theme.card))
                                .offset(x: 3, y: 3)
                        }
                } else {
                    StatusDot(color: agent.state.color, pulsing: agent.state == .thinking || agent.state == .needsYou, size: 10)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                (Text(agent.name).font(.ui(14, .semibold)) + Text("  ·  \(agent.tool)").font(.ui(14)).foregroundColor(Theme.secondary))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(agent.state.label(since: agent.since, now: ctx.date)).foregroundColor(Theme.secondary)
                        .font(.ui(12))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let ctx = model.contextBySession[agent.id] {
                ContextRing(percent: ctx)
                    .help(ctx >= 80 ? "Context window \(Int(ctx))% full: consider /compact" : "Context window \(Int(ctx))% full")
            }
            Button("Focus") { model.focus(agent) }
                .buttonStyle(.plain)
                .font(.ui(12.5, .semibold))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Small ring that fills with the session's context-window use.
struct ContextRing: View {
    let percent: Double

    var body: some View {
        let f = min(max(percent / 100, 0), 1)
        ZStack {
            Circle().stroke(Theme.border, lineWidth: 3)
            Circle().trim(from: 0, to: f)
                .stroke(f >= 0.8 ? Theme.amber : Theme.secondary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: f)
            Text("\(Int((f * 100).rounded()))")
                .font(.ui(8.5, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.secondary)
        }
        .frame(width: 26, height: 26)
    }
}

struct Orbit: View {
    let agents: [AgentInfo]
    @Environment(\.loopsEnabled) private var loops

    private let outer: CGFloat = 165
    private let inner: CGFloat = 110

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: !loops)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                ZStack {
                    ring(outer).rotationEffect(.degrees(loops ? t / 30 * 360 : 0))
                    ring(inner).rotationEffect(.degrees(loops ? -t / 18 * 360 : 0))
                }
            }
            Circle()
                .fill(Theme.card)
                .overlay(Circle().strokeBorder(Color(hex: 0x3f3f46), lineWidth: 1))
                .frame(width: 60, height: 60)
                .overlay(Text("You").font(.ui(13, .semibold)))
            ForEach(Array(agents.enumerated()), id: \.element.id) { i, agent in
                let p = position(i)
                AgentDot(agent: agent)
                    .offset(x: p.x, y: p.y)
            }
        }
    }

    private func ring(_ r: CGFloat) -> some View {
        Circle()
            .stroke(Color(hex: 0x3f3f46), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            .frame(width: r * 2, height: r * 2)
    }

    /// Alternate rings, spread evenly, starting top-right like a clock face.
    private func position(_ i: Int) -> CGPoint {
        let n = max(agents.count, 1)
        let angle = -Double.pi / 3 + Double(i) * 2 * .pi / Double(n) + (i % 2 == 0 ? 0 : 0.35)
        let r = i % 2 == 0 ? outer : inner
        return CGPoint(x: cos(angle) * r, y: sin(angle) * r)
    }
}

struct AgentDot: View {
    let agent: AgentInfo
    @Environment(\.loopsEnabled) private var loops
    @State private var glow = false

    var body: some View {
        let size: CGFloat = switch agent.state {
        case .needsYou: 34
        case .thinking: 26
        case .done: 22
        case .idle: 18
        }
        VStack(spacing: 6) {
            Group {
                switch agent.state {
                case .needsYou:
                    Circle().fill(Theme.amber.opacity(0.55))
                        .shadow(color: Theme.amber.opacity(glow ? 0.8 : 0.2), radius: glow ? 14 : 4)
                        .onAppear {
                            guard loops else { return }
                            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { glow = true }
                        }
                case .thinking:
                    Circle().fill(Theme.orange.opacity(0.6)).pulsing(minOpacity: 0.4, minScale: 0.9)
                default:
                    Circle().fill(agent.state.color)
                }
            }
            .frame(width: size, height: size)
            Text(agent.name)
                .font(.ui(11.5))
                .foregroundStyle(agent.state == .needsYou ? Theme.amberLight : Theme.text)
                .lineLimit(1)
                .fixedSize()
        }
        // Keep the dot (not the label) centred on the orbit point.
        .offset(y: 10)
    }
}
