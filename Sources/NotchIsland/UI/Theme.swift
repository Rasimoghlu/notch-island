import SwiftUI

enum Theme {
    static let shape = Color.black
    static let card = Color(hex: 0x121214)
    static let border = Color(hex: 0x27272a)
    static let control = Color(hex: 0x27272a)
    static let text = Color(hex: 0xe4e4e7)
    static let secondary = Color(hex: 0xa1a1aa)
    static let muted = Color(hex: 0x71717a)

    static let amber = Color(hex: 0xf59e0b)
    static let amberLight = Color(hex: 0xfbbf24)
    static let orange = Color(hex: 0xfb923c)
    static let blue = Color(hex: 0x60a5fa)
    static let green = Color(hex: 0x4ade80)
    static let red = Color(hex: 0xf87171)
    static let weekly = Color(hex: 0xd4d4d8)

    static let killBg = Color(hex: 0x3b1416)
    static let forecastText = Color(hex: 0xfcd34d)
    static let codeBg = Color(hex: 0x1c1c1f)
    /// How solid the open island's frosted body is (1 = opaque black, 0 = blur only).
    /// The notch row is always solid so it merges with the hardware notch.
    static let islandOpacity: Double = 0.32
    /// Points below the notch row over which the black fades into the frosted body.
    static let islandFade: CGFloat = 28
    /// Dividers inside the island.
    static let hairline = Color.white.opacity(0.07)
    static let greenIconBg = Color(hex: 0x14532d)
    static let redIconBg = Color(hex: 0x4c1515)
    static let amberIconBg = Color(hex: 0x3d2a06)
    static let idleDot = Color(hex: 0x52525b)

}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}

extension Font {
    /// SF Pro
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// SF Mono — ports, commands, branch names.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Small uppercase card title with letter spacing.
struct CardTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.ui(11, .semibold))
            .tracking(0.9)
            .foregroundStyle(Theme.muted)
    }
}

extension Font {
    /// SF Pro Rounded, for the big numbers.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// A column of the expanded island. No box: content sits on the black shape and columns are
/// separated by `ColumnDivider`s.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Hairline between columns.
struct ColumnDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1).padding(.vertical, 8)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Wide text button (alerts, settings).
struct PillButton: View {
    let title: String
    var shortcut: String? = nil
    var prominent = false
    var height: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.ui(13, .semibold))
                if let shortcut {
                    Text(shortcut).font(.ui(11)).opacity(0.55)
                }
            }
                .foregroundStyle(prominent ? Color.black : Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(prominent ? Theme.amber : Theme.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

/// Amber switch that looks the same whether or not the panel is key
/// (the system switch turns grey in inactive windows).
struct IslandToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() }
        } label: {
            HStack(spacing: 10) {
                Text(label).font(.ui(12.5)).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                Capsule()
                    .fill(isOn ? Theme.amber : Theme.control)
                    .frame(width: 30, height: 18)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle().fill(Color.white).frame(width: 14, height: 14).padding(2)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
