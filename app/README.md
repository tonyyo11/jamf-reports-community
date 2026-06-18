# Jamf Reports — macOS App

A native SwiftUI macOS app for fleet reporting against Jamf Pro and Jamf School — the
recommended interface for the
[`jamf-reports-community`](https://github.com/tonyyo11/jamf-reports-community) project.
It collects data, generates Excel and HTML reports, schedules unattended runs via
LaunchAgents, and tracks fleet health over time on a Historical Trends screen.

This is a SwiftPM project, not a hand-rolled `.xcodeproj`. Open `Package.swift` in
Xcode 16+ for previews and runtime, or build from the command line with `swift build`.

## Status

- **Build target:** macOS 14+ (Sonoma), Swift 6, SwiftPM (no `.xcodeproj`).
- **State:** shipped in v2.0.0 — all dashboards, scheduling, config editing, report
  generation, and Historical Trends are implemented. Reports are produced by a native
  Swift engine (`ReportEngine`); there is no Python in the report-generation path and no
  Python runtime is bundled or required.
- **Distribution:** local builds are ad-hoc signed; Developer ID signing, notarization,
  and stapling remain manual steps (see Build distribution below).

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
│   │   ├── CLIBridge.swift             # Process wrapper for jamf-cli + native ReportEngine
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
- `CLIBridge` — `Process`-based async wrapper for `jamf-cli` and the native Swift
  `ReportEngine`. Streams stdout/stderr through a callback so the Runs screen can render
  lines as they arrive. Auto-detects `jamf-cli` on PATH (Homebrew + system locations).
- `Theme` — single source of truth for colors, fonts, metrics. Hex values and font
  weights mirror the prototype's `pnp-tokens.css` and `app.css`. Body remains San
  Francisco; only mono and serif H1s use brand fonts.

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

No Python runtime is bundled into the app — `build-app.sh` builds and signs the SwiftPM
executable only, and report generation is performed entirely by the native Swift
`ReportEngine`.

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
