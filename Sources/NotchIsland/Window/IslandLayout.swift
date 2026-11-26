import AppKit
import NotchIslandCore

/// Shape size per state. Shared by SwiftUI (drawing) and the panel controller (hit-testing),
/// so the clickable area always matches what is on screen.
enum IslandLayout {
    static let expandedWidth: CGFloat = 820
    /// Fixed transparent panel; the black shape morphs inside it. Side margins leave room for the glow.
    static let panelSize = CGSize(width: expandedWidth + 120, height: 600)

    struct Spec: Equatable {
        /// Size of the body. The drawn shape is `topRadius` wider on each side (the "ears").
        var size: CGSize
        var bottomRadius: CGFloat
        /// Concave top corners that flare into the screen edge, like the hardware notch.
        var topRadius: CGFloat = 6
    }

    /// `extra`: room the Overview needs for the ports strip (0 when nothing is listening).
    static func expandedHeight(_ tab: IslandTab, notch: CGFloat, extra: CGFloat = 0) -> CGFloat {
        switch tab {
        case .overview: return notch + 306 + extra
        case .settings: return notch + 306
        case .radar: return notch + 374
        }
    }

    /// Each side of the notch in the working state. The notch itself has no pixels
    /// (it is a cut-out), so content must stay inside these wings.
    static let compactWing: CGFloat = 80

    static let compactDrop: CGFloat = 6

    /// Extra Overview height so the ports strip under "Now" is visible without scrolling.
    /// Estimated from the chip count, plus a label per Docker group.
    static func portsExtra(_ ports: [PortEntry]) -> CGFloat {
        guard !ports.isEmpty else { return 0 }
        let local = ports.filter { $0.container == nil }.count
        let groups = Dictionary(grouping: ports.filter { $0.container != nil }) { $0.composeGroup ?? "docker" }
        // Local chips carry a project name (≈2 per row); Docker chips a short service name (≈3).
        var rows = Int((Double(local) / 2).rounded(.up))
        for g in groups.values { rows += Int((Double(g.count) / 3).rounded(.up)) }
        let height = 30 + CGFloat(rows) * 27 + CGFloat(groups.count) * 22
        return min(height, 170)
    }

    // Split-off bubble (a second mini island beside the main one).
    static let bubbleGap: CGFloat = 5
    static let bubbleEar: CGFloat = 5

    /// Same height as the working island, so the pair reads as one split shape.
    static func bubbleSize(_ g: IslandGeometry) -> CGFloat { g.notch.height + compactDrop }

    /// Horizontal offset of the bubble's centre from the island's centre.
    static func bubbleOffset(_ spec: Spec, _ g: IslandGeometry) -> CGFloat {
        let islandHalf = spec.size.width / 2 + spec.topRadius
        let bubbleWidth = bubbleSize(g) + 2 * bubbleEar
        return islandHalf + bubbleGap + bubbleWidth / 2
    }

    static func compactWidth(_ g: IslandGeometry) -> CGFloat { g.notch.width + 2 * compactWing }

    static func spec(_ s: IslandState, _ g: IslandGeometry, extra: CGFloat = 0) -> Spec {
        let n = g.notch
        switch s.phase {
        case .idle:
            return Spec(size: n, bottomRadius: g.hasNotch ? 10 : n.height / 2, topRadius: 6)
        case .compact:
            // A few points taller than the cut-out so the edge progress along the bottom is visible.
            return Spec(size: CGSize(width: compactWidth(g), height: n.height + compactDrop), bottomRadius: 14, topRadius: 6)
        case .expanded:
            return Spec(size: CGSize(width: expandedWidth, height: expandedHeight(s.tab, notch: n.height, extra: extra)), bottomRadius: 32, topRadius: 12)
        case .alert:
            if s.needsYou != nil {
                return Spec(size: CGSize(width: 470, height: n.height + 128), bottomRadius: 28, topRadius: 10)
            }
            let rows = CGFloat(max(1, s.visibleAlerts.count))
            return Spec(size: CGSize(width: 420, height: n.height + 16 + rows * 52), bottomRadius: 26, topRadius: 10)
        }
    }
}

/// Finds the screen with the notch (or the main screen) and the notch rectangle on it.
struct ScreenGeometry {
    var screen: NSScreen
    var island: IslandGeometry
    /// Horizontal centre of the notch in global coordinates.
    var centerX: CGFloat

    static func detect() -> ScreenGeometry? {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        guard let screen = notched ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
        let f = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // Auxiliary areas are the menu-bar strips either side of the notch.
            let width = f.width - left.width - right.width
            let height = screen.safeAreaInsets.top
            let centerX = f.minX + left.width + width / 2
            return ScreenGeometry(screen: screen, island: IslandGeometry(notch: CGSize(width: width, height: height), hasNotch: true),
                                  centerX: centerX)
        }
        // No notch: a small black pill at the top centre, as tall as the menu bar.
        let menuBar = max(24, f.maxY - screen.visibleFrame.maxY)
        return ScreenGeometry(screen: screen, island: IslandGeometry(notch: CGSize(width: 180, height: min(menuBar, 32)), hasNotch: false),
                              centerX: f.midX)
    }
}
