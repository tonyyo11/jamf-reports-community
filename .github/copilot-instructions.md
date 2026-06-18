# Copilot Instructions for jamf-reports-community

This file provides context for GitHub Copilot and other AI coding assistants working with this project.

## Project Overview

A native macOS app (`app/`) — a SwiftUI GUI (macOS 14+, Swift 6) for fleet reporting against Jamf Pro and Jamf School. It collects data from `jamf-cli` (or a Jamf Pro CSV export, or cached snapshots), generates multi-sheet Excel workbooks and self-contained HTML reports, schedules unattended runs via LaunchAgents, tracks run history, and surfaces a Historical Trends screen built on archived `summary.json` snapshots.

All report generation is performed by a native Swift engine (`ReportEngine`); **there is no Python in the report-generation path.** The app is config-driven: users map their CSV column names to logical field names in `config.yaml` (edited through the GUI), with no code changes needed for normal use. It is a SwiftPM project (`app/Package.swift`), not a hand-rolled `.xcodeproj`.

**Key constraint:** Must work for any organization running Jamf Pro or Jamf School without requiring hardcoded org-specific values (column names, policy names, IP addresses, etc.) in the code.

## Architecture

The macOS app lives in `app/` and is a SwiftPM executable target (`JamfReports`).
Build target: macOS 14+ (Sonoma), Swift 6 strict concurrency.

### Two run paths

- **GUI** (`JamfReports.app`): the SwiftUI app — dashboards, config editing, report
  generation, scheduling, run history, Historical Trends.
- **Headless** (`main.swift --scheduled-run --mode <mode>`): invoked by LaunchAgent
  timers (and by the GUI "Run now" button). Collects and/or generates without a window.

### Key services

| Service | Purpose |
|---------|---------|
| `WorkspaceStore` | `@Observable` per-profile state. Sidebar chip switches the active profile; every screen re-routes to that workspace's data. |
| `ReportEngine` | Native Swift report engine. Reads cached jamf-cli JSON (and optional CSV), writes multi-sheet XLSX, self-contained HTML, and CSV. `collect` fetches/saves snapshots and emits `summary.json`; `generate` renders reports from cached snapshots. |
| `CLIBridge` / `CLIBridge+Run` | `Process`-based async wrapper for `jamf-cli` and `ReportEngine`. Streams stdout/stderr live to the Runs screen. All report generation uses the native Swift engine; no Python subprocess calls. |
| `WorkspacePaths` | Typed, profile-validated path constants under `~/Jamf-Reports/<profile>/`. All path construction goes through here. |
| `ProfileService` | Validates profile slugs (`^[a-z0-9][a-z0-9._-]*$`), resolves workspace URLs, discovers local profiles. |
| `ConfigService` | Reads and writes `config.yaml` within a profile workspace. Only rewrites managed top-level keys and re-reads the rest, so unrelated/unmanaged config is preserved verbatim. |
| `ScaffoldService` | CSV column detection + config writing. Initial onboarding scaffold regenerates `config.yaml`; re-scaffold uses the non-destructive `mergeColumns` path so existing agents/EAs/thresholds survive. |
| `DiagnosticBundleService` | Stages recent logs, last-N summaries, redacted config, a workspace tree, and version metadata into a zip under `~/Jamf-Reports/<profile>/diagnostics/`. Powers Settings → "Generate diagnostic bundle now". Never executes any external script. |
| `LaunchAgentService` / `LaunchAgentWriter` | Discover/parse and atomically write the app's `~/Library/LaunchAgents/com.github.tonyyo11.jamf-reports-community.*.plist` jobs. |

The full service and view inventory lives in `CLAUDE.md` / `AGENTS.md` — read those
before touching architecture.

## Critical Invariants (Do Not Break)

1. **Formula-injection safety on all CSV-/Jamf-sourced data.** Every cell written from
   user/Jamf data goes through `OOXMLWriter.sanitizeString` (XLSX) or the equivalent CSV
   escaper, which neutralizes a leading `=`, `+`, `-`, `@`, or tab. Static labels written
   by the engine are exempt.

2. **HTML escaping is centralized.** Every dynamic insertion in the HTML report routes
   through `HtmlSectionFormatters.escapeHTML`. No remote `<script src>` — HTML output is
   self-contained.

3. **No hardcoded column names.** All column names come from `config.yaml`. Strings like
   `"Computer Name"` appear only in `config.example.yaml` and `config.yaml`, never in code.

4. **No hardcoded org-specific values.** No IP addresses, URLs, usernames, department
   names, policy names, or EA names in code.

5. **No phantom config keys.** Never add a key to `config.example.yaml` that the app does
   not read. The app's config decoding/defaults (`ConfigDecoder` and per-service readers)
   are the source of truth for which keys exist.

6. **All file paths go through `ProfileService.workspaceURL(for:)` + `WorkspacePaths`.**
   Never construct workspace paths by string interpolation.

## Config System

### Single Source of Truth

The app's config defaults and decoding (`ConfigDecoder` and the per-service config
readers in `app/Sources`) define all keys. `config.example.yaml` mirrors that structure
exactly — no phantom keys.

### When Adding a Config Key

1. Give it a sensible default in the app's config decoding/defaults.
2. Read it from config in the relevant service.
3. Document it in `config.example.yaml` with a comment.
4. Update `README.md` if it's user-facing.

### Key Names (Common Confusion Points)

Use these exact names:

| Section | Key | NOT |
|---------|-----|--------|
| `columns` | `operating_system` | `os_version` |
| `columns` | `last_checkin` | `last_contact` |
| `columns` | `email` | `assigned_user_email` |
| `jamf_cli` | `profile` | `jamf_profile` |
| `jamf_cli` | `allow_live_overview` | `live_overview` |
| `security_agents` | `connected_value` | `installed_value` |
| `compliance` | `failures_count_column` | `failed_count_column` |

The full key reference and per-type custom-EA fields are in `CLAUDE.md` ("Config System —
Critical Rules").

## Custom EA Types

`custom_eas` is a list. Each entry has a `type` that selects how the value is rendered:

| Type | Behavior | Key config fields |
|------|----------|-------------------|
| `boolean` | Pass/fail counts, optional "Unknown" row | `true_value` |
| `percentage` | Distribution table, color-coded rows | `warning_threshold`, `critical_threshold` |
| `version` | Version distribution, optional status coloring | `current_versions` (list) |
| `text` | Value frequency table | — |
| `date` | Days-until-expiry, color-coded by proximity | `warning_days` |

## Testing & Validation

Run the Swift test suite from the `app/` directory:

```bash
cd app
swift test
```

Verify the app compiles before committing any Swift change:

```bash
cd app && swift build 2>&1 | tail -20
```

**Pre-push CI parity:** CI pins Xcode to `16.4` (bundled Swift 6.1.x). Local Swift 6.3+
relaxes `@MainActor` enforcement and will silently compile code that fails on CI. Before
pushing, run:

```bash
cd app && swift build --build-tests 2>&1 | grep "error:" || echo "OK"
```

### Dummy Profile Testing

For offline testing without live Jamf Pro:
- Set `jamf_cli.profile: "dummy"` in `config.yaml`.
- Point `data_dir` at a directory of pre-saved JSON (`jamf-cli-data/dummy/`).
- Fully offline — no credentials required.

## Code Conventions

- **Swift 6** with strict concurrency (`@MainActor`, `Sendable`, `async/await` throughout).
- `@Observable` for state; no `ObservableObject` / `@Published`.
- SwiftUI only — no `UIKit`; use `NSViewRepresentable` only where SwiftUI has no equivalent.
- **Functions ≤100 lines**, cyclomatic complexity ≤8.
- **100-character line length.**
- No force-unwrap (`!`) in production paths — use `guard let` / `if let`.
- New jamf-cli command wrappers go through the `CLICommand` enum and `CLIExecutor`
  protocol, not bespoke `CLIBridge` methods.

## jamf-cli JSON Data Shapes

`ReportEngine` parses these exact shapes (minimum supported jamf-cli is **v1.18.0**).
Don't change parsing without verifying against jamf-cli source:

**`pro report security --output json`**
```json
[
  {"section": "summary", "data": {"total_devices": N, "filevault_encrypted": N, ...}},
  {"section": "os_version", "os_version": "15.7.3", "count": N, "pct": "N%"}
]
```

**`pro report policy-status --output json`**
```json
[{"summary": {"total_policies": N, "enabled": N, ...},
  "config_findings": [{"severity": "...", "policy": "...", ...}]}]
```

**`pro report patch-status --output json`**
```json
[{"title": "Firefox", "id": "123", "on_latest": 100, "on_other": 20, ...}]
```

The full set of parsed shapes is documented in `CLAUDE.md` ("jamf-cli JSON Shapes").

## Schedule modes

A `Schedule.RunMode` is honored identically by the GUI "Run now" path and the headless
LaunchAgent path:

| Mode | Behavior |
|------|----------|
| `snapshot-only` | `collect` only — emits `summary.json`; no workbook |
| `jamf-cli-only` | `generate` only — from cached snapshots; no collect |
| `jamf-cli-full` | collect + generate; no CSV |
| `csv-assisted` | collect + generate; requires a CSV in `csv-inbox/` |
| `backup` | `jamf-cli pro backup` only — config objects to `backups/` |

## Related Documentation

- **CLAUDE.md / AGENTS.md** — Detailed architecture, config system reference, invariants, conventions.
- **README.md** (repo root) — End-user setup and usage guide.
- **app/README.md** — App build, distribution, and security model.
- **docs/wiki/** — Extended documentation (GitHub Wiki source).

## Before You Change Anything

1. Read `CLAUDE.md` or `AGENTS.md` for the complete invariants and architecture.
2. Understand that all CSV-/Jamf-sourced data must go through the formula-injection escaper,
   and all HTML through `escapeHTML`.
3. Build (`swift build`) and run the relevant Swift tests after your change.
4. Verify no hardcoded org-specific values leak into the code.
5. Check that config keys are read by the app before adding them to `config.example.yaml`.
