import SwiftUI
import NotchIslandCore

struct SettingsTab: View {
    let appeared: Bool
    @EnvironmentObject private var model: AppModel
    @State private var hooks = HookStatus()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            GeneralCard(settings: model.settings)
                .modifier(Stagger(index: 0, appeared: appeared))
            ColumnDivider()
            AlertsCard(settings: model.settings)
                .modifier(Stagger(index: 1, appeared: appeared))
            ColumnDivider()
            Card {
                CardTitle(text: "Hooks")
                    .padding(.bottom, 12)
                VStack(alignment: .leading, spacing: 9) {
                    status("Claude hooks", hooks.claudeHooks)
                    status("Allow / Deny from the notch", hooks.permissionHook)
                    status("Status line → usage limits", hooks.statusLine)
                    status("Usage data received", hooks.usageData)
                    status("zsh command hook", hooks.zsh)
                }
                Spacer(minLength: 10)
                Text("Set up with hooks/install.sh in the project folder.")
                    .font(.ui(11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PillButton(title: "Folder", height: 30) { NSWorkspace.shared.open(NIPaths.root) }
                    PillButton(title: "Quit", height: 30) { NSApp.terminate(nil) }
                }
                .padding(.top, 10)
            }
            .modifier(Stagger(index: 2, appeared: appeared))
        }
        .onAppear { hooks = HookStatus.detect() }
    }

    private func status(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 12))
                .foregroundStyle(ok ? Theme.green : Theme.muted)
            Text(label).font(.ui(12.5)).foregroundStyle(ok ? Theme.text : Theme.secondary)
        }
    }
}

private struct GeneralCard: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card {
            CardTitle(text: "General")
                .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 12) {
                IslandToggle(label: "Launch at login",
                             isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                if let err = settings.launchAtLoginError {
                    Text(err).font(.ui(11)).foregroundStyle(Theme.red)
                }
                IslandToggle(label: "Working notch while Claude runs",
                             isOn: Binding(get: { settings.showWorking }, set: { settings.showWorking = $0; model.settingsChanged() }))
                IslandToggle(label: "Only project ports + Docker",
                             isOn: Binding(get: { settings.projectPortsOnly }, set: { settings.projectPortsOnly = $0; model.settingsChanged() }))
                IslandToggle(label: "Hide from screen sharing",
                             isOn: $settings.hideFromScreenSharing)
            }
            Spacer(minLength: 0)
            Text("Reduce Motion and Low Power Mode turn off the bounce, wave, pulse and orbit.")
                .font(.ui(11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AlertsCard: View {
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var model: AppModel

    private let thresholds = [0, 10, 30, 60, 120]

    var body: some View {
        Card {
            CardTitle(text: "Alerts")
                .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 12) {
                IslandToggle(label: "Quiet when terminal is in front", isOn: $settings.quietWhenTerminalFront)
                IslandToggle(label: "Shortcuts ⌃⌥Y · N · T", isOn: $settings.shortcutsEnabled)
                IslandToggle(label: settings.isMuted ? "Muted until \(Fmt.timeOfDay(settings.mutedUntil ?? Date()))" : "Mute for 1 hour",
                             isOn: Binding(get: { settings.isMuted }, set: { model.mute(for: $0 ? 3600 : nil) }))
            }
            Text("Shell commands longer than")
                .font(.ui(12.5))
                .padding(.top, 14)
            HStack(spacing: 5) {
                ForEach(thresholds, id: \.self) { t in
                    let selected = settings.commandAlertSeconds == t
                    Button(t == 0 ? "Off" : (t < 60 ? "\(t)s" : "\(t / 60)m")) { settings.commandAlertSeconds = t }
                        .buttonStyle(.plain)
                        .font(.ui(11.5, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.black : Theme.text)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(selected ? Theme.amber : Theme.control, in: Capsule())
                }
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
            Text("Limit alerts at 80, 90 and 95%, and when a limit resets.")
                .font(.ui(11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
