# Architecture

This document describes the design of jamf-reports-community: how its two components relate,
how data flows through the system, and the key decisions that shaped the implementation.

For development conventions, config keys, and testing guidance see `CLAUDE.md`.

---

## System Overview

The project ships two components that are released together:

```
┌─────────────────────────────────────────────────────────────┐
│                   Native macOS App (Swift)                   │
│                                                              │
│  ┌──────────┐  ┌──────────────┐  ┌────────────────────────┐ │
│  │  SwiftUI │  │  CLIBridge   │  │    ReportEngine        │ │
│  │  Views   │◄─│  (subprocess │◄─│    (native Swift       │ │
│  │  (16 scr)│  │   wrapper)   │  │     engine)            │ │
│  └──────────┘  └──────┬───────┘  └────────────────────────┘ │
└──────────────────────┬┼────────────────────────────────────--┘
                       ││ subprocess + stdin/stdout
               ┌───────┴┴────────┐
               │    jamf-cli     │  (external binary, Homebrew)
               │  (Go binary)    │
               └────────┬────────┘
                        │ HTTPS
               ┌────────┴────────┐
               │    Jamf APIs    │
               │  Pro / School   │
               │  / Protect      │
               └─────────────────┘
```

**Python CLI engine** (`jamf-reports-community.py`) — Single-file script. Reads cached JSON
snapshots from disk and generates multi-sheet Excel workbooks and self-contained HTML reports.
Not a dependency of the Swift app's core data path; it handles the Excel/HTML output layer.

**Native macOS app** (`app/`) — SwiftUI frontend backed by a native Swift engine
(`ReportEngine`). Handles all interactive and scheduled data collection, visualization
(Trends, Fleet Overview, Device Lookup), and report generation. Bundles both the Python
runtime and the CLI script for users who don't have Python installed.

---

## App Component Map

```
App entry points
├── JamfReportsApp.swift      @main — GUI mode, sets up WorkspaceStore + window
└── main.swift                Daemon/scheduled mode; invoked by LaunchAgent

State
└── WorkspaceStore            @Observable root. Owns the active profile, cached
                              summary data, toast state, and refresh scheduling.

Data layer
├── ReportEngine              Native Swift engine. Runs jamf-cli subprocesses,
│   ├── CoreDashboard         parses JSON, writes Excel/HTML/CSV via OOXMLWriter
│   ├── SchoolDashboard       and HtmlReport. No Python required for core paths.
│   ├── CSVDashboard
│   └── HtmlReport
│
├── CLIBridge                 Process-based async wrapper. Dispatches jamf-cli
│   ├── CLIBridge+Generation  subprocesses, streams stdout/stderr to the UI,
│   └── CLIBridge+Run         saves JSON snapshots, enforces auth guard.
│
└── CLICommand                Enum of typed jamf-cli invocations. New commands
                              go here; CLIBridge's ad-hoc methods are legacy.

Workspace management
├── WorkspacePaths            Typed path constants under ~/Jamf-Reports/<profile>/
├── ProfileService            Slug validation + workspace discovery
├── WorkspacePermissionHardener  chmod sweep after every collect/generate (C-01)
└── WorkspaceMigration        On-disk layout migration between app versions

Scheduling
├── CollectionTier (enum)     hot (15m) / warm (4h) / cold (24h) cadence definitions
├── RefreshPolicy             Per-tier staleness thresholds and failure backoff
├── RefreshCoordinator        Drives background refresh; checks staleness via
│                             tier.stalenessProbeKind before collecting
├── LaunchAgentWriter         Writes ~/Library/LaunchAgents/*.plist atomically
├── TieredLaunchAgentWriter   Per-tier plist variant (one agent per tier)
└── LaunchAgentService        Reads and parses existing agent plists

Auth
├── authGuard (CLIBridge)     Probes `jamf-cli pro auth token` before live commands
└── TokenStatus               Value type for token validity; raw excluded from JSON

Inventory + Trends
├── DeviceInventoryService    Reads cached inventory JSON
├── TrendStore                Loads summary.json snapshots for Trends charts
├── SummaryJSONParser         Parses the summary.json schema
└── SnapshotRetentionService  Enforces keep-N policy on snapshot archives

Other services
├── JamfCLIInstaller          Homebrew-based auto-update + minimum-version check
├── SystemActions             NSWorkspace open/reveal, path allow-listed
├── YAMLCodec                 Minimal YAML read/write for config.yaml GUI fields
├── RunHistoryService         Reads automation/logs/ run records
└── ReportLibrary             Lists Generated Reports/ directory
```

---

## Data Flow

### Collection

```
LaunchAgent timer  (or UI "Collect now" button)
        │
        ▼
RefreshCoordinator.maybeRefresh(tier:)
        │  checks: snapshot mtime vs tier.stalenessProbeKind directory
        ▼
CLIBridge.collect(profile:)
        │  spawns: jamf-cli -p <profile> pro inventory list --output json --no-input
        │  spawns: jamf-cli -p <profile> pro report security --output json --no-input
        │  spawns: … (27 snapshot kinds total)
        │  environment: environmentForJamfCLI() — minimal pinned env (B-13)
        ▼
~/Jamf-Reports/<profile>/jamf-cli-data/<kind>.json
        │
        ▼
WorkspacePermissionHardener.tighten()   (chmod 0700/0600 sweep)
```

### Report generation

```
CLIBridge.generate(profile:template:)
        │
        ├─► ReportEngine.generate()          (native Swift path — primary)
        │       reads:  jamf-cli-data/*.json
        │       writes: Generated Reports/<stem>-<timestamp>.xlsx
        │               Generated Reports/<stem>-<timestamp>.html
        │
        └─► Python CLI (fallback for Excel edge cases)
                reads:  jamf-cli-data/*.json
                writes: Generated Reports/
```

### Historical trends

```
Each collect run
        └─► ReportEngine.emitSummaryJSON()
                writes: snapshots/computers/summaries/<date>-summary.json

TrendStore (loaded on Trends screen open)
        reads: snapshots/computers/summaries/*.json
        feeds: TrendsView SwiftUI charts
```

---

## Workspace Layout

All per-profile state lives under `~/Jamf-Reports/`:

```
~/Jamf-Reports/
└── <profile-slug>/
    ├── config.yaml                        # User-edited report config
    ├── jamf-cli-data/                     # Cached JSON snapshots (0700)
    │   ├── computers.json
    │   ├── overview.json
    │   ├── security.json
    │   └── … (27 kinds)
    ├── Generated Reports/                 # Output files (xlsx, html)
    │   └── archive/                       # Older timestamped runs
    ├── snapshots/
    │   ├── computers/
    │   │   └── summaries/                 # summary.json history for Trends
    │   └── csv/                           # Archived CSV exports
    └── automation/
        └── logs/                          # Per-run stdout/stderr logs
```

Profile slugs are validated by `ProfileService.isValid` (`^[a-z0-9][a-z0-9._-]*$`) before
any path is constructed. All path construction goes through `WorkspacePaths` typed constants —
never string interpolation.

---

## Scheduling Architecture

The app installs user-space LaunchAgents (never system-wide LaunchDaemons).

```
~/Library/LaunchAgents/
├── com.jamfreports.<profile>-hot.plist    StartInterval: 900 s
├── com.jamfreports.<profile>-warm.plist   StartInterval: 14 400 s
└── com.jamfreports.<profile>-cold.plist   StartInterval: 86 400 s
```

Each agent fires `main.swift` in daemon mode. `RefreshCoordinator` checks whether the
tier's data is actually stale (via `stalenessProbeKind` directory mtime) before collecting
to avoid redundant API calls when the system wakes frequently.

**Staleness probe mapping:**

| Tier | Probe directory | Rationale |
|------|----------------|-----------|
| hot | `overview` | Always written; cheapest indicator |
| warm | `policy-status` | Written every warm collect |
| cold | `patch-device-failures` | Only written in cold (expensive scan) |

---

## Security Model

| Boundary | Mechanism |
|----------|-----------|
| Path traversal | `SystemActions` open/reveal allow-listed to `~/Jamf-Reports`, `~/Library/LaunchAgents`, standard user folders. Trailing-`/` prefix check prevents symlink escape. |
| Profile slug injection | `ProfileService.isValid` regex at every path-construction site |
| Credential storage | Secrets never persisted by the app. Onboarding writes to jamf-cli via stdin, immediately cleared. Long-term secrets live in the system keychain managed by jamf-cli. |
| Subprocess environment | `CLIBridge.environmentForJamfCLI()` pins a minimal env for all subprocess calls, preventing `DYLD_INSERT_LIBRARIES`, `SSL_CERT_FILE`, and `JAMF_CLI_*` leakage (B-13). |
| File permissions | `WorkspacePermissionHardener` enforces 0700 on workspace directories and 0600 on snapshot files after every collect/generate run (C-01/C-03/C-04). |
| Executable trust | `isTrustedNativeExecutable` restricted to `Bundle.main.executableURL` only. |
| Atomic writes | Config and plist updates use `replaceItem(at:withItemAt:)` to prevent corruption on crash. |
| Runtime | Hardened Runtime enabled. Entitlements in `app/JamfReports.entitlements`. |

---

## jamf-cli Integration

jamf-cli is optional — the app degrades gracefully when it is absent. All subprocess calls:

- Pass `--no-input` to prevent the CLI from blocking on prompts in non-interactive contexts.
- Pass `--output json` for structured, parseable output.
- Run under `environmentForJamfCLI()` (pinned minimal environment).
- Are guarded by `authGuard`, which probes `pro auth token` before live API commands.

**Exit code handling:**

| Code | Meaning | App response |
|------|---------|-------------|
| 0 | Success | Continue |
| 1 | General error | Warn; use cached data |
| 2 | Bad flags (caller bug) | Log as error |
| 3 | HTTP 401 — auth failure | Hard abort; clear error message |
| 4 | HTTP 404 — not found | Warn; use cached data |
| 5 | HTTP 403 — permission denied | Warn with specific message |
| 6 | HTTP 429 — rate limited | Warn with specific message; transient |

Jamf School profiles skip the `pro auth token` probe (`shouldSkipAuthProbe`) because School
uses API key authentication rather than OAuth2 bearer tokens.

---

## Jamf Service Architectures

Understanding the upstream SDK differences matters when adding new data sources:

| Service | Protocol | Auth | Notes |
|---------|----------|------|-------|
| Jamf Pro (modern) | REST | OAuth2 bearer token | `pro` namespace; token cached on disk by jamf-cli |
| Jamf Pro (classic) | REST | Basic / bearer | Generated commands from Classic API manifest |
| Jamf Platform API | REST | Platform OAuth2 | `pro` namespace; runtime-gated (requires platform auth) |
| Jamf School | REST | API key | `school` namespace; API key injected internally by SDK |
| Jamf Protect | **GraphQL** | Separate OAuth2 | Hand-written commands; uses `jamfprotect-go-sdk`; name→ID resolver pattern |

Protect commands are entirely different from Pro/School — they use the GraphQL SDK, not raw
HTTP, and require a separate auth context. Protect data collection is best-effort: jamf-cli
exits non-zero when Protect is not configured for the active profile, and this does not abort
other collect commands.

---

## Python CLI Engine Architecture

The Python CLI (`jamf-reports-community.py`) is a single 13,600-line file. Key design rules:

- **No split.** Do not create additional modules. It is a drop-in script.
- **Config-driven.** `DEFAULT_CONFIG` is the single source of truth. `config.example.yaml`
  must mirror it exactly — no phantom keys.
- **`_safe_write` invariant.** All CSV-sourced data routes through `_safe_write()` before
  being written to a worksheet cell. Never call `worksheet.write()` directly with user data.
- **No hardcoded column names.** Every column reference goes through `ColumnMapper`.
- **Optional dependencies.** jamf-cli absence → CSV-only mode. matplotlib absence → no charts.

The Excel output pipeline: `JamfCLIBridge` fetches JSON → `CoreDashboard`/`SchoolDashboard`
parse it → `OOXMLWriter`-equivalent (xlsxwriter) writes cells → `ChartGenerator` embeds PNGs.

---

## Build Targets

```bash
# Validate compilation
cd app && swift build

# Run tests
cd app && swift test

# Produce runnable .app (ad-hoc signed)
cd app && ./build-app.sh release

# Skip Python runtime bundling for fast local iteration
cd app && JRC_BUNDLE_PYTHON=0 ./build-app.sh debug
```

The release build bundles a private Python runtime via `scripts/build-python-runtime.sh`.
Pin SHA256 values live in `app/python-runtime.lock`. Distribution requires a Developer ID
certificate, `xcrun notarytool` notarization, and `xcrun stapler staple` — currently manual.
