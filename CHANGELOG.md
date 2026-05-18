# Changelog <!-- markdownlint-disable MD024 -->

All notable user-visible changes to this project should be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions in this repository map to git tags.

## [Unreleased]

### Changed

- **Schedule mode semantics tightened — each mode now does exactly one thing** (PR-21, macOS app):
  Before PR-21, three of the four `Schedule.RunMode` cases had descriptions
  that disagreed with the code: `jamf-cli-only` said "from cached data" but
  called collect first; `jamf-cli-full` and `csv-assisted` were operationally
  identical (both passed the newest CSV when present, both no-op'd CSV when
  absent). Modes are now strict and distinct:
  - `snapshot-only` — collect only; updates Trends; no workbook (unchanged from PR-20).
  - `jamf-cli-only` — generate only from the latest cached snapshots; **no collect step**.
    Fast re-render path for editing config or templates without hitting the API.
  - `jamf-cli-full` — collect + generate; no CSV. Renamed display label clarifies
    "No CSV input."
  - `csv-assisted` — collect + generate with a CSV from `csv-inbox/`. Now
    **hard-fails when no CSV is present** instead of silently falling back to a
    jamf-cli-only workbook. Earlier behavior masked broken CSV pipelines for
    days at a time; use `jamf-cli-full` explicitly if you want the no-CSV path.
  Existing pre-PR-20 LaunchAgent plists (which omit `--mode`) default to
  `jamf-cli-only` — that means the silent collect they did before PR-21 stops
  happening; resave the schedule from the GUI to migrate to the explicit mode
  you want. `Schedule.RunMode.displayTitle` and `displayDescription` strings
  updated to match the new semantics; `docs/wiki/07-LaunchAgent-Automation.md`
  Workflow Modes section rewritten to describe both the strict Swift contract
  and the legacy Python `launchagent-setup` divergence (notably csv-assisted's
  silent fallback).

### Fixed

- **Schedule mode now round-trips through the LaunchAgent plist** (PR-20, macOS app):
  The Swift `LaunchAgentWriter.nativeSingleWrite` / `nativeMultiWrite` now embed
  `--mode <rawValue>` in `ProgramArguments` so the user's selected mode
  (snapshot-only / jamf-cli-only / jamf-cli-full / csv-assisted) survives the
  round-trip through `LaunchAgentService.parse`. Previously the writer omitted
  mode entirely; the parser then defaulted to jamf-cli-only on every read,
  silently overriding the user's choice. The Schedules form let you pick
  snapshot-only, but the next refresh of the list showed it as jamf-cli-only —
  and the scheduled run did the jamf-cli-only behavior because `main.swift`
  unconditionally ran collect + generate. `main.swift`'s `--scheduled-run`
  handler now parses `--mode` (falling back to jamf-cli-only for pre-PR-20
  plists) and dispatches: snapshot-only runs collect only; jamf-cli-only runs
  collect + generate without CSV; jamf-cli-full and csv-assisted run collect
  + generate with the newest CSV from `csv-inbox/`. New
  `testNativeSingleWriteRoundTripsAllRunModes` covers every case in
  `Schedule.RunMode.allCases`.

- **OS adoption charts no longer split same-version device counts across trailing-zero variants** (PR-17): Jamf MDM rows sometimes record OS version as `26.4` and sometimes as `26.4.0` for the same release; the adoption-chart timeseries builders treated them as distinct columns, splitting one population across two lines. `ChartGenerator` now normalizes versions at read time — trailing `.0` patch components are stripped while preserving at least `major.minor`, so `26.4.0 → 26.4` but `26.0.0 → 26.0` (and `26.4.1` is left alone). Applied to both the CSV-sourced (`_build_os_timeseries`) and jamf-cli JSON-sourced (`_build_inventory_summary_timeseries`) paths so the chart is consistent regardless of source. Historical archived snapshots benefit retroactively without re-export.

### Added

- **`snapshot-only` schedule mode now updates the Trends summary** (PR-20, macOS app):
  `ReportEngine.collect` emits `summary_<today>.json` after the collection
  loop completes — previously this only happened inside `generate()`, so a
  snapshot-only schedule collected fresh data but never advanced the Trends
  page. The first-run-of-day skip from PR-18 still applies (a same-day
  summary file is not overwritten); operators investigating "I ran twice and
  Trends only moved once" see the `[info] summary_<today>.json already exists`
  log line and know why. The Schedules form description
  (`Schedule.RunMode.snapshotOnly.displayDescription`) updated accordingly:
  "Runs jamf-cli pro collect, archives JSON snapshots, and updates the
  Trends summary. Does NOT generate a workbook."

- **`jamf_cli.collect_skip` config option for excluding expensive report types from `collect`** (PR-16): Set `jamf_cli.collect_skip: [update-status, update-device-failures]` (or any of `patch-device-failures`, `profile-status`, `update-status`, `update-device-failures`) in `config.yaml` to skip those per-device-heavy queries during live collection. Targets on-prem Jamf Pro instances where these reports stall the server. Skipped commands log `[skip] <label>: excluded by jamf_cli.collect_skip` so operators see exactly what was excluded. Underscores and hyphens are interchangeable in values. Core inventory commands (computers, security, EAs, etc.) always run because the primary report sheets depend on them.
- **Per-LaunchAgent-run partial-status summaries + manifest coverage for `snapshots/computers/summaries/`** (PR-11, threat-model T-12): `cmd_generate` invoked from `cmd_launchagent_run` now emits a per-log `summary_<log_filename>.json` carrying the run's `status` field. The Swift `RunHistoryService.isPartialRun` and `LaunchAgentService.checkSummaryFileForPartialStatus` previously read a file that no producer wrote (BACKLOG MEDIUM-3); they now have a real producer AND verify the file's SHA-256 against a sibling `manifest.json` before trusting `status`. Tampered or corrupt summaries fall back to the existing `[partial]` log-marker scan rather than silently misreporting the PARTIAL pill. Daily `summary_YYYY-MM-DD.json` writes ALSO produce a manifest now — closes the integrity gap PR-7 left open for trend summaries.
- **T-13 integrity envelope for Generated Reports** (PR-12, threat-model T-13):
  Every generated `.xlsx` now ships with a `<basename>.xlsx.sha256` sidecar
  in `shasum -a 256` output format, so recipients can verify the file with
  `shasum -a 256 -c <basename>.xlsx.sha256` from the report directory.
  Generated HTML reports embed a `<meta name="report-sha256" content="...">`
  tag in `<head>` and a visible source-fingerprint footer with the
  verification procedure. The macOS app's "Report ready" toast surfaces the
  first 12 hex chars of the hash; the Generate sheet's completion banner
  shows the per-artifact fingerprint with a click-to-copy button for the
  full 64-character digest. Python and Swift emitters produce identical
  envelope structure.
- **`jamf_cli.require_manifest` config option + AuditView "Unverified snapshot" warning card** (PR-10, threat-model T-11): Set `jamf_cli.require_manifest: true` in `config.yaml` (or toggle "Require snapshot manifest" in Configuration → jamf-cli Cache) to hard-fail on snapshot integrity violations — missing manifest entries, SHA-256 mismatches, or absent `manifest.json` files. Equivalent to passing `--strict-manifest` on every invocation. The macOS app's AuditView now surfaces a warning card listing the count and breakdown of unverified snapshot directories regardless of the config setting, closing the "manifest absence = silent pass" gap from PR-7.
- **`LICENSE`** (MIT), **`NOTICE.md`** (Jamf/Apple trademark and non-affiliation notice), **`THIRD_PARTY_NOTICES.md`** (Sparkle, ZIPFoundation, jamf-cli, Chart.js, Python deps): canonical files at the repo root; mirrored copies in `app/Sources/JamfReports/Resources/` for in-app loading.
- **`BACKLOG.md`**: project-visible backlog of deferred review findings. Items are added when valid but out of scope for the current change, removed in the same commit that fixes them. Pointer notes added to `CLAUDE.md` and `AGENTS.md`.
- **`Acknowledgements…` menu item** (macOS app, application menu): opens a window with three tabs — License, Trademark Notice, Third-Party Notices — driven by `Bundle.module`-loaded resource files. Selectable, accessibility-labeled text.
- **`EmptyStateView`** (macOS app, shared component at `Theme/EmptyStateView.swift`): generalizes the Compliance Posture screen's empty-state pattern (optional icon + title + message + optional primary action). Retrofitted Compliance Posture (canonical usage) and Devices view. Includes accessibility hooks and `#Preview` variants for design verification. Now also accepts an optional `commands: [String]` parameter that renders a list of mono command-line examples above the action button.
- **`Theme.Severity` ramp** (macOS app, `Theme/ThemeSemanticTokens.swift`): paired `inApp` / `export` / `pillTone` / `systemImage` accessors for critical / high / medium / low. Drives Protect alerts-by-severity bars, severity Pills, the export canvas variants, and the new color-blind-safe icon redundancy in Phase 5.3.
- **`Theme.ChartPalette.osVersionInApp` and `osVersionExport`** (macOS app, `Theme/ThemeSemanticTokens.swift`): matched 8-entry palettes consumed by Security Posture `osChart` (in-app) and `SecurityPostureOSDonutExport` (light canvas) so the OS donut now looks the same when exported as on-screen.
- **`DataTableHeader` / `DataTableRow` / `DataTableColumn`** (macOS app, `Theme/Components.swift`): shared table primitives for hand-rolled tables that can't use SwiftUI `Table` (e.g. multi-line truncated rows). `DataTableColumn.width` is `CGFloat?` — `nil` means flex. PolicyProfileView (findings + profiles) and UpdatesView (failed plans + error devices) consume these instead of three independent table dialects.
- **`Theme.Text` / `Theme.Hairline` / `Theme.Surface` contrast-aware accessors** (macOS app, `Theme/ThemeSemanticTokens.swift`): helpers that bump foreground / hairline / surface opacity when `colorSchemeContrast == .increased`. Used in Pill, Sparkline, EmptyStateView, Sidebar, and StatusBar so the app responds to macOS *System Settings → Accessibility → Display → Increase Contrast* by gaining weight rather than recoloring.
- **`accessibility-audit.md`** at the repo root: WCAG 2.1 contrast matrix for every (foreground, background) text pair in the dark theme. Documents methodology, identifies 8 failing pairs across 5 token roles, and proposes minimal token tweaks. The proposed tweaks were applied in a follow-up commit (Pill `.muted` / `.warn` / `.danger` fg, `tealBright`, `fgDisabled`) — all rendered failures now clear AA Normal at 10.5 pt.
- **`build-pkg.sh`** (macOS app): distribution-style `.pkg` installer. Reuses the signed `.app` from `build-app.sh`, installs to `/Applications/JamfReports.app`, beta-aware filename naming (`JamfReports-2.0.0-beta10.pkg` vs `JamfReports-2.0.0.pkg`), team-ID-based Developer ID Installer cert resolution, `pkgutil --check-signature` verify-after-sign, `notarytool submit --wait` + `stapler staple` on release builds.
- **`build-dmg.sh`** (macOS app): consolidated `.dmg` builder paralleling `build-pkg.sh`. Auto-detects marketing + build version from `Info.plist`, beta-aware filename naming, team-ID-based Developer ID Application cert resolution, hard-fail on missing release identity, `notarytool` + `stapler` on release builds.
- **`docs/GLOSSARY.md`**: canonical reference for Apple-platform, Jamf, and jamf-reports-community vocabulary. Disambiguates overlapping terms (smart vs static group, scope vs target, blueprint vs config profile, MDM command vs declaration, ADE vs DEP) and defines project-specific terms (workspace, profile slug, refresh tier, ReportEngine, TrendStore, Compliance Band, Risk Score, Security Score, Stability Index). Pattern inspired by jamf-cli PR #199; lightweight version without the `docs/solutions/` postmortem archive.
- **Chart PNG export across the new dashboards** (macOS app): Security Posture, Compliance Posture, Updates, Mobile Fleet, Protect, and Extension Attributes each gained an Export PNG button next to their primary chart. The export pipeline (`DashboardChartExport`) renders a fixed 848×448 light-mode canvas with consistent serif title + monospaced kicker + footnote framing so every saved PNG looks like it came from the same template.
- **X-axis label scaling in Trends** (macOS app): trend chart x-axis tick density now scales with the selected range (7d / 14d / 28d / 56d strides for w4 / w12 / w26 / w52, and `.automatic(desiredCount: 8)` for All). Labels switch between "Apr 1" → "Apr '26" → "2026" formats so wider ranges no longer collide.
- **Per-EA memory bounds in the Extension Attributes service** (macOS app): the EA dashboard's underlying service now pre-aggregates raw `ea-results` rows in a single streaming pass. Peak memory is bounded by `O(devices + distinctValues)` instead of `O(rows)`, so a 54,000-row fleet (600 devices × 90 EAs) no longer holds the full row array on the snapshot. Top 20 values per EA are kept; the tail rolls into an `Other` bucket with a "Top values shown per EA" footnote when the row count exceeds 25,000.
- **Nine new dashboards** (macOS app): Security Posture, Compliance Posture, Patch, Updates, Policy/Profile, Extension Attributes, Outreach, Protect, and Mobile Fleet. Each reads existing cached `jamf-cli` JSON snapshots — no new API commands are issued. The Sidebar gains POSTURE, OPERATIONS, and FLEET groups; core tabs stay pinned at the top.
- **Configurable Security Score** (macOS app, Config → Scoring tab): The v3.5 weighted security score (FileVault 15, SIP 15, Firewall 15, CrowdStrike 10, mSCP 20, XProtect 5, CVE 15, Secure Boot 5) is now exposed as editable weights and persisted in `config.yaml`. Risk Scoring factors are configurable in the same tab. Defaults reproduce the legacy script's output within ±0.5 points for the same data.
- **Sidebar visibility controls** (macOS app, Settings → Sidebar Visibility): Hide dashboards you don't use; core tabs (Overview, Devices, Sources, Settings) cannot be hidden. Preferences persist via `@AppStorage` per machine.
- **Default trend range** (macOS app, Settings → Data & Charts): A new picker lets you set 4/12/26/52 weeks (or All) as the default for Overview and Trends. Default is now 4 weeks. The picker in Trends still lets you override per-session.
- **Skip expensive collections** (macOS app, Settings → Data & Charts): Optional toggle that omits four per-device commands (`ea-results --all`, `patch-status --scan-failures`, `update-status --scan-failures`, `device-compliance`) from manual GUI refreshes to spare on-prem Jamf servers. LaunchAgent-scheduled collects always run the full set.
- **Legacy fleet-health history import** (macOS app, Settings → Import legacy history): Reads `fleet_health_metrics_history.json` written by `jamf_reports_cli_v3.5.py` and seeds the workspace's `summaries/` directory with translated `summary.json` snapshots so Trends has historical depth from day one.
- **Complete rewrite as a native macOS application**: The project has been rewritten from the ground up as a native Swift/SwiftUI application for macOS 14+. The original single-file Python CLI (`jamf-reports-community.py`) served as the reference implementation; all report generation, data collection, scheduling, and config management logic has been ported to Swift and is now compiled into a self-contained `.app` bundle. Users no longer need Python, pip, or any third-party runtime installed — the app ships with everything required. The Python CLI remains in the repository as a standalone tool for headless or non-Mac environments.
- **Python-free operation** (macOS app): All interactive GUI paths — collect, generate, generate HTML, export inventory CSV, school collect, school generate, config check, workspace init, and LaunchAgent scheduling — now run exclusively through the native Swift engine (`ReportEngine`). Users no longer need Python installed or a bundled Python runtime for any supported workflow. The only remaining jrc dependency is `backup()` and the multi-profile LaunchAgent fan-out — both are limited to edge-case automation flows and will fail fast with a clear error if jrc is absent.
- **Auth fail-fast guard** (macOS app): `CLIBridge.collect()` and `collectThenGenerate()` now probe `jamf-cli pro auth token` before launching any API commands. A profile with invalid or unconfigured credentials returns exit code 3 (HTTP 401) and emits an actionable error line, preventing redundant subcommand launches against an unauthorized tenant. Jamf School profiles (`auth-method = apikey`) bypass the probe automatically.
- **Dynamic Platform Gateway status** (macOS app, Config → Platform API tab): When the active workspace profile uses Platform Gateway auth (`auth-method = platform`), the tab now shows a green "Platform Gateway profile active" callout instead of a static setup instruction, with the profile name and a prompt to enable the Platform API toggle.
- **VoiceOver / Accessibility** (macOS app): All Swift Charts views — Trends metric charts, hero trend chart, compliance distribution, security posture comparison, OS version distribution, and fleet stability — now expose full VoiceOver chart navigation via `AXChartDescriptorRepresentable`, allowing VoiceOver users to swipe through individual data points. Interactive controls (`PNPButton`, `PNPToggle`, `SegmentedControl`, `StatTile`, sidebar nav items, workspace chip, agent cards, metric pills) have composed accessibility labels that include badges, counts, and trend direction. Decorative elements (sparklines, legend dots, progress bar fills, hover chevrons) are hidden from the accessibility tree.
- **Design polish** (macOS app): Visual refinements across eight views:
  - *Sidebar*: Per-profile gradient avatar (hue derived from profile name); compact-mode icon sizing improved; workspace chip shows available workspace count; nav items include badge counts in their accessibility labels.
  - *Titlebar*: Status dot animates when jamf-cli is missing; demo mode chip is tinted gold; hover popover reveals the resolved jamfCLI binary path.
  - *Overview*: Stat tiles with downward trends receive a danger tint and border; security agent cards below 80% coverage show a warn-tinted progress bar and gap count; drill-down cards animate border and shadow on hover.
  - *Fleet Overview*: Profile cards with issues show a warning-colored left-edge accent stripe; first-time profiles (no summary yet) use a dashed border instead of a solid hairline.
  - *Devices*: Search field shows a gold focus ring on focus; stale devices badge the Last Contact column with a clock icon; responsive column hiding collapses low-priority columns at <1200 pt; security status displayed as colored pills.
  - *Trends*: Metric pills show a leading accent bar on selection, a micro-sparkline of the last 8 values, and a pulsing danger wash on declining metrics; the hero chart value gets a metric-colored shadow and a date-range label; archive bars show date and value in a hover tooltip.
  - *Audit*: CRITICAL findings get a red left-edge accent bar; affected-count shown as an inline proportional bar; newly detected findings animate in with a "NEW" badge; resolved findings show a strikethrough with an ok-colored checkmark.
  - *Schedules*: Next-run tile shows a 60 s-tick countdown with a semicircular progress arc; run log is terminal-styled with per-line color coding for errors, warnings, and success keywords, and auto-scrolls only when already at the bottom.
- **Protect Computers Sheet**: New 14-column sheet listing Jamf Protect-managed Macs (hostname, serial, UUID, model, OS version, plan, tags, web protection / full disk access status, insights pass/fail/unknown counts, connection status, last connection). Driven by `jamf-cli protect computers list`. Gated by `protect.computers.enabled` (default off). Marked Experimental until pagination shape is verified against a live tenant.
- **Protect Alerts Sheet**: New 11-column sheet listing Jamf Protect alerts (created, severity, status, event type, computer, serial, plan, analytics, actions, tags, UUID). Driven by `jamf-cli protect alerts list`. Gated by `protect.alerts.enabled` (default off).
- **Protect Insights Sheet**: New 10-column sheet listing Protect compliance insights (label, section, description, pass/fail/none counts, enabled, tags, CIS IDs, UUID). Driven by `jamf-cli protect insights list`. Gated by `protect.insights.enabled` (default off).
- **Device Lookup screen** (macOS app): Search by serial, hostname, asset tag, or device ID; resolves via `jamf-cli pro device <id>` and renders the full DeviceDetail. Includes "Open in Jamf Pro" deep-link to the corresponding console page.
- **Sparkle Auto-Update**: Integrated Sparkle 2.x. "Check for Updates…" menu item under the application menu. Configuration via `Info.plist` (SUFeedURL → GitHub Pages appcast, EdDSA-signed). Installer is a no-op until the EdDSA public key is set in the build script (safe-by-default).
- **APIScope Toggle UX** (macOS app): The per-profile API scope chip in Data Sources is now an interactive Menu — Limited↔Full Admin selectable inline, with a confirmation dialog required for elevation to Full Admin.
- **Console Deep-Link Helpers**: Typed `consoleURL(...)` helpers cover computers, mobile devices, smart/static computer groups, policies, and computer/mobile config profiles, plus String-id overloads. Replaces ad-hoc URL construction across views.
- **jamf-cli First-Time Installer**: `JamfCLIInstaller.firstTimeInstall()` direct-downloads the latest GitHub release into `~/.local/bin/`. SHA256 verification against the release's `*.checksums.txt` is mandatory — install is refused if the checksums file is missing or the digest does not match. Existing upgrade path now flows through the same verification.
- **Platform Health Audit Sheet**: New `Platform Health` sheet driven by `jamf-cli pro audit --checks platform`. Surfaces seven platform-specific health checks (undeployed blueprints, blueprint deployment failures, stale blueprints, compliance benchmarks needing updates, MONITOR-mode benchmarks, empty platform scope, devices with failed DDM declarations). Gated by `platform.enabled` and `platform.audit_platform.enabled`.
- **School DEP Devices Sheet**: New sheet listing DEP-enrolled devices (Serial Number, Model, Color, Status, Profile Name, Device Name). Driven by `jamf-cli school dep-devices list`.
- **School iBeacons Sheet**: New sheet listing configured iBeacons (Name, UUID, Major, Minor, Description). Driven by `jamf-cli school ibeacons list`.
- **Jamf Protect Plans Sheet**: New 14-column `Protect Plans` sheet showing plan name, threat-prevention strategy, custom engine config, exception/analytic sets, and telemetry version per plan. First step of Protect feature graduation from experimental.
- **Protect Bridge**: New `ProtectCLIBridge` class graduates the experimental Protect plumbing into a first-class subclass of `JamfCLIBridge`. Includes auth-detection (`is_protect_available()`) and structured error classification (`_classify_protect_error()`).
- **CI Automation**: Added Dependabot configuration plus weekly workflows that watch for new jamf-cli releases and Python versions.
- **Jamf School Reporting**: Full support for Jamf School inventory and device group sheets in Python reports.
  - New **Compact Inventory**: CSV-driven inventory focusing on stale-status classification.
  - New **Sorted Device Groups**: Bridge-driven group reporting sorted by device count with multi-location support.
- **Native macOS App**: Introduced a complete SwiftUI-based desktop application for fleet overview, detailed inventory, health audits, and automated schedule management.
- **Health Audit Improvements**: New audit views in the macOS app for identifying stale devices, empty groups, and hygiene findings from jamf-cli data.
- **Group Hygiene Reporting**: Automated detection and reporting of unused or misconfigured device groups.
- **Config Management**: Expanded `ConfigView` in the macOS app to manage stale device thresholds, run retention policies, and jamf-cli cache settings.
- **Inbox Management**: Wired `SourcesView` to the workspace inbox for real-time monitoring and one-click clearing of generated reports.
- **Automated Scheduling**: Atomic LaunchAgent management for scheduled report runs across multiple profiles.
- macOS app **Fleet Overview** tab now aggregates initialized profile workspaces
  from historical summary JSON, showing per-profile device count, Stability
  Index, and last successful run without exposing local configuration paths.
- macOS app **Overview** and **Fleet Overview** surfaces now support drill-down:
  KPI cards, macOS distribution, failing rules, security-agent cards, recent
  activity, and fleet profile cards open detail pages with relevant metrics and
  actions to jump to related tabs.
- Added **Stability Index** trend metric as a management-level health score,
  weighted from compliance, patch posture, and inverse stale-device pressure.
- Added **Interactive Breadcrumbs** to all page headers; users can now click the
  parent view name (e.g., "OVERVIEW") to navigate back or switch tabs.
- Added **Keyboard Shortcuts** for core app actions: `Cmd + R` (Refresh),
  `Cmd + F` (Find/Search), and `Cmd + D` (Toggle Demo Mode).
- Added **Live Status Bar** to the app footer, providing real-time feedback and
  CLI output (e.g., "Collecting jamf-cli snapshots...") during long-running tasks.
- Added **Toast Notifications** for background task completion; a brief popup
  now confirms successful report generation or audit completion across all tabs.
- Added **Context Menus** (right-click) to device rows in Detailed Inventory and
  Overview tables with actions for "Open in Jamf Pro", "Copy Serial", and "Copy User".
- Added **Interactive Column Sorting** to inventory and audit tables.
- **Security Hardening**: Hardened `ProfileService` path safety with direct-child workspace root validation to prevent symlink-based traversal.
- **App Responsiveness**: Improved `DirectoryWatcher` responsiveness by reducing debounce interval and ensuring MainActor thread safety for Swift 6 concurrency.

### Changed

- Tracked jamf-cli dependency updated to v1.17.0. No code changes required.
  Notable upstream changes since v1.14.0:
  - v1.15.0: Spec-generated platform commands and bulk delete functionality added.
  - v1.16.0: New `jcds download <fileName>` and `jcds sync --dir <path>` commands for
    Jamf Cloud Distribution Service — not used by the app.
  - v1.16.1: Nil-safety fix for device platform section fields — picked up by the app's
    v1.16.1 minimum version floor (see entry below).
  - v1.17.0: New `--compact` flag (token-efficient output), `--select` flag (multi-field
    projection), and `doctor` diagnostic command. Inventory preload CSV export and app
    store app backup capabilities added. Classic API extended with ebooks, user-groups,
    and VPP scope support. Destructive commands annotated with `jamf:destructive`.
    None of these changes affect commands or flags used by the app.
- **Partial-success status for sheet-write failures** (Python CLI + macOS engine): When one or more sheets fail to write during `generate` / `school-generate`, the run now emits `status: "partial"` in `summary.json`, lists the failed sheets in `sheets.failures` (with `{"sheet": name, "error": "<Type>: <message>"}` entries), populates `counts.sheet_failures`, and logs `[partial] Report written with N sheet failure(s)` instead of the plain success line. Previously, sheet exceptions were swallowed and the run reported `status: "ok"` regardless. **Operator note**: tenants whose CSV column mapping has a pre-existing tolerated miss (`KeyError`/`ValueError` on a non-required sheet) will now surface as `status: "partial"` rather than silently skipping. Required sheets (e.g. Compliance with `compliance.enabled: true`) still raise `SystemExit` and fail the run as before. Required sheets are evaluated by `CSVDashboard.required_failures` on the Python side and by the `SheetSkippable`-conforming error protocol on the Swift side; non-conforming throws land in `failures` rather than being swallowed.

- **Design review pass across the dashboards** (macOS app):
  - *Pills never wrap mid-word*: `Pill` now applies `.lineLimit(1)` + `.fixedSize(horizontal: true, vertical: false)` internally. `CRITICA / L`, `INVESTIGAT / ING`, and `INAC / TIVE` no longer render across two lines in Protect and Updates tables. Column widths bumped where the underlying label is genuinely longer (Protect status 88 → 104 pt, Updates state 120 → 138 pt).
  - *EmptyStateView icon is visible*: foreground swapped from `hairlineStrong` (white @ 0.12) to `fgMuted` so the icon reads as a visual anchor rather than a ghosted artifact. The `NSAccessibility.announcementRequested` on-appear announcement was dropped — tab labels already speak themselves and `NSApp.keyWindow` can be nil for non-focused windows.
  - *Severity bars and severity Pills now agree per row*: Protect's `Alerts by Severity` card was using a different ramp from its own severity Pills below it (Medium read bright yellow on the bar, gold-brown on the Pill). Both routes now go through `Theme.Severity.{critical,high,medium,low}.inApp`, so the row colors line up.
  - *Status colors come from Theme tokens, not inline hex*: `PatchView.complianceColor` / `actionColor`, `OutreachView.daysSinceColor`, and `CompliancePostureView.barColor` now reference `Theme.Colors.danger / warn / goldBright / ok` instead of duplicating the same hex literals.
  - *OS-version palette is shared between in-app and export*: Security Posture's macOS donut and its PNG export now consume `Theme.ChartPalette.osVersionInApp` / `osVersionExport`. Exporting the chart no longer produces unexpectedly different slice colors. MobileFleet's iOS version chart aligns its export against the same palette's lead color.
  - *Empty states use one component, one icon weight, one padding*: nine hand-rolled empty states across Security Posture, Compliance Posture (already canonical), Outreach, Patch, Updates, Policy/Profile (both findings and profiles), Extension Attributes, Mobile Fleet, and Protect were converted to call `EmptyStateView(...)`. Each screen now picks a domain-appropriate SF Symbol. Protect's "no Protect data" state includes the four `jamf-cli protect *` commands that would populate it.
  - *KPI grid columns are aligned across screens*: every `LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, …)])` was raised to `220` to match the Overview screen, and `ProtectView.kpiGrid` switched from a fixed-3-columns layout to the same adaptive form. At 960 pt window width, Overview and Security Posture now show the same tile widths.
  - *"Showing N of M" copy unified*: every SectionHeader trailing that signals a row cap now reads `"\(shown) of \(total)"`; bare counts and "Showing first N" variants were removed. `PolicyProfileView.findingsCard` previously capped at 100 silently — the cap is now annotated.
  - *SectionHeader gained a `trailingValue:` slot*: passes a sentence-case string through `fg2` color without uppercase tracking. Used in Extension Attributes' Value Distribution card header where the EA name (e.g. "FileVault Status") was being rendered as "FILEVAULT STATUS" in tracked mono. The existing `trailingTag:` slot retains the uppercased Kicker behavior for actual tags.
  - *Hand-rolled tables unified*: Policy/Profile (findings + profiles) and Updates (failed plans + error devices) now consume new `DataTableHeader` / `DataTableRow` / `DataTableColumn` primitives from `Theme/Components.swift`. Column widths are preserved; row-level styling (per-row backgrounds, multi-line truncated error cells) carries through unchanged. Reduces three table dialects to one.
  - *Extension Attributes export header*: removed the redundant `Spacer()` between SectionHeader and Export PNG button — SectionHeader already has an internal Spacer, so the trailing tag and the export button were misaligned. Same view also drops the duplicate `.onTapGesture` on EA coverage rows.
  - *Patch titles table gains an Export PNG button*: routed through `DashboardChartExport` with a new `PatchTitlesTableExport` light-canvas view (848 × 448 pt). Matches the export pattern already established on Compliance Posture, Security Posture, Updates, Mobile Fleet, Protect, and Extension Attributes.
  - *Export canvas templates unified*: `DashboardExportCanvas` and `ExtensionAttributesView.BarChartExportView` no longer build two different headers — both consume a shared `DashboardExportHeader` so a strip of saved PNGs from different dashboards looks like one set. Export timestamps now include the timezone (`yyyy-MM-dd HH:mm 'UTC'`).
  - *Sidebar polish*: nav rows tint background `Color.white.opacity(0.04)` on hover (matches the workspace chip pattern); `avatarHue(for:)` spreads adjacent letters and offsets clear of the brand gold band so two profiles starting with `A` and `B` no longer pick near-identical hues; the avatar `accessibilityLabel` uses the same two-letter monogram the avatar visually shows.
  - *Protect date formatting*: rows like `731d ago` now render as the absolute date once the span exceeds 60 days. Under 60 days uses `RelativeDateTimeFormatter` with abbreviated units.
  - *Protect KPI subs*: Web Protection / Full Disk Access / Connected tiles read `"10 of 12 (83%)"` instead of a bare `"83%"`, matching the Security Posture KPI tile convention.
  - *Protect subtitle*: falls back to `criticalAlerts + highAlerts + mediumAlerts + lowAlerts` count fields when the `alerts` array is empty but the counts are present — fixes the case where demo data and partial real data produced a subtitle ("12 computers") that didn't match the cards rendered below.
  - *SecurityPostureView Action Items*: the always-zero P2 "Reserved" tile was dropped from the action items card. The card now shows only P0 and P1.
  - *StatTile sparkline color follows the delta*: when the delta direction is `.down` the sparkline defaults to `Theme.Colors.danger`; on `.up`, `Theme.Colors.ok`; on `.flat`, gold. Eliminates the case where an upward gold sparkline was drawn next to a red downward delta on the same tile.
- **Accessibility — respect macOS system settings** (macOS app):
  - *Increase Contrast*: Pill background opacity, Sparkline gradient fill, EmptyStateView message text, Sidebar caption text, and workspace chip background now react to `@Environment(\.colorSchemeContrast)` and gain weight when the system setting is enabled. No light-mode inversion — dark mode is preserved; tokens just step up.
  - *Reduce Motion*: TrendsView pulse animations on bad-trend pills and archive bars now respect `@Environment(\.accessibilityReduceMotion)`. Under reduce-motion, the danger wash and gold pulse are static while the underlying signal (icon, color, text) remains visible.
  - *Reduce Transparency*: Sidebar, StatusBar, and GlassPane swap `.regularMaterial` / `.ultraThinMaterial` for opaque `Theme.Colors.winBG2` when `@Environment(\.accessibilityReduceTransparency)` is on. GlassPane additionally swaps to a stronger border when reduced so the elevation cue survives.
  - *Color-blind redundant encoding*: RunsView and SchedulesView status pills now pair color with an icon (`checkmark` / `exclamationmark` / `xmark`) so last-run status remains identifiable under deuteranopia. Protect severity Pills, Protect alerts-by-severity bars, Policy/Profile findings Pills, Compliance Posture controlBar labels, Patch compliance numerics, and Updates statusBar labels use the same pattern (critical / high / medium / low mapped to SF Symbols). Severity remains identifiable for users with deuteranopia or under macOS *Display → Color Filters → Deuteranopia*.
  - *WCAG 2.1 contrast pass*: dark-theme tokens that failed AA Normal at 10.5 pt were lifted to pass. Pill `.muted` fg moved from `fgMuted` (2.40:1) to `fg2` (5.50:1); Pill `.warn` fg `#FFB340` → `#FFCE7A` (3.82 → 4.59:1); Pill `.danger` fg `#FF8077` → `#FFA39A` (3.77 → 4.83:1); `tealBright` `#3A8A8A` → `#4FAAAA` (3.83 → 5.89:1); `fgDisabled` `#5A5A60` → `#8A8A90` (2.41 → 4.68:1). Log-line error/warn colors in `GenerateSheet` and `SchedulesView` and `PNPButton.danger` fg mirror the new Pill fg targets for consistency. The full matrix and methodology live in `accessibility-audit.md`.
  - *Dynamic Type for body text*: pinned `.system(size: ...)` calls for non-display body text were switched to SwiftUI semantic fonts (`.callout` / `.footnote` / `.caption` / `.caption.monospaced()`) across all 16 primary screens (OverviewView, ProtectView, SchedulesView, HealthCheckView, TrendsView, RunsView, and 10 others). Users on *System Settings → Displays → Larger Text* see body text, captions, and help text grow while the typographic identity (serif H1s, mono kickers, 32 pt numeric metrics, SF Symbols) stays anchored.
- **Theme tokens for log-line coloring** (macOS app, `Theme/Theme.swift`): Named tokens `dangerSoft` (`#FFA39A`) and `warnSoft` (`#FFCE7A`) replace inline hex literals for terminal-style log output in RunsView and SchedulesView. Ensures consistent coloring across live-output views and centralizes audit color maintenance.
- **Sidebar Surface tier on interact** (macOS app): Navigation row hover tint now uses `Theme.Surface.hover(contrast)` which bumps opacity when Increase Contrast is on. Workspace chip swaps to `Theme.Surface.interactive(contrast)` tier when engaged instead of clamped opacity > 1. Sidebar brand block truncates with `.lineLimit(1).truncationMode(.tail)` for long org names.
- **Schedules popover adaptive height** (macOS app, `SchedulesView`): Run-log popover changed from fixed `height: 260` to `minHeight: 200, maxHeight: 320` so it adapts on narrow windows without clipping.
- **Schedules exit-code pill always shows code** (macOS app, `SchedulesView`): Changed from showing "DONE" / "EXIT 0" to always displaying "EXIT N" with tone and icon based on exit code (0 → teal+checkmark, non-zero → danger+xmark).
- **RunsView empty state and context menu** (macOS app, `RunsView`): Hand-rolled empty state migrated to `EmptyStateView` for consistency. Reveal button enabled unconditionally, falling back to run-history root when no run selected. Per-row right-click context menu now mirrors header (Copy log, Export log, Reveal in Finder).
- **TrendsView export unified** (macOS app, `TrendsView`): Chart export migrated to shared `DashboardExportCanvas` pipeline, eliminating 15+ inline hex-color literals. Metric display now renders flat-delta metrics as `"—"` in muted color instead of misleading `+0%`. Archive bar heights normalize to visible data range instead of metric maximum, making sparse trends visible.
- **ExtensionAttributesView empty-state icon** (macOS app, `ExtensionAttributesView`): Swapped icon from `tag` to `slider.horizontal.below.rectangle` to better convey user-defined data slots rather than mail labels.
- **Sidebar is scrollable** (macOS app): the left navigation column now wraps the section stack in a `ScrollView` so the SYSTEM section is reachable on 13" MacBook Pro screens. Compact-rail tray backdrop and workspace chip preserved.
- **Window min-width unified to 960pt** (macOS app, `JamfReportsApp.swift`): the static `minSupportedWidth = 960` constant (with a WCAG 1.4.10 docstring) and the actual `.frame(minWidth:)` were out of sync (the frame was 1200). Both now use the constant — the app is honest about supporting the documented breakpoint.
- **Overview KPI grid reflows on narrow windows** (macOS app): grid columns switched from `.flexible()` to `.adaptive(minimum: 220)` so tiles collapse to fewer columns at narrow widths instead of squishing into unreadable strips.
- **Trends chart Y-axis dynamically fits data** (macOS app): the hero chart's Y-domain now uses `min(metric.minY, dataMin)...max(metric.maxY, dataMax)`. The metric's `minY`/`maxY` constants are treated as a *minimum visible frame* (preferred when data is in-range), not a hard clamp. A Stability Index of 0% is now visible instead of disappearing below `minY: 40`; a Stale count of 101 is visible instead of clipping above `maxY: 60`.
- **Trend chart interpolation switched from `.catmullRom` to `.monotone`** (macOS app): Catmull-Rom splines can overshoot the data envelope between near-zero control points, producing visible "dips below zero" even though no actual data point was negative. `.monotone` (Fritsch-Carlson) provably stays within the envelope.
- **Trends title-bar subtitle reflects the active range** (macOS app): previously hardcoded to `"26W"` regardless of selection. The `Trends` tab subtitle and the picker selection are now both bound to the `@AppStorage("defaultTrendRange")` key, so the title bar shows `Trends / W4` when W4 is selected, etc. Side effect: picker selection persists across navigation.
- **Trends multi-line comparison chart Y-scale**: changed from hardcoded `30...100` to `0...100`. The previous range silently clipped any value below 30% (e.g. FileVault at 0%, early-deployment compliance).
- **Trends archive bar heights normalize to `metric.maxY`** (macOS app): the formula previously assumed a 0-100 percentage metric, producing nonsensical bar heights for raw-count metrics (Stale, Active Devices). Now normalizes against the metric's actual maximum.
- **Trends bad-trend pulse fires only on actual declines** (macOS app): the danger pulse animation previously fired on any non-positive delta, including `0` (flat trend or first-snapshot delta). Restricted to `delta < 0`.
- **Overview first-snapshot delta hides** (macOS app): when only one snapshot exists, the delta row showed `+0.0pp` / `+0` as if a real comparison was made. The tile now hides the delta row when fewer than two snapshots are available.
- **Sparkline lower bound clamped at 0** (macOS app, `Theme/Components.swift`): the Sparkline component normalized to `values.min()...values.max()`, allowing the visible baseline to sit below zero for percentage metrics with near-zero readings. The lower bound is now clamped to `max(0, values.min())`. Internal change; no caller updates needed.
- **`DailySummary` fields `fileVaultPct`, `osCurrentPct`, `patchPct` are now `Double?`** (macOS app, `SummaryJSONParser.swift`): previously non-optional `Double` with `0.0` initialization when source data was absent or failed to decode, making "no data" indistinguishable from a real 0%. Decoder uses `decodeIfPresent`; `ReportEngine` leaves them `nil` when absent; downstream consumers (`SecurityScoreCalculator`, `FleetOverviewView`, `TrendStore`, `Models.TrendSeries.stabilityIndex`) `guard let` / `if let` unwrap. Pulls one item out of `BACKLOG.md`.
- **`CFBundleVersion = 10`** (macOS app, `build-app.sh`): bumped from `2.0.0` to `10` to support the new beta-build naming. XML comment documents the Sparkle monotonic-build-number rule (never reuse, never reset, even across marketing-version changes). The comment ships inside the deployed `Info.plist`.
- **Sparkle appcast inputs validated** (`scripts/sparkle-appcast.sh`): the `VERSION` / `BUILD` / `CHANNEL` arguments are now strictly regex-validated at script entry. Allowed character sets are XML-safe by construction, so no downstream escaping is needed. A typo in a release variable can no longer produce a malformed appcast feed. The auto-discovery for the Sparkle `sign_update` binary now probes the actual Homebrew Cask locations (`/opt/homebrew/Caskroom/sparkle/.../bin/sign_update`, `/usr/local/Caskroom/sparkle/.../bin/sign_update`) rather than an unreachable `DerivedData` path.
- **`build-app.sh` codesign + version validation** (macOS app): `build-dmg.sh` and `build-pkg.sh` both now read `CFBundleShortVersionString` and `CFBundleVersion` from the built `Info.plist` and fail hard if either is missing or invalid. Release builds also `codesign --verify --deep --strict` the `.app` before staging — preventing an unsigned bundle from being wrapped in a signed DMG/pkg and submitted to notarization with a confusing failure.
- **Protect Bridge graduation**: `JamfCLIBridge.protect_*` shim methods (deprecated in v2.0) have been removed. Internal callers now construct a `ProtectCLIBridge` via `_build_protect_bridge(config)`, which honors the dedicated `protect.*` config block (`data_dir`, `profile`, `use_cached_data`) so Pro and Protect can target different tenants. `_protect_commands` / `_require_protect_command` likewise moved from `JamfCLIBridge` to `ProtectCLIBridge` where they always belonged.
- **Protect collect planner** now gates Protect snapshots on `is_protect_available()` — when Protect is unconfigured for the active profile, the collector emits a single `[skip]` line instead of a misleading auth error. The `cmd_check` Protect probe likewise replaces its placeholder-value heuristic with the same availability call.
- **Overview screen tile layout**: Stat tiles on the Overview screen now use a fixed-count flexible grid; previously, an asymmetric `minWidth` on the primary tile caused right-side tiles to collapse into single-character columns on live workspaces.
- **Titlebar breadcrumb is clickable**: The "Tab Name / SUBTITLE" path at the top of every screen now acts as a navigation control — clicking either segment pops the active tab's `NavigationStack` back to root.
- **Minimum supported jamf-cli is now v1.16.1** (raised from v1.14.0). Picks up the platform-section nil-guard in `pro device <id>` (jamf-cli PR #185). The pre-v1.4 patch-status `installed`/`total` shape is no longer parsed — only `on_latest`/`on_other` is supported. The older `update-status` shape (`summary`/`ErrorDevices`) is preserved pending live verification; `status_summary` remains the canonical path. Users on older versions must upgrade via Homebrew (`brew upgrade jamf-cli`). The app surfaces a notice in Settings when the installed version is below the floor rather than hard-failing — most code paths still work.
- **v1.6.0 Compatibility**: Updated patch and update-status parsers to support the new JSON schema introduced in jamf-cli v1.6.0.
- **Python Runtime**: Switched to pinned SHA256 verification for bundled Python runtime assets on both arm64 and x86_64 architectures.
- **Test Suite**: Expanded Swift test coverage for core services including `ConfigService`, `ProfileService`, `CSVInboxService`, and `LaunchAgent` management. Added negative path testing for security boundaries.
- **Date Robustness**: Reconciled Python date-handling logic to be more resilient to clock skew and diverse timestamp formats using UTC-aware pandas parsing across all school-related sheets.
- **Architecture Cleanup**: Removed deprecated `_write_device_groups` and `_write_device_inventory` in favor of more specialized methods.
- Compliance failure-count parsing is now fail-closed: `strict_parse_failures()`
  raises `ValueError` on non-numeric values (empty, "N/A", "null", etc.) instead
  of silently treating them as 0. In the summary JSON path, unparseable values
  cause `compliancePct` to be omitted (GUI shows "no data") rather than exiting.
  CSV sheets log unparseable details and exclude those rows from compliance bands.

### Fixed

- **`api_key` / `apikey` leaked in free-text log lines** (Python CLI + macOS app, `LogRedactor`): both `LogRedactor` implementations already redacted `api_key` / `apikey` JSON keys in `redact_json` walks, but the `_SECRET_PATTERNS` / `patterns` table omitted the matching free-text regex. A jamf-cli echo of an API key in a log line (e.g. `apikey="..."`) survived redaction. Both redactors gained a generic `api_?key` pattern (case-insensitive, 8-char value floor mirroring `client_secret`); diagnostic bundles and run logs now scrub both spellings.
- **`patchPct` written as `0.0` floor when `patch_status` failed** (Python CLI, `_emit_summary_json` CSV path): the CSV branch initialized `patch_pct = 0.0` and unconditionally wrote `patchPct: 0.0` to `summary.json`, even when `bridge.patch_status()` raised. The Swift `DailySummary.patchPct` is `Double?`, so the `0.0` was treated as a real data point and plotted as a 0% trend floor. The key is now omitted (matching the existing `compliancePct` treatment and the Swift `Double?` shape); the warn message now reads "patchPct omitted (no data)".
- **`isTrustedJamfCLIExecutable` skipped the M-01 codesign gate** (macOS app, `LaunchAgentWriter`): the helper used by `runMultiNow`'s legacy multi-profile path verified the jamf-cli candidate by path identity (`ExecutableLocator.locate` + `sameResolvedPath`) but not by signature. A tampered jamf-cli planted at the located path would have satisfied the path check and launched. The helper now runs `CLIBridge.codesignGate` after the path check, closing the 4th spawn site identified in the M-01 review. A `_testLocatedOverride` parameter (test seam only) lets unit tests reach the gate without owning the real binary path.
- **Multi-profile "Run now" failed with "paths are not trusted"** (macOS app, `LaunchAgentWriter`): `nativeMultiWrite` omitted the `WorkingDirectory` key, but `runMultiNow`'s `isExpectedMultiWorkingDirectory` guard required it to match `ProfileService.workspacesRoot()`. Every multi-profile Run now click failed. Three coordinated changes: writer now emits `WorkingDirectory`; validator accepts a missing key (self-heal for pre-existing plists); the compound guard was split so the error message names which path failed (stdout / stderr / WorkingDirectory) and tells the user to re-save the schedule. The self-heal now emits a `[warn]` line so the substitution isn't silent.
- **Config decode failed on every collect/generate** (macOS app, `YAMLCodec`): the parser required block-sequence list items at `indent + 2`, but config.yaml files written by `workspace-init` and edited in the GUI use YAML's compact form where list items share the parent key's indent (valid YAML; PyYAML/ruamel accept it). The result was that `security_agents`, `custom_eas`, and similar lists silently decoded as empty mappings, producing "Config decode failed (config.yaml): The data couldn't be read because it isn't in the correct format" on every run while the engine quietly fell back to default config — so generated reports were missing custom EAs and security agents. New `peekBlockSequenceIndent` lookahead finds sequences at either indent. As a corollary, an empty `key:` followed by a sibling key now decodes as `null` rather than `{}` (which previously failed Array decode for any Optional list field).
- **`pro scripts list` JSON blob leaked into the live run log** (macOS app, `CLIBridge.runAndCapture`): stdout was being both captured for the report engine and streamed to `onLine`. For commands like `pro scripts list --output json` whose stdout is a 360 KB JSON payload, the full body (including embedded script source) flooded the live console — including a complete FileVault decrypt script body bleeding into stderr lines from other profiles. stdout is now captured silently; jamf-cli progress messages continue to stream via stderr.
- **Schedules live output was not selectable / copyable** (macOS app, `SchedulesView.RunLogConsole`): the `Text` lines in the live-output popover gained `.textSelection(.enabled)` and the popover header gained a Copy-all button that joins every line into the clipboard. Users can now copy error text for triage without screenshotting.
- **Recent runs had no Reveal-in-Finder action** (macOS app, `RunsView`): the header gained a Reveal button (next to Refresh / Copy log / Export) and each run row gained a right-click "Reveal log in Finder" context menu. Both route through `SystemActions.reveal`, which is now `@discardableResult` returning `Bool` and logs via `AppLogger.ui.warning` when the path falls outside the allow-list, giving operators an observable signal for the previously silent no-op.
- **"Run now" on Schedules always failed with "stdout log" path error** (macOS app, `LaunchAgentWriter.nativeManualRunPlan`): the validator built the expected `StandardOutPath` via `expectedMultiLogURL(filename: "").deletingLastPathComponent()`, which stripped the per-label folder — comparing `~/Library/Logs/JamfReports/stdout.log` against the writer's actual `~/Library/Logs/JamfReports/<label>/stdout.log`. The validator now uses the helper correctly, passing the actual filenames. Test gap (round-trip writer↔validator) tracked in `BACKLOG.md` since the relevant functions are `private`.
- **Trends chart and Overview sparklines no longer dip below zero** (macOS app): see the *Changed* section for the combined fix — `.catmullRom` → `.monotone` interpolation plus dynamic Y-domain in the hero chart plus Sparkline lower-bound clamp plus optional metric types in `DailySummary`. The "below zero" visual symptom had four compounding root causes; all four are addressed.
- **Trends title bar shows the active range** (macOS app, `ContentView.swift`): previously hardcoded `"26W"` regardless of picker selection.
- **Privacy-modifier convention** (macOS app, logging): `AppLogger` calls added in the recent review pass — `DashboardChartExport.run`, `DashboardChartExport.render`, and `ExtensionAttributeService.load` decode-error branches — used `privacy: .public` for both file paths and `error.localizedDescription`. The project's existing convention (per `ReportEngine.swift`) is `lastPathComponent` (public) + `error.localizedDescription` (private). Updated to match: full paths now log as `lastPathComponent`, and error descriptions are redacted by the OS unified-log system when viewed by other users.
- **Silent PNG export failures** (macOS app): `DashboardChartExport.run` (and the EA-dashboard equivalent) previously dropped render and write errors with `try?` after the user had already confirmed a save destination. Both helpers now return `Result<URL, ExportError>?`; each dashboard caller posts a danger-style toast on `.failure` and `AppLogger.ui.error` records the underlying error. The user-visible action no longer fails silently when the disk is full, the destination is unwritable, or `ImageRenderer` returns nil.
- **EA snapshot decode failures hidden as "no data"** (macOS app): `ExtensionAttributeService.load(resultsURL:definitionsURL:)` used `try?` on the JSON decode, making a truncated or corrupt `ea-results.json` indistinguishable from a pre-first-collect empty state. Decode errors now log to `AppLogger.engine.warning` with the failing file path so a stale or malformed snapshot is diagnosable from `Console.app`.
- **Unstable mobile-device row IDs** (macOS app, Mobile Fleet): `Either<L, R>.id` returned `UUID().uuidString` when both `MobileDeviceListRow.id` and `MobileDeviceInventoryItem.mobileDeviceId` were nil, generating a fresh random identity on every render pass. SwiftUI Table selection and scroll position now use a deterministic fallback (`light-<serial>-<name>` / `rich-<serial>-<name>`) so rows without server IDs stay stable across redraws.
- **PNG-export duplication and missing a11y in EA dashboard** (macOS app): `ExtensionAttributesView.exportDistributionPNG` reimplemented the full `NSSavePanel` + `ImageRenderer` + `try?-write` pipeline and the corresponding button had no `accessibilityLabel` or `help`. The function now delegates to `DashboardChartExport.render(...)` (a sibling of `.run` that accepts an already-framed view), and the button has the same a11y modifiers as every sibling Export PNG control. The unused `isExporting` state and `AppKit` import were removed.
- **Skip-expensive subtitle omitted Extension Attributes** (macOS app, Settings): When the "Skip expensive collections" toggle is on, the subtitle listed Posture/Patch/Updates as affected. Since `ea-results` is one of the four suppressed commands, the Extension Attributes dashboard is also affected; the subtitle now lists all four.
- **Trends Export PNG missing accessibility metadata** (macOS app): The reference Export PNG button in Trends had no `accessibilityLabel` or `help`. Added both so VoiceOver announces the active metric and the button's purpose, matching the bar set by the new dashboards.
- **`alertsBySevirityCard` typo** (macOS app, Protect): renamed to `alertsBySeverityCard`. Internal only — no user-visible impact.
- **CollectFilterTests tautology** (macOS app, tests): `testSkipExpensiveFalsePreservesAllPlannedKinds` used `.filter { _ in true }` (identity), which asserted nothing about production behavior. Replaced with `testSkipExpensiveDeltaIsExactlyTheExpensiveKindsSet`, which exercises both branches and asserts the symmetric difference equals `expensivePerDeviceKinds`. Added `testPlannedKindsCountMatchesProductionCommandList` as a drift guard against silent kind additions in `ReportEngine.collect`.
- **Trend metric silent corruption** (Python CLI): `_build_summary_from_bridge` and `_emit_summary_json` silently wrote `0.0` to `summary.json` when any bridge call (security_report, inventory_summary, device_compliance, patch_status) raised an exception. The 0.0 was indistinguishable from a real zero reading in Trends charts. All five metric collection blocks now log a `[warn]` line on failure; `0.0` is still written as a sentinel (required by the Swift decoder) but the failure is now visible.
- **Cache-write failure hidden from fallback chain** (macOS app): `CachedDataFallback.runWithFallback` used `try?` on `saveSnapshot(data)`, silently discarding disk errors (ENOSPC, EACCES). If the cache was never written, the next live failure would hard-error instead of falling back gracefully. Now logs the write failure at `AppLogger.engine.warning` and returns the live data normally.
- **`SystemActions.open` accepted plain `http` URLs** (macOS app): The browser-open branch allowed `http` in addition to `https`, and accepted any URL regardless of whether it had a valid host. Now requires scheme `== "https"` and a non-empty host; bare scheme URLs (e.g. `javascript:`, `data:`) are silently dropped.
- **Silent `return -1` after `ensureWorkspace`** (macOS app): Four call sites in `CLIBridge` returned `-1` with no output when `ProfileService.workspaceURL` returned nil after `ensureWorkspace` succeeded — an unreachable-in-practice but hard-to-diagnose state. All four now emit a `.fail`-level `LogLine` to the Runs screen and an `AppLogger.cli.error` entry before returning.
- **Background refresh failures were invisible** (macOS app): `RefreshCoordinator.performRefresh` incremented `failureCounts` on non-zero collect exits but emitted no log and published no state. Auth expiry or server outage silently staled all workspace data. Now logs each background refresh failure at `AppLogger.cli.warning` with the exit code and consecutive-failure count.
- **Workflow script injection vector** (CI): The jamf-cli version-watcher workflow interpolated the upstream release tag directly into a `run:` shell context. A malicious tag value from `Jamf-Concepts/jamf-cli` could be injected into the shell. The tag is now validated against `^v?[0-9][0-9A-Za-z.+\-]*$` before being written to `$GITHUB_OUTPUT`, and subsequent steps reference it via `env:` rather than direct `${{ }}` interpolation.
- **Cache directory permission errors were indistinguishable from missing directory** (macOS app): `cachedJSONSnapshots` used `try?` on `contentsOfDirectory`, treating ENOENT (expected on first run) identically to EACCES or other errors. Now uses `do/catch` with a specific `NSFileReadNoSuchFileError` guard — ENOENT returns an empty list silently; other errors are logged at `AppLogger.cli.warning`.
- **Security Hardening**: Resolved path-traversal risks by sanitizing trailing-slashes in workspace paths and validating profile names in `TrendStore`.
- **HTML Security**: Hardened HTML reports against branding-driven markup/style injection via escaped titles and topbar branding.
- **UI Stability**: Fixed Swift compiler ambiguities and missing return statements in various app views (`SchedulesView`, `AuditView`).
- **Data Integrity**: Improved error normalization for cached Jamf software-update responses to prevent blank report sheets.
- `_emit_summary_json` now validates existing summary files before skipping:
  parses JSON and checks for required keys (`date`, `totalDevices`, `source`);
  regenerates instead of using corrupt data.
- Compliance parsing no longer crashes in summary path: removed `sys.exit(1)`
  when unparseable values are found; sets `comp_pct = None` and logs a warning.
- Font loading on remote Macs: bypassed SwiftPM's `Bundle.module` lookup for font resources so custom fonts load correctly when the app bundle is copied to a different Mac.
- Canonical macOS bundle layout: normalized the SwiftPM resource bundle directory structure so resource paths resolve correctly in production builds outside the build tree.
- Per-profile drill-down: fixed pluralization of time-ago labels and corrected a missing Stability trend chart on the per-profile detail view in Fleet Overview.
- Tests for `max_cache_age_hours` enforcement in `test_bridge.py`:
  `test_max_cache_age_raises_when_cache_too_old`,
  `test_max_cache_age_skips_check_when_zero`,
  `test_max_cache_age_uses_cache_when_fresh`.
- Tests for `JamfCLIBridge.audit()` and `group_analyze()` methods:
  `test_audit_calls_correct_command`,
  `test_audit_with_category_adds_checks_flag`,
  `test_group_analyze_unused_mode_adds_flag`.
- Fixed chart layout overflow in the macOS app where charts could go "off the page"
  due to categorical string X-axis; now uses continuous `Date` scaling.
- Fixed timeline range filtering (W4–W52) to be duration-based rather than
  snapshot-count based, ensuring correct behavior when daily snapshots exist.
- Fixed chart scaling for sparse data: charts now anchor to the selected time
  domain (e.g., a full year for W52) rather than stretching few points to fill.
- Improved responsiveness of **Trends** view; comparison cards now stack
  vertically on narrow windows using `ViewThatFits`.
- Added **Data Staleness Indicators** to headers; timestamps now turn amber (>24h)
  or red (>7d) with a relative age label to warn when viewing old cached data.
- Improved search discoverability; `Cmd + F` now automatically focuses the search
  field in **Detailed Inventory** and **Health Audit** views.
- Health Audit now tracks drift between cached audit snapshots, badges findings
  that are new since the previous run, and shows recently resolved findings.
- Multi-profile automation now has a dedicated `multi-launchagent-run` command
  that fans out the existing LaunchAgent workflow across initialized profile
  workspaces, with aggregate status JSON and per-profile results.
- Fixed optional metrics (Stability, NIST Compliance) in the macOS app **Overview**
  rendering as 0.0% when no historical data exists; now shows "--" and "No Data".
- Manual multi-profile "Run now" actions in the macOS app now append their output
  to the standard schedule logs and record exit status correctly.
- Hardened device row identity to prevent collisions for records that capture
  a numeric Jamf ID but lack a serial number or name.
- Fixed sidebar trend badge to honor custom `charts.historical_csv_dir` paths
  instead of hardcoding the default snapshots directory.
- Manual multi-profile "Run now" now rejects legacy `jamf-cli multi`
  LaunchAgent plists that point at a fake executable with the same basename
  instead of the trusted `jamf-cli` discovered by the app.
- Multi-profile LaunchAgent schedules now read their aggregate status JSON and
  treat `[fail]`, `Error:`, and non-zero exit markers in logs as failed runs,
  so a failed profile fan-out no longer appears as OK in the schedule list.
- Trends now keep optional metric values paired with their original snapshot
  dates, preventing Compliance, CrowdStrike, and Stability data from drifting
  onto the wrong date when summaries mix CSV-only and jamf-cli-backed metrics.
- Active Devices demo trends now use the demo total-device series and clamp
  mismatched demo date/value arrays, preventing crashes when viewing that metric.
- "Open in Jamf Pro" context-menu actions now appear only when a device has a
  numeric Jamf computer ID populated from inventory or patch-failure data,
  avoiding invalid URLs built from serial/name-based local row IDs.
- Breadcrumb navigation actions now use main-actor closures, resolving Swift
  concurrency warnings from page-header navigation callbacks.
- macOS app Trends **Export PNG** now renders readable, self-contained chart
  images with a light background, title, date range, gridlines, axis labels,
  point markers, highlighted latest point, and summary stats instead of sparse
  dark images with little context.
- Active Devices PNG exports now use dynamic y-axis scaling so count metrics no
  longer flatten into a near-empty line against a hardcoded range.
- Multi-profile schedules now run the saved JRC LaunchAgent command instead of
  bypassing automation through `jamf-cli multi -- pro collect`, preserving the
  selected mode, base profile, target profile list/filter, sequential setting,
  logs, and status-file behavior.
- Health Audit, Group Hygiene, and Backups app views received focused usability
  refinements: compact KPI summaries, last-run timestamps, clearer affected
  counts, recommendation details, group-type/status pills, bulk ID/CSV helpers,
  improved backup labels, diff selection hints, and syntax-colored diff output.
- When `--csv` is explicitly provided but the file is unreadable, `generate`
  now exits with an error instead of silently producing a workbook with no
  CSV sheets.
- When the Compliance sheet is enabled in config but fails during generation,
  `generate` now exits with an error rather than silently skipping the sheet.
- The output workbook is now written to a `.partial` temp file and atomically
  renamed to the final path only after a successful `wb.close()`, preventing
  partially-written `.xlsx` files from being left on disk if the process is
  interrupted mid-write.
- Compliance failure counts of `""` or `"N/A"` no longer silently count as
  passing. Unparseable values are excluded from the compliant count in both
  the summary JSON and the Compliance sheet. The sheet now shows an
  "Unparseable (excluded)" row when any values could not be parsed, making
  the data quality issue visible.
- Merging multiple CSVs via `--csv` now deduplicates rows by serial number.
  If the same serial appeared in more than one input file, the first
  occurrence is kept and a warning is printed.
- Fleet Drift comparison now warns when a historical CSV snapshot contains
  duplicate serial numbers, rather than silently discarding them.
- Unexpected exceptions that escape a command (e.g. network errors, malformed
  JSON) now print a clean `Error: <type>: <message>` line to stderr and exit 1,
  instead of surfacing a raw Python traceback with local paths.
- **Build Fix**: Fixed a missing `return` statement in `SchedulesView.swift` that prevented the macOS app from building.
- **Swift Compiler**: Simplified `latestJson` closure in `AuditView.swift` to resolve a compiler ambiguity error.
- macOS app builds now fail fast when component or bundle signing fails instead
  of continuing with a partially signed app.
- Bundled Python runtime builds now require a pinned SHA256 before downloading,
  extracting, or copying a runtime asset.
- Swift jamf-cli install/update subprocesses now drain stdout and stderr while
  the process is running, avoiding hangs when a command emits enough output to
  fill a pipe buffer.
- Manual scheduled "Run now" execution now rejects tampered LaunchAgent plists
  whose Python executable, script path, config/status paths, log paths, or
  profile do not match the generated command contract.
- LaunchAgent environments are now rebuilt from a small trusted set instead of
  inheriting plist-controlled `PATH`, `JAMFCLI_PATH`, `PYTHONHOME`, or
  `PYTHONPATH` values.
- `launchagent-setup` now writes LaunchAgent plists atomically and restores the
  previous plist if `launchctl bootstrap` fails.
- `backup` now removes partial backup directories on subprocess, stats,
  manifest, or final rename failures and reports cleanup failures explicitly.
- `inventory-csv` now writes through a destination-local temp file before
  replacing the final CSV, preserving an existing export if the write fails.
- `generate` now emits trend summary JSON only after the workbook closes
  successfully, and `--force-summary` can explicitly replace an existing
  same-day summary.
- Cached Jamf managed-software-update endpoint errors are now normalized to the
  same no-data workbook rows as live `jamf-cli` failures, so cached reports no
  longer produce blank Update Status/Failures sheets when the tenant toggle is off.
- Reduced macOS app file-opening and onboarding exposure by removing the unused
  `/Applications` allow-list entry and redacting profile credentials from
  registration failure output before it is shown in the UI.
- Hardened generated HTML reports against branding-driven markup/style injection:
  page titles and topbar branding are escaped, accent colors are limited to hex
  values, inline logos must be small bitmap images, and SVG logos are rejected.
- Hardened macOS app multi-profile "Run now" execution so tampered LaunchAgent
  plists cannot redirect the aggregate status file or stdout/stderr logs outside
  the generated `~/Library/Logs/JamfReports/<label>/` directory, and the saved
  `multi-launchagent-run` arguments must match the generated command contract.
- macOS app report actions now choose a Python interpreter that can import the
  bundled report dependencies, and the workspace banner now distinguishes a
  missing `config.yaml` from a missing workspace directory.
- macOS app scheduled runs now show computed next-run times and last-run status
  from the generated LaunchAgent status/log files; manual "Run now" uses the
  schedule's `launchagent-run` command so it records run history consistently.
- Turning demo mode off now removes the synthetic `meridian-prod` local
  workspace and any generated demo LaunchAgents so the demo profile does not
  leak into live profile discovery.
- Hardened macOS app profile handling around connection validation, workspace
  initialization, LaunchAgent labels, and live-mode trends so invalid profile or
  schedule names are rejected consistently and live users are not shown synthetic
  compliance-band chart data.
- The macOS app now delegates scheduled-run LaunchAgent creation to Python's
  `launchagent-setup`, using the shared status-file, log, CSV inbox, and
  `com.github.tonyyo11.jamf-reports-community.*` plist format; old
   `com.tonyyo.jrc.*` app-generated plists are removed on launch.
 - Fixed `DeviceRecordMerger` not updating `jamfIDIndex` after merging records
   with a new `jamfID`, causing subsequent lookups by Jamf ID to miss updated records.
 - Fixed `TrendStore` timezone mismatch: `parsedDate` used UTC while
   `filterSummaries` used `Calendar.current`, causing date-range boundaries to
   shift during DST transitions. Both now use `Calendar(identifier: .iso8601)`.
 - Fixed `DailySummary` decoding to use explicit `init(from:)` with
   `decodeIfPresent` for optional keys (`compliancePct`, `crowdstrikePct`),
   preventing decode failures when Python omits CSV-only metrics.
 - Fixed `cmd_multi_launchagent_run` missing timeout: `ThreadPoolExecutor` now
   uses `wait(futures, timeout=3600)` so a hanging profile run cannot block
   the pool indefinitely; timed-out profiles are recorded as failed.

### Removed

- Removed unwired Swift prototype status/history/benchmark screens, their
  orphaned single-consumer services, unused demo fixtures, unused theme tokens,
  and unused private Python helpers.

## [1.3.0] - 2026-04-24

### Fixed

- `cmd_inventory_csv` now reads `jamf-cli pro computers list` responses correctly.
  Earlier versions read top-level keys (`name`, `serialNumber`, `operatingSystemVersion`,
  `location.username`) but `jamf-cli` returns nested objects (`general.name`,
  `hardware.serialNumber`, `operatingSystem.version`, `userAndLocation.username`) and,
  by default, only includes the General section. The result was inventory CSVs where
  every non-id/udid field was empty. The bridge now requests
  `--section GENERAL --section HARDWARE --section OPERATING_SYSTEM
  --section USER_AND_LOCATION --section DISK_ENCRYPTION --section SECURITY`, and
  `_inventory_export_row()` resolves values through `_flatten_record` plus a new
  `INVENTORY_FIELD_CANDIDATES` lookup table that handles both nested (current) and
  flat (legacy) shapes.
- Per-device `pro device <id>` enrichment is no longer the only source for FileVault,
  SIP, Firewall, Bootstrap Token, and Gatekeeper columns — those values now come from
  the inventory list's SECURITY section. Setting
  `inventory_csv.skip_security_enrichment: true` is now safe with no data loss for
  the standard security columns; it simply skips redundant per-device API calls.

### Added

- New `jamf_cli.command_timeout_seconds` config key (default `300`) sets the per-call
  timeout for jamf-cli subprocess invocations. The previous hardcoded 120s timeout
  was insufficient for slow Jamf Pro instances or large fleets.
- New `jamf_cli.ea_results_timeout_seconds` config key (default `600`) sets a
  longer timeout specifically for `pro report ea-results --all`, which is consistently
  the slowest jamf-cli call because it queries every EA value across the fleet.
- New `inventory_csv` config block with `max_workers` (default `20`) and
  `skip_security_enrichment` (default `false`). Replaces the previous hardcoded
  `max_workers=8` and provides an opt-out for the per-device security enrichment
  loop now that the inventory list returns security fields directly.
- `JamfCLIBridge.computers_list()` accepts a `sections` argument and converts it to
  repeated `--section` flags. `_run()` and `_run_and_save()` accept an optional
  `timeout` override.

### Changed

- Tracked jamf-cli dependency updated to v1.14.0. No code changes required.
  Notable upstream changes in v1.14.0: added `-vv` (request headers) and `-vvv`
  (request and response bodies) verbose levels — additive and orthogonal to this
  tool's stdout JSON parsing. Generator command ingests Jamf Pro 11.27.0
  monolith OpenAPI spec — improves command coverage upstream without affecting
  any commands this tool already calls.

## [1.2.0] - 2026-04-20

### Added

- **`export-reports` command** — generates dated, filtered CSV snapshots from the
  wide `automation_inventory_*.csv` produced by `launchagent-run --mode jamf-cli-full`.
  Configured via the new `export_reports` list in `config.yaml`.  Each entry defines
  a name, output directory, filename template (`{ts}` is replaced with a timestamp),
  schedule (`daily`, `mon,wed,fri`, `1st-of-month`, etc.), optional row filter
  (`within_days` or `exclude_values`), and optional column selection/rename map.
  State files in `jamf-cli-data/state/export-<name>.last` prevent double-writes
  within the same day.
- `export-reports` runs automatically as the final step of
  `launchagent-run --mode jamf-cli-full` when `export_reports` entries are
  configured; exported paths are recorded in the automation status JSON.
- `Config.export_reports` property (returns `list[dict]`, empty list default).
- **`sheets.only`** config list — when non-empty, only the named workbook tabs
  are written. This takes precedence over `sheets.skip` and supports focused
  workbooks such as patch-only, security-only, or mobile-only exports.
- **`sheets.skip`** config list — named workbook tabs can now be skipped during
  `generate` and `school-generate`, including CSV-backed sheets, custom EA tabs,
  and auxiliary tabs such as `Report Sources` and `Charts`. Sheet names are
  matched case-insensitively and unknown names emit a warning.
- **`automation.generate_html` / `generate_xlsx` / `generate_inventory_csv`**
  config flags — LaunchAgent automation can now produce timestamped HTML,
  xlsx, and inventory CSV artifacts per scheduled run, including `snapshot-only`.
- `launchagent-run` status JSON now records separate xlsx, HTML, and inventory
  CSV output paths when those artifacts are produced.
- `cmd_html()` now archives older timestamped HTML outputs using the same
  `output.archive_enabled` / `keep_latest_runs` retention rules as xlsx reports.

### Changed

- Tracked jamf-cli dependency updated to v1.11.0. No code changes required:
  the field-candidate and fallback logic already handles the v1.10.0 change
  where `pro mobile-devices list` switched to the detail endpoint with nested
  `general.*` JSON fields; the `MOBILE_INVENTORY_FIELD_CANDIDATES` dictionary
  already covers both flat and nested key shapes.
- `pro computers-inventory` remains the primary command namespace in v1.10.0;
  `computers` / `comp` are now registered as aliases pointing to it, so all
  existing calls to `pro computers-inventory patch` continue to work unchanged.
- New v1.11.0 subcommands `pro classic-account-users list` and
  `pro classic-account-groups list` are not yet used by this tool; flagged here
  for future consideration as a backup-coverage sheet.
- Tracked jamf-cli dependency updated to v1.12.0. No code changes required.
  Notable upstream changes in v1.12.0: `apply` now works for PATCH-only resources
  (vpp-locations, computers-inventory, adcs-settings, digi-cert-settings,
  mobile-device-groups-static-groups, patch-software-title-configurations,
  team-viewer-remote-administrations, venafis) — this tool does not use `apply`.
  The `--rename` flag was renamed to `--name` for `device-enrollment-instances`
  create/update/apply operations — this tool only uses `device-enrollment-instances list`
  and is unaffected. `config show`, `config list`, and `config validate` now accept
  `-o` for structured output (json, yaml, csv, table, plain) — additive, no impact.
- Tracked jamf-cli dependency updated to v1.13.0. No code changes required.
  Notable upstream changes in v1.13.0: `--installation-priority` added to package
  upload commands — this tool does not upload packages. `--custom-payload-file` and
  `--custom-payload-domain` added for classic macOS config profile create/update —
  this tool only uses `classic-macos-config-profiles list` and is unaffected.
  Help command examples now consistently include the `pro` prefix — cosmetic/docs
  change, no impact on CLI syntax or on the help-output parser used for command
  discovery. HTTP client internals (streaming multipart, shared transport) improved
  with no CLI surface change.

## [1.1.0] - 2026-04-16

### Added

- Added **Active Devices** sheet to the jamf-cli workbook showing total, active, and
  inactive device counts against the `thresholds.stale_device_days` window.
- Added adjusted compliance columns to **Patch Compliance**: Adjusted Up To Date,
  Adjusted Out Of Date, Adjusted Total, and Adjusted Completion %. These columns scale
  raw patch counts by the active-device ratio so stale/offline devices don't deflate
  reported compliance. If device-compliance data is unavailable the adjusted columns are
  silently omitted and raw columns remain unchanged.
- Added Jamf School reporting support for `jamf-cli school` data (jamf-cli 1.7+) and
  Jamf School device CSV exports.
- Added `school-generate`, `school-collect`, `school-scaffold`, and `school-check`
  commands.
- Added Jamf School workbook sheets for inventory, OS versions, device status, stale
  devices, overview, device groups, users, classes, apps, profiles, and locations.
- Added **Cleanup Analysis** section to the HTML report. Surfaces disabled policies,
  unscoped policies, unscoped macOS profiles, unused packages, and unused scripts — each
  in its own tab with a count badge. The section appears only when per-policy and
  per-profile detail JSON is cached on disk (populated by the `collect` step). If no
  detail cache exists, the section is omitted silently.
- Added **macOS Adoption Timeline** chart to the HTML report. Requires
  `html.track_history: true`; the chart appears once two or more point-in-time snapshots
  exist for the same instance.
- Added `scripts/demo.sh` as a supported offline demo runner that generates fixture-backed
  HTML, Jamf Pro workbook, mobile CSV workbook, and Jamf School workbook outputs without
  requiring a live tenant or local maintainer workspaces.

### Changed

- Extended the config and documentation surface to cover Jamf School mappings and
  workflows.
- Documented the committed fixture corpus as the supported no-credentials demo path for
  the community repo and replaced README workspace examples that implied local `Dummy/`
  or `Harbor/` directories.

### Fixed

- Fixed a cache lookup bug in `_latest_cached_json` where `rglob` was matching JSON files
  inside per-ID detail subdirectories (e.g. `classic-policies/14/`) when querying the
  parent directory. Changed to non-recursive `glob` so list-level and detail-level caches
  are not confused.
- Fixed HTML report JavaScript being completely non-functional (dark mode, table sorting,
  search, CSV export all broken). The `_js()` method used a plain triple-quoted Python
  string, causing `\r` and `\n` to be emitted as literal CR/LF bytes inside JavaScript
  regex patterns and string literals, producing a parse error that silently broke the
  entire `<script>` block. Fixed by switching to a raw string (`r"""..."""`).

### Changed

- Removed the DevliegereM attribution link from the HTML report footer. Credit is
  retained in source-code comments. Public-facing documentation and the wiki continue
  to credit the original project.

## [1.0.0] - 2026-04-14

### Added

- Initial tagged community release of the single-file Jamf reporting tool.
- Config-driven Jamf Pro CSV reporting with scaffold, validation, collection, and report
  generation workflows.
- Optional `jamf-cli` integration for live snapshots and expanded workbook coverage.
- Release packaging automation for tagged GitHub releases.
