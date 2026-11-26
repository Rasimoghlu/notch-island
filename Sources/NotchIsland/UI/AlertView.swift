import SwiftUI
import NotchIslandCore

/// Content below the hardware notch for alert states.
struct AlertView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let state = model.island
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: model.geometry.notch.height)
            if let n = state.needsYou {
                NeedsYouContent(alert: n)
            } else {
                // One block, centred under the notch; icons stay in a column inside it.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(state.visibleAlerts) { a in
                        ResultRow(alert: a)
                            .frame(height: 52)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 22)
        .frame(width: IslandLayout.spec(state, model.geometry).size.width, alignment: .topLeading)
    }
}

struct NeedsYouContent: View {
    let alert: IslandAlert
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let icon = model.appIcon(forPid: alert.pid ?? model.sessionPidFor(alert.sessionId)) {
                    // The terminal / IDE this request comes from, with a pulsing amber badge.
                    AppIconView(icon: icon, size: 20)
                        .overlay(alignment: .bottomTrailing) {
                            StatusDot(color: Theme.amber, pulsing: true, size: 7)
                                .padding(1.5)
                                .background(Circle().fill(Theme.shape))
                                .offset(x: 3, y: 3)
                        }
                } else {
                    StatusDot(color: Theme.amber, pulsing: true)
                }
                (Text(alert.title).font(.ui(14, .semibold))
                 + Text(alert.subtitle.isEmpty ? "" : "  ·  \(alert.subtitle)").font(.ui(14)).foregroundColor(Theme.secondary))
                    .lineLimit(1)
            }
            .padding(.top, 6)
            if let detail = alert.detail, !detail.isEmpty {
                Text(detail)
                    .font(.mono(12.5))
                    .foregroundStyle(Theme.forecastText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(spacing: 10) {
                let keys = model.settings.shortcutsEnabled && alert.requestId != nil
                if alert.requestId != nil {
                    PillButton(title: "Allow", shortcut: keys ? "⌃⌥Y" : nil, prominent: true) { model.answer(alert, allow: true) }
                    PillButton(title: "Deny", shortcut: keys ? "⌃⌥N" : nil) { model.answer(alert, allow: false) }
                } else {
                    PillButton(title: "Dismiss") { model.send(.dismissAlert(alert.id)) }
                }
                PillButton(title: "Open terminal", shortcut: keys ? "⌃⌥T" : nil) { model.openTerminal(for: alert) }
            }
        }
    }
}

struct ResultRow: View {
    let alert: IslandAlert
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            model.openTerminal(for: alert)
            model.send(.dismissAlert(alert.id))
        } label: {
            HStack(spacing: 12) {
                ResultIcon(kind: alert.kind)
                    .overlay(alignment: .bottomTrailing) {
                        // Small badge: which terminal / IDE this result belongs to.
                        if let icon = model.appIcon(forPid: alert.pid ?? model.sessionPidFor(alert.sessionId)) {
                            AppIconView(icon: icon, size: 13)
                                .offset(x: 4, y: 4)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title).font(.ui(14, .semibold)).lineLimit(1)
                    Text(alert.subtitle).font(.ui(12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                .frame(maxWidth: 320, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// done: the check draws itself · failed: the x shakes · warning: the ! pops.
struct ResultIcon: View {
    let kind: AlertKind
    @Environment(\.loopsEnabled) private var loops
    @State private var shown = false

    var body: some View {
        ZStack {
            Circle().fill(background)
            switch kind {
            case .done:
                CheckShape()
                    .trim(from: 0, to: shown || !loops ? 1 : 0)
                    .stroke(Theme.green, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .animation(.easeOut(duration: 0.35).delay(0.22), value: shown)
            case .warning:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.amber)
                    .keyframeAnimator(initialValue: 1.0, trigger: shown) { view, scale in
                        view.scaleEffect(scale)
                    } keyframes: { _ in
                        KeyframeTrack {
                            CubicKeyframe(1.0, duration: 0.2)
                            SpringKeyframe(1.45, duration: 0.14)
                            SpringKeyframe(1.0, duration: 0.35, spring: .bouncy)
                        }
                    }
            default:
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.red)
                    .keyframeAnimator(initialValue: 0.0, trigger: shown) { view, x in
                        view.offset(x: x)
                    } keyframes: { _ in
                        KeyframeTrack {
                            CubicKeyframe(0, duration: 0.2)
                            LinearKeyframe(-3.5, duration: 0.05)
                            LinearKeyframe(3.5, duration: 0.08)
                            LinearKeyframe(-2.5, duration: 0.08)
                            LinearKeyframe(1.5, duration: 0.07)
                            LinearKeyframe(0, duration: 0.06)
                        }
                    }
            }
        }
        .frame(width: 28, height: 28)
        .onAppear { if loops { shown = true } }
    }

    private var background: Color {
        switch kind {
        case .done: return Theme.greenIconBg
        case .warning: return Theme.amberIconBg
        default: return Theme.redIconBg
        }
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.32, y: rect.minY + rect.height * 0.52))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.45, y: rect.minY + rect.height * 0.65))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.69, y: rect.minY + rect.height * 0.37))
        return p
    }
}
