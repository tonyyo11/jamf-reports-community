# Jamf Reports — macOS App (`dev-app/2.0`)

A native SwiftUI macOS GUI for the [`jamf-reports-community`](https://github.com/tonyyo11/jamf-reports-community)
CLI. The app wraps every CLI flow — config editing, scheduling via LaunchAgents,
report generation, run history — and adds a **Historical Trends** screen built on
26 weeks of archived snapshots.

This is a working SwiftPM project, not a hand-rolled `.xcodeproj`. Open `Package.swift`
in Xcode 16+ for previews and runtime, or build from the command line with `swift build`.

## Status

- **Build target:** macOS 14+ (Sonoma), Swift 6
- **State:** scaffold + all 10 screens implemented against the design handoff (Meridian
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
│   │   └── WorkspaceStore.swift        # @Observable state per profile
│   ├── Views/
│   │   ├── Sidebar.swift               # nav + workspace switcher chip
│   │   ├── Titlebar.swift
│   │   ├── OverviewView.swift
│   │   ├── TrendsView.swift            # ★ hero feature
│   │   ├── ReportsView.swift
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

✅ All 10 screens render from demo data
✅ Sidebar collapse (expanded / compact / hidden) with `⌘0`
✅ Profile switcher chip (visual)
✅ Swift Charts for the Trends hero, multi-line comparison, stacked compliance bands
✅ `CLIBridge` discovers `jrc` / `jamf-cli` on PATH and runs subprocesses with
   live stdout streaming

## What's still stubbed (next on the punch list)

- ⏳ `config.yaml` round-trip — needs Yams (or a hand-rolled YAML emitter for the
  small set of keys the GUI touches)
- ⏳ `LaunchAgent` plist round-trip in `~/Library/LaunchAgents/com.tonyyo.jrc.<profile>.<slug>.plist`
- ⏳ Trend data parser — read each archived `.xlsx` summary or have `jrc` write
  a sidecar `summary.json` per run (open question in the design README)
- ⏳ App icon — the design handoff includes Spectrum (primary) and Patch (backup)
  HTML mockups; export via Icon Composer in Xcode 16+ before shipping
- ⏳ Actual run-now plumbing in `SchedulesView` — currently the table toggles
  are read-only

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
