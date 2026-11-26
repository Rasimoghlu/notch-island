# Notch Island

A menu-bar agent that turns the MacBook notch into a small developer dashboard for Claude Code:
usage limits with a pace forecast, what Claude (and its subagents) is doing right now, listening
ports, long-running shell commands, git status, and alerts when an agent needs you, finished or
failed. Everything is local: no network calls, no tokens, no telemetry.

## Quick start

```sh
git clone https://github.com/Rasimoghlu/notch-island.git
cd notch-island
scripts/build-app.sh --install   # builds, copies to ~/Applications, launches
hooks/install.sh --dry-run       # see exactly what the hooks change
hooks/install.sh                 # apply (asks y/N per file, makes backups)
```

Then restart running Claude Code sessions and open a new terminal tab. Building from source is
also the easiest way to share it: an app you build yourself is not quarantined, so Gatekeeper
does not block it (see "Sharing" below).

| State | What you see |
|---|---|
| idle | Looks exactly like the hardware notch (a small black pill on Macs without one) |
| working | Notch widens a little: pulsing amber dot on the left, percent on the right, and the 5-hour usage fills along the island's edge (down the left side, across the bottom, up the right; red above 90%) |
| expanded | Hover ~90 ms: drops into an 820 pt panel with **Overview / Radar / Settings** |
| needs you | Opens by itself with an amber glow: **Allow / Deny / Open terminal** |
| done / failed | Green check or red x with a short bounce; closes after 4 s unless hovered |

### Things this island does differently

- **Pace ghost.** On the edge fuse and on the 5-hour bar, a white marker shows where usage would
  be if spent evenly across the window. When the fuse runs more than 15 points ahead of it, the
  fuse turns red; the card says "18% ahead of pace", "on pace" or "9% under pace". The fuse and
  its marker appear only after the shape has settled, so they never slide along a moving outline.
- **Context per session.** The status line also passes each session's `context_window.used_percentage`.
  It is saved to `~/.notch-island/usage/context/<session>.json` and shown on the Radar as a ring and
  "ctx 62%" (amber from 80%; the tooltip suggests `/compact`).
- **Who started that server.** Every listening port is traced up the process tree (`ps -axo pid,ppid`).
  Servers started by a Claude session say "· Claude", and they keep that label after the session
  ends. Servers whose parent has exited (re-parented to launchd) are flagged **orphan**, so
  forgotten dev servers are easy to find and kill.
- **While you were away.** After 2 minutes without keyboard or mouse input (read with
  `CGEventSource`, no permission needed), done / failed / limit alerts are held back. When you
  return, you get one summary row instead: "While you were away · 12 min — Claude finished ·
  npm run build failed · …". "Needs you" is never held.

### Now: what Claude is doing

The middle column of the Overview shows the busy session's current step ("Editing Cards.swift",
"Build the app", "computer · claude-in-chrome") with the two before it, the subagents it started
(a spinner and each agent's own current step while it runs, a check when done), and "6 files
changed · 42 tool calls". Other busy sessions get one line each. No extra hooks: it reads the
transcript tail, and only while the island is open.

Listening ports sit under it as chips: click opens HTTP ports (https for x443), right-click kills
the process or stops the container after a confirm. Orphans have an amber outline. Docker
chips are grouped by compose project. The island grows just enough to show them, and keeps its
normal size when nothing is listening.

### Feels like a Dynamic Island

- **Island layout.** No boxed cards: content sits straight on the black shape, columns are split
  by hairlines, and the key number (5-hour %) is set large in SF Pro Rounded. Colour has a job:
  amber = Claude / needs attention, red = a problem, green = success, everything else neutral.
  Buttons stay quiet until hovered (Kill turns red only then).
- **Split island.** While a shell command runs for more than 3 s, a second mini island springs
  out of the main one's right edge, showing the terminal's icon inside a spinning amber ring
  (a Core Animation layer, so ~0 CPU). It merges back when the command ends.
- **Real app icons.** The terminal or IDE behind a session shows up in "needs you", on result
  rows (as a small badge) and on the Radar (with a status dot).
- **Pulse follows the burn rate.** The working dot breathes slowly when you're on pace and faster
  when you're spending ahead of the 5-hour window.
- **Frosted glass.** The open island is see-through below the notch row (black at ~32% over a
  behind-window blur), with a hairline of light along its sides and bottom.
- **Success shine.** When something finishes, a soft diagonal shine sweeps across the island once.
- **Usage sparkline.** Under the 5-hour bar: this window's usage so far against a dashed even-pace
  line.
- **Several sessions at once.** When more than one Claude session is working, the compact notch
  shows their app icons, overlapped, and a count.
- **Touch.** Clicking the collapsed island opens it straight away, with a small squish. When open
  it casts a soft shadow, so it reads as floating over the windows below.

### Alerts that stay out of the way

- **Usage limits.** A short alert when the Claude 5-hour or weekly limit crosses 80%, 90% and
  95% (each once per window, with the reset time and the pace forecast), and one when a limit
  you were warned about resets. The reset alert uses a one-shot timer, not polling.
- **Quiet when you're already looking.** Done/failed alerts are skipped when the terminal that
  ran the job is the front app. "Needs you" always shows.
- **Mute for 1 hour** from the menu-bar icon or Settings (everything except "needs you").
- **Hidden from screen sharing.** The panel is excluded from screenshots, recordings and
  screen sharing (`NSWindow.sharingType = .none`). Some ScreenCaptureKit-based apps on newer
  macOS may still capture it.
- **Keyboard:** while a permission request is showing, ⌃⌥Y allows, ⌃⌥N denies, ⌃⌥T opens the
  terminal. The keys are registered only during that time (Carbon hot keys, no Accessibility
  permission needed), so they never shadow other apps.

macOS has no public API to read Focus / Do Not Disturb, so the app does not follow it. Use mute.

## Requirements

- macOS 14+ on Apple Silicon. The build is `arm64` only; a universal (Intel) build needs Xcode.
- Swift 5.9+ toolchain. **Xcode is not required**: Command Line Tools are enough
  (`xcode-select --install`), with the SDK caveat below. With Xcode you can also open `Package.swift`.

## Build and run

```sh
scripts/build-app.sh             # → build/Notch Island.app (release, ad-hoc signed)
scripts/build-app.sh --install   # also copies to ~/Applications and launches it
```

**SDK note.** Recent Command Line Tools (macOS 27 SDK) compile SwiftUI's `@State` through a
macro plugin that only ships with Xcode ("plugin for module 'SwiftUIMacros' not found").
`build-app.sh` detects this and builds against the newest installed `MacOSX26.*.sdk` instead.
For plain `swift build` / `swift run selftest`, prefix
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`. If a future update removes
the 26.x SDKs, install Xcode.

The app has no Dock icon (`LSUIElement`). Use the menu-bar icon for **Show Island**,
**Settings…** and **Quit**. Launch at login is a toggle in Settings.

It is **not sandboxed** on purpose: it runs `lsof`, `ps`, `git` and `docker`, reads
`~/.claude`, and sends `SIGTERM` to processes you choose to kill. Distribute outside
the App Store.

### Sharing

The app is ad-hoc signed, so a copied or downloaded `.app` is rejected by Gatekeeper on another
Mac ("developer cannot be verified"). Options:

- **Build from source** on each Mac (Quick start above). Nothing is quarantined, nothing is blocked.
- Send the `.app` and have the receiver run `xattr -dr com.apple.quarantine "Notch Island.app"` once.
- For a proper release: sign with a Developer ID certificate and notarize (Apple Developer
  Program membership needed).

## Hook setup

Nothing is installed automatically. The installer shows a diff of every change and asks
before writing each file. It also makes a backup.

```sh
open "$HOME/Applications/Notch Island.app"   # first launch creates ~/.notch-island/bin/notch-hook
hooks/install.sh --dry-run                  # only print the diffs
hooks/install.sh                            # apply, with a y/N prompt per file
hooks/uninstall.sh                          # remove everything install.sh added
```

### What it changes

**`~/.claude/settings.json`**: it adds these entries and leaves everything else untouched:

```jsonc
"hooks": {
  "Notification":      [{ "hooks": [{ "type": "command", "command": "\"~/.notch-island/bin/notch-hook\" claude Notification", "timeout": 5 }] }],
  "Stop":              [{ "hooks": [{ "type": "command", "command": "\"…/notch-hook\" claude Stop", "timeout": 10 }] }],
  "StopFailure":       [{ "hooks": [{ "type": "command", "command": "\"…/notch-hook\" claude StopFailure", "timeout": 5 }] }],
  "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "\"…/notch-hook\" claude PermissionRequest", "timeout": 30 }] }]
},
"statusLine": { "type": "command", "command": "\"…/notch-hook\" statusline", "padding": 0 }
```

(The real file gets absolute paths.) If you already have a `statusLine`, it is saved to
`~/.notch-island/statusline-chain`, and `notch-hook` runs it and prints its output, so
your status line looks the same.

**`~/.zshrc`**: it appends one line:

```sh
[[ -r "$HOME/.notch-island/notch-island.zsh" ]] && source "$HOME/.notch-island/notch-island.zsh"  # notch-island
```

Restart running Claude Code sessions and open a new terminal tab afterwards.

## Where the data comes from

| Card | Source | Refresh |
|---|---|---|
| Claude 5-hour / weekly % | Claude Code passes `rate_limits` (`used_percentage`, `resets_at`) to status-line commands on stdin. `notch-hook statusline` saves it to `~/.notch-island/usage/claude.json` | File watch (FSEvents), no polling |
| Forecast | Least-squares fit of the last 45 min of percent samples. With too few samples, it falls back to token throughput from `~/.claude/projects/**/*.jsonl` scaled by percent-per-token | On each new sample; log scan on expand and every 30 s while expanded |
| Codex 5-hour | `rate_limits` in the newest `~/.codex/sessions/YYYY/MM/DD/*.jsonl` | On expand, then every 30 s while expanded |
| Working / Radar | `~/.claude/sessions/<pid>.json` (`status`: busy/idle, `cwd`) | File watch |
| Now | Tail of the busy session's transcript (`~/.claude/projects/*/<session>.jsonl`): tool calls of the current turn in plain words, files changed. Subagents come from `Agent` calls; each one's own transcript (`<session>/subagents/agent-<id>.jsonl`) gives its current step, and it counts as running while that file was written in the last 30 s | On expand, then every 3 s while expanded |
| Ports (under Now) | `lsof -nP -iTCP -sTCP:LISTEN`, cwd via `lsof -a -p PIDS -d cwd -Fn`, `ps` for the dev-server name, `docker ps` when a Docker socket exists. By default only **project** servers are listed: the process runs from a folder inside home (not home itself, `~/Library` or hidden folders) or on `/Volumes`, plus Docker containers. Apps, system daemons and Claude/Codex's own ports are hidden (toggle in Settings) | 3 s expanded, 60 s collapsed |
| Commands | zsh `preexec`/`precmd` hook → `~/.notch-island/shell/` and `events/` | File watch |
| Git | The first git repo among: the busy session's folder, other sessions, shell commands, then the folders behind open ports (dev servers, compose projects). `rev-parse` / `status --porcelain` / `rev-list @{upstream}..HEAD` | 9 s while expanded |
| Git account | GitHub login from gh's local `~/.config/gh/hosts.yml` (no API call), `user.name` / `user.email` as git resolves them; warns when no email is set | With the git card |
| Alerts | Claude hooks → `~/.notch-island/events/*.json` | File watch |

### Why no OAuth / usage endpoint

The status-line `rate_limits` field is official and local, so the app never reads the
Keychain or calls an unofficial endpoint. The trade-off is that the numbers only update
while a Claude Code session is open and rendering its status line. When they are old, the
card says "as of 12 min ago". After `resets_at` passes, a window counts as 0%.

### Allow / Deny from the notch

A `Notification` hook can only report; it cannot answer. Allow/Deny therefore uses a
`PermissionRequest` hook that **blocks** while it waits for the app's answer in
`~/.notch-island/responses/<id>.json`:

- If the app isn't running, the hook returns immediately.
- If you don't answer within `NOTCH_ISLAND_PERMISSION_TIMEOUT` seconds (default 20), the
  hook prints nothing and Claude Code shows its normal terminal prompt. The same happens if
  the app quits while waiting.
- **Cost:** while the notch waits, the terminal prompt is delayed by up to that timeout.
  Set the variable lower (or run `hooks/uninstall.sh` and re-add only the other hooks) if
  that bothers you.

Deny sends Claude the message "Denied from Notch Island."

## Project layout

```
Package.swift                 targets: NotchIslandCore, NotchIsland, notch-hook, selftest
Sources/NotchIslandCore/      pure logic, Foundation only
  IslandMachine.swift         state + reducer (the state machine), away digest
  Usage.swift                 UsageProvider protocol, Claude/Codex providers, Forecast, Pace, context
  LimitWatch.swift            80/90/95 % and reset alerts, once per window
  LiveActivity.swift          transcript tail → current step, recent steps, subagents
  ClaudeLogScanner.swift      incremental jsonl token reader
  Ports.swift                 lsof / ps / docker parsers, Claude ownership, orphans, compose groups
  Sessions.swift              ~/.claude/sessions, turn summary, git identity
  AgentEvent.swift, Paths.swift, Fmt.swift
Sources/NotchIsland/          the app (AppKit + SwiftUI)
  App/        entry, AppModel (store + scheduling), Snapshot (dev tool)
  Window/     NotchPanel, PanelController (hit-testing, hover), IslandLayout
  Services/   Shell, FileWatcher (FSEvents), ProcessControl, Docker, Git, HotKeys, settings
  UI/         root view + shape morph, compact, alerts, split bubble, Motion (all timings), Theme
  UI/Expanded Overview (Usage, Now + ports strip, Commands + Git), Radar, Settings
Sources/notch-hook/           CLI called by Claude hooks and the status line
Sources/selftest/             assertion tests
hooks/                        notch-island.zsh, install.sh, uninstall.sh, merge_settings.py
```

### State machine

`IslandState` is a struct, and `phase` is derived from it (alert > expanded > compact > idle),
so there is only one source of truth. `IslandMachine.reduce(&state, input)` is pure and
returns effects (the 4 s auto-close timer). The store runs the effects and feeds
`.alertTimedOut` back in; a stale timer finds nothing and does nothing.

```
idle/compact ── hover 90 ms ──▶ expanded ── leave + 180 ms ──▶ compact if busy, else idle
any          ── event ─────────▶ alert (needs-you first, up to 3 result rows)
done/failed  ── 4 s ───────────▶ back (if hovered: closes when the pointer leaves)
needs-you    ── Allow/Deny, timeout, the session resumes, or Stop ──▶ back
```

The black shape is a single `NotchShape`: a body with rounded bottom corners whose top corners
flare outward with a small concave curve, the way the hardware notch meets the screen edge. In
idle the body is exactly the notch cut-out, so the island grows out of it and shrinks back into
it. When opening, the width leads by a hair and the height follows (alerts overshoot a little).
When closing, the content blinks out first (70 ms), then every edge converges onto the notch
outline together on a critically damped spring, so it never undershoots and slips behind the
cut-out. Content enters once the shape is about two-thirds open (~95 ms): the header, then the cards
30 ms apart, each fading in, rising a few points and un-blurring. A full open takes about
0.3 s and a close about 0.25 s. Every timing lives in `UI/Motion.swift`.

Smaller touches:
- The collapsed notch swells slightly while the pointer rests on it, just before it opens.
- The tab highlight is one capsule that slides between tabs (`matchedGeometryEffect`).
- Percentages roll when they change (`.numericText`).
- In alerts, the done check draws itself, the failed x shakes, and the warning ! pops.

The status dot moves between the compact notch and the header with `matchedGeometryEffect`.

### Performance

Measured on this machine: **0.0% CPU** idle and in the compact working state, about 50–60 MB RSS.
- The working dot's pulse is a Core Animation layer animation (it runs in the render server).
- The liquid wave, orbit rings and needs-you glow exist only while their view is on screen.
- Transcripts, git and ports are read only while the island is open (ports also once a minute
  when closed). The frosted blur is drawn by the WindowServer.
- Reduce Motion or Low Power Mode turns off every loop and the bounce.
- When collapsed, the panel ignores the mouse, so clicks reach the menu bar. A mouse-moved
  monitor turns hit-testing on only inside the current shape.

## Development

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk   # see the SDK note
swift build                          # debug build of everything
swift run selftest                   # 101 checks: state machine, parsers, forecast, live activity, ports
.build/debug/NotchIsland --demo overview          # live panel with sample data (overview|radar|settings|compact|needs|done|limits|idle)
.build/debug/NotchIsland --snapshot radar out.png # render a state to PNG with this Mac's notch shown in red (--no-notch to hide)
.build/debug/NotchIsland --snapshot-morph compact:expanded frames   # PNG frames during a transition
NOTCH_ISLAND_DEBUG=1 open -W "build/Notch Island.app"            # logs every state transition to stderr
```

XCTest and swift-testing do not run with Command Line Tools alone, so tests are a plain
executable (`selftest`).

### Event format (`~/.notch-island/events/*.json`)

```json
{"v":1,"id":"1795611527000-ab12cd34","ts":1795611527.35,"source":"claude|shell",
 "kind":"permission|permission_resolved|needs_you|done|failed|command_end",
 "session_id":"…","cwd":"/path","title":"…","message":"…","command":"…",
 "exit_code":0,"duration_ms":1208,"files_changed":2,"request_id":"…","shell_pid":123}
```

To add a new agent, write these files from its hooks. To add a new usage source, implement
`UsageProvider`.

## Not done yet / known limits

- Only **Claude Code** is visible (terminal, IDE plugins, and most likely the Code tab of the
  desktop app). Plain chats in the Claude desktop app or on claude.ai run no hooks and no status
  line, so the island cannot see them. Reading the desktop app's private storage was rejected
  (undocumented, fragile, private).
- The 5-hour / weekly limit is shared with those chats, but the percent only refreshes while a
  Claude Code session renders its status line. If you mostly chat in the desktop app, the number
  can be behind; the card then says "as of N min ago". Polling Anthropic's unofficial usage
  endpoint with Claude Code's Keychain login would fix this, and was deliberately left out.
- Subagents launched in the background return at once, so one counts as running while its own
  transcript was written in the last 30 s. An agent thinking for longer can briefly show as done.
- Apple Silicon only, ad-hoc signed (see Sharing). No auto-update: pull and run
  `scripts/build-app.sh --install` again.
- On very bright windows the frosted panel's contrast drops a little; tune `Theme.islandOpacity`.
- Radar "Focus" brings the session's terminal **app** forward, not the specific tab.
- The menu bar must not auto-hide for hover to feel right on Macs without a notch.
- Over full-screen apps the panel uses `.statusBar + 1` with `fullScreenAuxiliary`. This
  was not checked on screen here, because this terminal has no Screen Recording permission.
