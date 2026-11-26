import SwiftUI
import NotchIslandCore

/// The middle column: what Claude is doing right now (step, recent steps, subagents),
/// with listening ports as a compact strip underneath when there are any.
struct NowCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirming: String?

    var body: some View {
        Card {
            CardTitle(text: "Now")
                .padding(.bottom, 8)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if model.live.isEmpty {
                        Text("No Claude Code session is running")
                            .font(.ui(12))
                            .foregroundStyle(Theme.muted)
                    }
                    ForEach(Array(model.live.enumerated()), id: \.element.id) { i, session in
                        if i > 0 {
                            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 10)
                        }
                        if i == 0 {
                            LiveSessionDetail(session: session)
                        } else {
                            LiveSessionLine(session: session)
                        }
                    }
                    if !model.ports.isEmpty {
                        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 12)
                        PortStrip(confirming: $confirming)
                    }
                }
            }
        }
    }
}

extension LiveStep.Kind {
    var symbol: String {
        switch self {
        case .edit: return "pencil"
        case .write: return "doc.badge.plus"
        case .read: return "doc.text"
        case .run: return "terminal"
        case .search: return "magnifyingglass"
        case .web: return "globe"
        case .agent: return "person.2"
        case .plan: return "checklist"
        case .ask: return "questionmark.bubble"
        case .message: return "paperplane"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

/// The main session: header, current step, the two before it, subagents and a short tally.
struct LiveSessionDetail: View {
    let session: LiveSession
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let a = session.activity
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                AppIconView(icon: model.appIcon(forPid: session.pid), size: 14)
                Text(session.project).font(.ui(13, .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(elapsed(now: ctx.date))
                        .font(.ui(11.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
            }

            if let current = a.current {
                HStack(spacing: 7) {
                    Image(systemName: current.kind.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(session.busy && current.pending ? Theme.amber : Theme.secondary)
                        .frame(width: 14)
                    Text(current.title)
                        .font(.ui(13))
                        .foregroundStyle(session.busy ? Theme.text : Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if session.busy && current.pending {
                        StatusDot(color: Theme.amber, pulsing: true, size: 6)
                    }
                }
                .padding(.top, 9)

                // The two steps before it, newest first, quieter.
                ForEach(a.steps.dropLast().suffix(2).reversed()) { step in
                    HStack(spacing: 7) {
                        Image(systemName: step.kind.symbol)
                            .font(.system(size: 9.5))
                            .frame(width: 14)
                        Text(step.title).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 5)
                }
            } else {
                Text(session.busy ? "Thinking…" : "Waiting for your next prompt")
                    .font(.ui(12.5))
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 9)
            }

            if !session.agents.isEmpty {
                let running = session.agents.filter(\.running).count
                Text(running > 0 ? "AGENTS · \(running) RUNNING" : "AGENTS")
                    .font(.ui(10, .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 12)
                ForEach(session.agents.prefix(4)) { agent in
                    AgentLine(agent: agent)
                        .padding(.top, 5)
                }
            }

            if a.toolCalls > 0 {
                Text(tally(a))
                    .font(.ui(11))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 10)
            }
        }
    }

    private func elapsed(now: Date) -> String {
        guard let start = session.activity.turnStart else { return "" }
        return session.busy ? Fmt.clock(now.timeIntervalSince(start)) : "done"
    }

    private func tally(_ a: LiveActivity) -> String {
        var parts: [String] = []
        if a.filesChanged > 0 { parts.append(a.filesChanged == 1 ? "1 file changed" : "\(a.filesChanged) files changed") }
        parts.append("\(a.toolCalls) tool call\(a.toolCalls == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }
}

/// A subagent: spinner and its own current step while it runs, a check when done.
struct AgentLine: View {
    let agent: LiveSession.Agent
    @Environment(\.loopsEnabled) private var loops

    var body: some View {
        HStack(spacing: 7) {
            Group {
                if agent.running {
                    SpinnerRing(color: NSColor(Theme.amber), lineWidth: 1.5, spinning: loops)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.green)
                }
            }
            .frame(width: 11, height: 11)
            .frame(width: 14)
            (Text(agent.description).foregroundColor(agent.running ? Theme.text : Theme.secondary)
             + Text(agent.running ? (agent.step.map { " · \($0.title)" } ?? "") : "").foregroundColor(Theme.muted))
                .font(.ui(12))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help([agent.type, agent.description].compactMap { $0 }.joined(separator: " · "))
    }
}

/// Other busy sessions: one line each.
struct LiveSessionLine: View {
    let session: LiveSession
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            AppIconView(icon: model.appIcon(forPid: session.pid), size: 13)
            (Text(session.project).font(.ui(12.5, .semibold))
             + Text(session.activity.current.map { "  \($0.title)" } ?? "  Thinking…").font(.ui(12)).foregroundColor(Theme.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if !session.agents.filter(\.running).isEmpty {
                Image(systemName: "person.2").font(.system(size: 9)).foregroundStyle(Theme.amber)
                    .help("\(session.agents.filter(\.running).count) agents running")
            }
        }
    }
}

// MARK: - Ports strip

/// Listening ports as chips. Click opens HTTP ports; right-click to kill / stop (with a confirm).
struct PortStrip: View {
    @Binding var confirming: String?
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let local = model.ports.filter { $0.container == nil }
        let docker = Dictionary(grouping: model.ports.filter { $0.container != nil }) { $0.composeGroup ?? "docker" }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("PORTS · \(model.ports.count)")
                    .font(.ui(10, .semibold)).tracking(0.8).foregroundStyle(Theme.muted)
                let orphans = model.ports.filter(\.orphan).count
                if orphans > 0 {
                    Text("\(orphans) orphan\(orphans == 1 ? "" : "s")").font(.ui(10, .semibold)).foregroundStyle(Theme.amber)
                }
            }
            if !local.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(local) { PortStripChip(entry: $0, confirming: $confirming) }
                }
            }
            ForEach(docker.keys.sorted(), id: \.self) { group in
                HStack(spacing: 5) {
                    Image(systemName: "shippingbox.fill").font(.system(size: 8.5)).foregroundStyle(Theme.blue.opacity(0.85))
                    Text(group).font(.ui(11)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                .padding(.top, 2)
                FlowLayout(spacing: 5) {
                    ForEach(docker[group]!.sorted { $0.port < $1.port }) { PortStripChip(entry: $0, confirming: $confirming) }
                }
            }
            if let id = confirming, let entry = model.ports.first(where: { $0.id == id }) {
                HStack(spacing: 8) {
                    Text(entry.container == nil ? "Kill \(entry.project) on \(entry.port)?" : "Stop container \(entry.project)?")
                        .font(.ui(11.5)).lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Cancel") { confirming = nil }
                        .buttonStyle(.plain).font(.ui(11.5)).foregroundStyle(Theme.secondary)
                    Button(entry.container == nil ? "Kill" : "Stop") {
                        model.kill(entry)
                        confirming = nil
                    }
                    .buttonStyle(.plain)
                    .font(.ui(11.5, .semibold))
                    .foregroundStyle(Theme.red)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Theme.killBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
    }
}

struct PortStripChip: View {
    let entry: PortEntry
    @Binding var confirming: String?
    @State private var hover = false

    var body: some View {
        Button {
            if let url = entry.url { ProcessControl.open(url) }
        } label: {
            HStack(spacing: 4) {
                Text(String(entry.port)).font(.mono(11.5, .medium)).foregroundStyle(Theme.text)
                Text(entry.project).font(.ui(11)).foregroundStyle(Theme.secondary).lineLimit(1)
                if entry.url != nil {
                    Image(systemName: "arrow.up.right").font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(Theme.secondary).opacity(hover ? 1 : 0.5)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(hover ? Theme.border : Theme.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                if entry.orphan {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.amber.opacity(0.7), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .help(help)
        .contextMenu {
            if let url = entry.url { Button("Open \(url.absoluteString)") { ProcessControl.open(url) } }
            Button(entry.container == nil ? "Kill \(entry.project)…" : "Stop container \(entry.project)…") {
                withAnimation(.easeOut(duration: 0.15)) { confirming = entry.id }
            }
        }
    }

    private var help: String {
        var lines = ["\(entry.detail)"]
        if let owner = entry.ownerName { lines.append("Started by the Claude session in \(owner)") }
        if entry.orphan { lines.append("Orphan: the process that started it has exited") }
        lines.append(entry.url == nil ? "Right-click to kill" : "Click to open · right-click to kill")
        return lines.joined(separator: "\n")
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
