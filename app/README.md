# Jamf Reports — macOS App (`dev-app/2.0`)

A native SwiftUI macOS GUI for the [`jamf-reports-community`](https://github.com/tonyyo11/jamf-reports-community)
CLI. The app wraps every CLI flow — config editing, scheduling via LaunchAgents,
report generation, run history — and adds a **Historical Trends** screen built on
26 weeks of archived snapshots.

This is a working SwiftPM project, not a hand-rolled `.xcodeproj`. Open `Package.swift`
in Xcode 16+ for previews and runtime, or build from the command line with `swift build`.

## Status

- **Build target:** macOS 14+ (Sonoma), Swift 6
- **State:** scaffold + all 12 screens implemented against the design handoff (Meridian
  Health demo data). CLI bridge wired to `Process` but `LaunchAgent` round-trip,
  config.yaml read/write, and live trend data parsing are TODO.

## Quick start

```bash
# From repo root
cd app
swift build                        # validates the package compiles
swift run JamfReports               # launches the app (debug build)
```

To open in Xcode for previews and the full runtime:

```bash
open Package.swift
```

To build a runnable `JamfReports.app` (with Dock icon and proper window
behavior — needed because SwiftPM only emits a bare executable):

```bash
cd app
./build-app.sh release             # → app/build/JamfReports.app
open build/JamfReports.app
```

The script ad-hoc signs the bundle so Gatekeeper allows it on the local
machine. For distribution to other Macs, replace the ad-hoc sign with a
Developer ID signature and notarize.

## Design source

Implemented from the [Claude Design](https://claude.ai/design) handoff — see
`design_handoff_jamf_reports_app/` (not committed; lives in the design archive). The
design tokens, color palette, and screen layouts are all faithful to the handoff
README's spec. Brand restraint is intentional: PN&P gold is the sole accent on CTAs
and active states; IBM Plex Mono is reserved for monospaced labels, code paths,
profile ids, and stdout.

## Project layout

```
app/
├── Package.swift                       # SwiftPM manifest (executable target)
├── Sources/JamfReports/
│   ├── App/
│   │   ├── JamfReportsApp.swift        # @main App + sidebar keyboard shortcut
│   │   └── ContentView.swift           # window shell + routing
│   ├── Theme/
│   │   ├── Theme.swift                 # design tokens (colors, fonts, metrics)
│   │   └── Components.swift            # Pill, Card, Kicker, StatTile, etc.
│   ├── Models/
│   │   ├── Models.swift                # Schedule, Report, ColumnMapping, etc.
│   │   └── DemoData.swift              # Meridian Health fictional org
│   ├── Services/
│   │   ├── CLIBridge.swift             # Process wrapper for jrc / jamf-cli
│   │   ├── DeviceInventoryService.swift # Read-only device inventory loader
│   │   └── WorkspaceStore.swift        # @Observable state per profile
│   ├── Views/
│   │   ├── Sidebar.swift               # nav + workspace switcher chip
│   │   ├── Titlebar.swift
│   │   ├── OverviewView.swift
│   │   ├── DevicesView.swift
│   │   ├── TrendsView.swift            # ★ hero feature
│   │   ├── ReportsView.swift
│   │   ├── BackupsView.swift
│   │   ├── SchedulesView.swift
│   │   ├── RunsView.swift
│   │   ├── ConfigView.swift
│   │   ├── CustomizeView.swift
│   │   ├── SourcesView.swift
│   │   ├── SettingsView.swift
│   │   └── OnboardingView.swift
│   └── Resources/
│       └── Fonts/                      # IBM Plex Mono TTFs
└── README.md
```

## Architecture

- `WorkspaceStore` — `@Observable` per-profile state. Sidebar bottom chip switches
  the active profile; every screen re-routes to that workspace's data.
- `CLIBridge` — `Process`-based async wrapper for `jrc` and `jamf-cli`. Streams
  stdout/stderr through a callback so the Runs screen can render lines as they
  arrive. Auto-detects binaries on PATH (Homebrew + system locations).
- `Theme` — single source of truth for colors, fonts, metrics. Hex values and font
  weights mirror the prototype's `pnp-tokens.css` and `app.css`. Body remains San
  Francisco; only mono and serif H1s use brand fonts.

## What's wired up

✅ All 12 screens render from demo data
✅ Devices screen reads current workspace inventory and cached patch/compliance data
- Backups screen lists per-profile backups and wraps `jrc backup` / `jamf-cli pro diff`
✅ Sidebar collapse (expanded / compact / hidden) with `⌘0`
✅ Profile switcher chip and local workspace discovery (`~/Jamf-Reports/*/config.yaml`)
✅ Active app profile is passed through every `jrc` / `jamf-cli` operation
✅ Fresh workspaces can collect and generate from jamf-cli only, with no CSV/history
✅ Swift Charts for the Trends hero, multi-line comparison, stacked compliance bands
✅ `CLIBridge` prefers the bundled Python script, falls back to `jrc`, and runs
   subprocesses with live stdout streaming
✅ `SystemActions` for "Reveal in Finder" and "Open Report" with secure path validation
✅ `LaunchAgentService` for discovering and parsing existing scheduled jobs

## What's still stubbed (next on the punch list)

- ⏳ `config.yaml` round-trip — needs Yams or a hand-rolled YAML emitter
- ⏳ `LaunchAgent` write/load/unload operations — currently read-only for safety
- ⏳ Trend data parser — read each archived `.xlsx` summary or the new `summary.json`
- ⏳ App icon — Spectrum assets exist but need final `.icns` assembly
- ⏳ Actual run-now plumbing in `SchedulesView` — currently the table toggles
   are read-only

## Build distribution

The `./build-app.sh release` script performs ad-hoc signing (`codesign -s -`) so the
bundle can run on the local development machine. For distribution to other Macs:

1. **Signing:** The bundle must be signed with a valid **Developer ID Application**
   certificate.
2. **Notarization:** The signed bundle must be submitted to Apple's notary service
   via `xcrun notarytool`.
3. **Stapling:** The notarization ticket must be stapled to the bundle via
   `xcrun stapler staple`.

These steps are currently manual and not yet integrated into the `build-app.sh` script.

## Security model

The app is designed as a non-privileged GUI shell over the CLI tool:

- **Path allow-list:** `NSWorkspace` file actions (Open/Reveal) are strictly
  bounded to `~/Jamf-Reports`, `~/Library/LaunchAgents`, and standard user
  folders. The app refuses to interact with paths outside this scope.
- **Profile-name regex:** Workspace and profile names are validated against
  `^[a-z0-9][a-z0-9._-]*$` to prevent path traversal and malformed plist labels.
- **No persisted credentials in app:** During onboarding, the GUI passes the API
  client secret to `jamf-cli` over stdin, redacts failure output, and clears the
  field afterward. Persistent secrets remain in the system keychain through
  `jamf-cli`; normal app flows reference profiles by name.
- **UserAgents-only:** The app only manages `~/Library/LaunchAgents`. It never
  requests `sudo` or attempts to install system-wide LaunchDaemons.
- **Atomic-write policy:** (Planned) All configuration and plist updates will
  use atomic-write patterns (`write(to:options:)` with `.atomic`) to prevent
  data corruption during power loss or app crashes.

## Build verification

The project compiles against Swift 6 / macOS 14+. Verify locally:

```bash
cd app
swift build 2>&1 | tail -20
```

For a release build:

```bash
swift build -c release
```

## License

MIT, same as the parent project. See repo root.
