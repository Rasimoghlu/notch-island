import SwiftUI
import NotchIslandCore

struct ExpandedView: View {
    let ns: Namespace.ID
    @EnvironmentObject private var model: AppModel
    @Environment(\.loopsEnabled) private var loops
    /// Content enters only after the black shape has (mostly) opened.
    @State private var headerShown = false
    /// Cards are created only once the shape has mostly opened, so the morph itself never
    /// pays for laying out three cards every frame.
    @State private var mounted = false
    @State private var appeared = false

    var body: some View {
        let notch = model.geometry.notch
        let tab = model.island.tab
        VStack(spacing: 0) {
            HeaderRow(ns: ns)
                .frame(height: notch.height)
                .opacity(headerShown ? 1 : 0)
                .offset(y: headerShown ? 0 : -4)
            Group {
                if mounted {
                    switch tab {
                    case .overview: OverviewTab(appeared: appeared)
                    case .radar: RadarTab(appeared: appeared)
                    case .settings: SettingsTab(appeared: appeared)
                    }
                }
            }
            .id(tab)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)).animation(.easeOut(duration: 0.18).delay(0.04)),
                                    removal: .opacity.animation(Motion.contentOut)))
            .padding(.top, 10)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
        .frame(width: IslandLayout.expandedWidth,
               height: IslandLayout.expandedHeight(tab, notch: notch.height, extra: model.overviewExtra), alignment: .top)
        .task {
            guard loops, !model.reduceMotion else { headerShown = true; mounted = true; appeared = true; return }
            try? await Task.sleep(nanoseconds: Motion.contentDelay)
            withAnimation(Motion.headerFade) { headerShown = true }
            mounted = true
            try? await Task.sleep(nanoseconds: 16_000_000)
            appeared = true
        }
    }
}

/// Status on the left of the hardware notch, tabs on the right.
struct HeaderRow: View {
    let ns: Namespace.ID
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let notchW = model.geometry.notch.width
        let side = (IslandLayout.expandedWidth - 44 - notchW) / 2 - 8
        HStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let s = model.headerStatus(now: ctx.date)
                HStack(spacing: 8) {
                    StatusDot(color: s.color, pulsing: s.pulsing)
                        .matchedGeometryEffect(id: "status-dot", in: ns)
                    (Text(s.title).font(.ui(13, .semibold)).foregroundColor(Theme.text)
                     + Text(s.detail.isEmpty ? "" : " · \(s.detail)").font(.ui(13)).foregroundColor(Theme.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: side, alignment: .leading)
            Spacer(minLength: notchW + 16)
            TabBar()
                .frame(width: side, alignment: .trailing)
        }
    }
}

struct TabBar: View {
    @EnvironmentObject private var model: AppModel
    @Namespace private var tabNS

    var body: some View {
        HStack(spacing: 2) {
            ForEach(IslandTab.allCases, id: \.self) { tab in
                let selected = model.island.tab == tab
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { model.send(.selectTab(tab)) }
                } label: {
                    Text(tab.title)
                        .font(.ui(12.5, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.text : Theme.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            // One capsule that slides between tabs.
                            if selected {
                                Capsule().fill(Theme.control)
                                    .matchedGeometryEffect(id: "tab-capsule", in: tabNS)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Cards arrive left → right, 50 ms apart: fade, 8 pt rise, slight scale and a blur that clears.
struct Stagger: ViewModifier {
    let index: Int
    let appeared: Bool
    @Environment(\.loopsEnabled) private var loops

    func body(content: Content) -> some View {
        let hidden = !appeared && loops
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: hidden ? 6 : 0)
            .scaleEffect(hidden ? 0.98 : 1, anchor: .top)
            .blur(radius: hidden ? 4 : 0)
            .animation(Motion.card.delay(Double(index) * Motion.cardStagger), value: appeared)
    }
}

struct OverviewTab: View {
    let appeared: Bool

    var body: some View {
        // 776 pt of content: ports get the most room (two-part detail line), commands the least.
        HStack(alignment: .top, spacing: 0) {
            UsageCard().frame(width: 252).modifier(Stagger(index: 0, appeared: appeared))
            ColumnDivider()
            NowCard().frame(width: 300).modifier(Stagger(index: 1, appeared: appeared))
            ColumnDivider()
            CommandsCard().modifier(Stagger(index: 2, appeared: appeared))
        }
    }
}
