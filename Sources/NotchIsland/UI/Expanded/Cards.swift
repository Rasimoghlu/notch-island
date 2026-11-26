import SwiftUI
import NotchIslandCore

// MARK: - AI usage

struct UsageCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card {
            CardTitle(text: "AI usage")
                .padding(.bottom, 8)
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                content(now: ctx.date)
            }
        }
    }

    /// One big number; everything else small and quiet.
    @ViewBuilder
    private func content(now: Date) -> some View {
        let claude = model.claudeUsage
        let five = claude?.fiveHour?.current(now: now)
        let week = claude?.weekly?.current(now: now)
        let codex = model.codexUsage?.fiveHour?.current(now: now)
        let ghost = Pace.elapsed(resetsAt: five?.resetsAt, window: 5 * 3600, now: now)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if let five {
                    Text("\(Int(five.usedPercent.rounded()))")
                        .font(.display(38))
                        .contentTransition(.numericText(value: five.usedPercent))
                        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: Int(five.usedPercent.rounded()))
                    Text("%").font(.display(20, .medium)).foregroundStyle(Theme.secondary)
                } else {
                    Text(model.windowTokens.map(tokens) ?? "—").font(.display(26))
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Claude · 5-hour").font(.ui(11.5)).foregroundStyle(Theme.secondary)
                    Text(five?.resetsAt.map { Fmt.resetsIn($0, now: now).replacingOccurrences(of: "Resets in", with: "resets in") } ?? "no limit data")
                        .font(.ui(11)).foregroundStyle(Theme.muted)
                }
            }
            LiquidBar(fraction: (five?.usedPercent ?? 0) / 100, height: 12)
                .overlay(alignment: .leading) {
                    if let ghost {
                        GeometryReader { geo in
                            Capsule().fill(Color.white.opacity(0.8))
                                .frame(width: 2, height: 16)
                                .offset(x: geo.size.width * ghost - 1, y: -2)
                        }
                        .help("Even pace: \(Int((ghost * 100).rounded()))% of the window has passed")
                    }
                }
                .padding(.top, 8)
            HStack(spacing: 0) {
                paceText(five, ghost: ghost)
                Spacer(minLength: 4)
                if let updated = claude?.updatedAt, now.timeIntervalSince(updated) > 15 * 60 {
                    Text("as of \(Fmt.ago(now.timeIntervalSince(updated)))").foregroundColor(Theme.muted)
                }
            }
            .font(.ui(11))
            .lineLimit(1)
            .padding(.top, 6)

            if let five, let reset = five.resetsAt {
                UsageSparkline(samples: model.history, resetsAt: reset, now: now, current: five.usedPercent)
                    .frame(height: 30)
                    .padding(.top, 8)
                    .help("This 5-hour window so far. Dashed line: even pace.")
            }

            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 12)

            miniRow("Weekly", week, color: Theme.weekly)
            miniRow("Codex", codex, color: Theme.blue)
                .padding(.top, 9)

            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 12)

            forecastLine(model.forecast, hasData: five != nil)
            if let rate = model.burnRate, rate > 0.01 {
                Text(String(format: "Burning %.1f%%/min · %.0f%%/hour", rate, rate * 60))
                    .font(.ui(11))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 5)
                    .padding(.leading, 20)
            }
            Spacer(minLength: 0)
        }
    }

    private func miniRow(_ label: String, _ w: UsageWindow?, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.ui(12)).foregroundStyle(Theme.secondary).frame(width: 50, alignment: .leading)
            ThinBar(fraction: w.map { $0.usedPercent / 100 }, color: color, height: 5)
            Text(w.map(percent) ?? "—")
                .font(.ui(12, .medium))
                .monospacedDigit()
                .foregroundStyle(w == nil ? Theme.muted : Theme.text)
                .frame(width: 36, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func forecastLine(_ result: Forecast.Result, hasData: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch result {
            case .hitsLimit(let at):
                Image(systemName: "hourglass").foregroundStyle(Theme.amber)
                (Text("Full at ") + Text(Fmt.timeOfDay(at)).fontWeight(.semibold) + Text(" at this pace"))
                    .foregroundColor(Theme.forecastText)
            case .staysUnder:
                Image(systemName: "checkmark.circle").foregroundStyle(Theme.muted)
                Text("Lasts until the reset at this pace").foregroundColor(Theme.secondary)
            case .unknown:
                Image(systemName: "hourglass").foregroundStyle(Theme.muted)
                Text(hasData ? "Not enough activity for a forecast" : "Install the status-line hook")
                    .foregroundColor(Theme.muted)
            }
        }
        .font(.ui(12))
        .lineLimit(1)
    }

    /// Ahead of pace is amber (red when far ahead); under pace is neutral, since green means "done".
    private func paceText(_ w: UsageWindow?, ghost: Double?) -> Text {
        guard let w, let ghost else { return Text("") }
        let lead = Pace.lead(usedPercent: w.usedPercent, elapsed: ghost)
        if lead > 5 { return Text("\(Int(lead.rounded()))% ahead of pace").foregroundColor(lead > 15 ? Theme.red : Theme.amberLight) }
        if lead < -5 { return Text("\(Int((-lead).rounded()))% under pace").foregroundColor(Theme.secondary) }
        return Text("on pace").foregroundColor(Theme.secondary)
    }

    private func percent(_ w: UsageWindow) -> String { "\(Int(w.usedPercent.rounded()))%" }

    private func tokens(_ t: Double) -> String {
        t >= 1_000_000 ? String(format: "%.1fM tok", t / 1_000_000) : String(format: "%.0fk tok", t / 1000)
    }

}

// MARK: - Commands + git

struct CommandsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card {
            CardTitle(text: "Commands")
                .padding(.bottom, 10)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                commands(now: ctx.date)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
                .padding(.vertical, 12)
            CardTitle(text: model.git.map { "Git · \($0.repo)" } ?? "Git")
                .lineLimit(1)
                .padding(.bottom, 10)
            gitSection
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func commands(now: Date) -> some View {
        // Ignore the very short commands every shell runs; show ones running ≥ 2 s.
        let running = model.runningCommands.filter { now.timeIntervalSince($0.startDate) >= 2 }.suffix(2)
        let finished = model.finishedCommands.prefix(max(0, 3 - running.count))
        if running.isEmpty && finished.isEmpty {
            Text(model.isDemo ? "" : "Long-running zsh commands show up here")
                .font(.ui(12))
                .foregroundStyle(Theme.secondary)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(running)) { cmd in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(cmd.command).font(.mono(13)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(Fmt.clock(now.timeIntervalSince(cmd.startDate)))
                                .font(.ui(12)).monospacedDigit().foregroundStyle(Theme.secondary)
                        }
                        RunningBar()
                    }
                }
                ForEach(Array(finished)) { rec in
                    HStack(spacing: 6) {
                        Text(rec.command).font(.mono(13)).lineLimit(1)
                        Spacer(minLength: 6)
                        Image(systemName: rec.exitCode == 0 ? "checkmark" : "xmark")
                            .font(.system(size: 10, weight: .bold))
                        Text(rec.exitCode == 0 ? Fmt.clock(rec.duration) : "exit \(rec.exitCode)")
                            .font(.ui(12)).monospacedDigit()
                    }
                    .foregroundStyle(rec.exitCode == 0 ? Theme.green : Theme.red)
                }
            }
        }
    }

    @ViewBuilder
    private var gitSection: some View {
        identityRow
        if let g = model.git {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                Text(g.branch).font(.mono(13)).lineLimit(1).truncationMode(.middle)
            }
            .padding(.top, 12)
            HStack(spacing: 8) {
                // Green is for success only; "changed" is just a state.
                chip(g.changed == 0 ? "clean" : "\(g.changed) changed",
                     fg: g.changed == 0 ? Theme.secondary : Theme.text, bg: Theme.control)
                if let ahead = g.ahead, ahead > 0 {
                    chip("↑\(ahead) to push", fg: Theme.text, bg: Theme.control)
                } else if g.ahead == nil {
                    chip("no upstream", fg: Theme.secondary, bg: Theme.control)
                }
            }
            .padding(.top, 8)
        } else {
            Text("No git repo in the active projects")
                .font(.ui(11.5))
                .foregroundStyle(Theme.muted)
                .padding(.top, 12)
        }
    }

    /// The GitHub account on this Mac and the commit identity git will use.
    @ViewBuilder
    private var identityRow: some View {
        let id = model.gitIdentity
        let name = model.git?.userName ?? id?.name
        let email = model.git?.userEmail ?? id?.email
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.secondary)
            VStack(alignment: .leading, spacing: 1) {
                if let gh = id?.githubUser {
                    (Text("@\(gh)").font(.ui(13, .medium)) + Text("  GitHub").font(.ui(11)).foregroundColor(Theme.muted))
                        .lineLimit(1)
                } else {
                    Text(name ?? "No GitHub login").font(.ui(13, .medium)).lineLimit(1)
                }
                if let email {
                    Text(id?.githubUser != nil && name != nil ? "\(name!) · \(email)" : email)
                        .font(.ui(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("git user.email not set")
                        .font(.ui(11)).foregroundStyle(Theme.amber)
                        .help("Commits need an author. Set it with: git config --global user.email you@example.com")
                }
            }
        }
    }

    private func chip(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.ui(12))
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
