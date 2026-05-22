# Documentation Restructure Plan — post-v2.0

> **Status:** Proposal. Planning document only. No documentation files are changed by
> the commit that introduces this plan — the single file written is this plan itself.
> A future writing session executes the PRs described in §9.
>
> **Author context:** Produced 2026-05-22 against `origin/main` at `ed77309`. All
> jamf-cli facts (§1) were verified live against upstream sources on that date; all
> app-feature facts (§2) were verified against `app/Sources/JamfReports/` source on
> that date. Re-verify both before executing if more than a few weeks have passed.

---

## Why this exists

jamf-reports-community shipped **v2.0.0** (2026-05-20). The product is now two
components:

- a native macOS SwiftUI app (`app/`, macOS 14+, Swift 6) — the **recommended, primary**
  interface;
- the Python CLI (`jamf-reports-community.py`) — now **optional/secondary**, for
  headless, CI/Linux, server-side, and automation use.

The documentation never caught up. Three problems, in priority order:

1. **`README.md` is 1,393 lines and Python-CLI-centric.** The app is a short section at
   the top; everything from "What This Is" (line 50) onward documents the script.
2. **The project ships two parallel, unsynchronized documentation sets.** `docs/wiki/`
   (10 files, a linear Python-CLI workflow) and the `docs/` tree
   (`onboarding/`, `operations/`, `templates/`, `architecture/`, `GLOSSARY.md`,
   `INDEX.md`, `testing.md` — 16 files, app-centric). They overlap on setup, config,
   scheduling, and trends, share no navigation, and disagree with each other.
3. **The docs have drifted from the code.** HOT/WARM/COLD collection tiers (deleted in
   PR-23, replaced by Refresh/Inventory/Scan) still appear in five files; the screen
   count is stated as 12, 14, 16, 24, and 27 in five different places; the LaunchAgent
   plist prefix is wrong in four files. Re-describing the app from these docs would
   only relaunder the staleness — which is why §2 below rebuilds the feature inventory
   from source.

### Two corrections to the prior straw-man

A previous drafting session produced an appendix straw-man (preserved as the basis for
§4–§5). Two of its claims are wrong and are corrected here:

- It called `README.md` "~500 lines." Verified: **`wc -l README.md` → 1,393.**
- It said `docs/wiki/` is "mirrored to the GitHub Wiki via CI." Verified false:
  `.github/workflows/` contains `ci.yml`, `release.yml`, `report.yml`, and
  `update-jamf-cli-version.yml` — **no wiki workflow exists.** The live wiki at
  `github.com/tonyyo11/jamf-reports-community/wiki` is served from a separate repo,
  `…/jamf-reports-community.wiki.git`, and is published **manually**. §8 supplies the
  command sequence.

---

## 1. jamf-cli upstream review

Verified 2026-05-22 against the jamf-cli README, GitHub Wiki, and the published docs
site (`jamf-concepts.github.io/jamf-cli`).

### Current command surface

| Topic | Current fact (verified) |
|---|---|
| Latest version | **v1.17.0** (released 2026-05-14). 20 releases total. |
| Install | `brew install Jamf-Concepts/tap/jamf-cli` (third-party tap), or `go install …@latest`, or pre-built release binaries (macOS/Linux/Windows, amd64+arm64). |
| Jamf Pro setup | `jamf-cli pro setup --url https://jamf.example.com` — still valid. Prompts for credentials; offers a `--scope read-only \| standard \| full-admin` choice. |
| Platform Gateway setup | **New since v1.6:** `jamf-cli platform setup` enables Pro **and** Platform API commands in one profile. Upstream now presents this as a recommended path. |
| `config validate` | Still exists, same name. `jamf-cli config validate [--connectivity]`. Honors `-p/--profile`. Companion commands: `config list`, `config show`, `config path`. |
| Profile flag | Unchanged: `--profile` / `-p`. **No rename to "tenant" has occurred.** `--tenant-id` is a *separate*, additive flag used only for Platform Gateway auth routing — do not conflate it with `-p`. |
| Protect setup | Still `jamf-cli protect setup --url …`. The `protect` namespace is large and active. |
| Jamf School | `jamf-cli school` namespace is present and documented; first-run is `jamf-cli school setup`. New resources since the project's School support landed: `ibeacons`, `dep-devices`, `blueprints`, `ddm-reports`. |
| JSON output | Canonical flag is **`-o json`** (`--output` long form also valid). Global default output is already `json`; classic-API commands default to `xml`. |
| Exit codes | `0` success, `1` general, `2` usage, `3` auth, `4` not-found, `5` permission-denied, `6` rate-limited — **matches the table in the repo's `CLAUDE.md` and `ARCHITECTURE.md` exactly. No change needed.** |
| `pro report` family | `security`, `patch-status`, `policy-status`, `profile-status`, `app-status`, `update-status`, `device-compliance`, `inventory-summary`, `software-installs`, `ea-results`. New platform reports (unconsumed by this project): `blueprint-status`, `compliance-rules`, `compliance-devices`, `ddm-status`. |
| API permissions | jamf-cli **does not publish a canonical required-privileges list** — its docs defer to Jamf's "Privileges and Deprecations" reference. The project's documented Read-only table (Computers, Mobile Devices, Mobile Device Configuration Profiles, Computer Extension Attributes, Policies, Patch Management, Mobile Device Applications, Managed Software Updates, Computer Groups) is internally consistent with the endpoints the project's `pro report` commands consume and is a reasonable minimum. Keep it, but caveat it as "the minimum read-only privileges this project needs — jamf-cli itself publishes no required-privileges list." |

### Why the v1.16.1 floor still holds

The repo's `CLAUDE.md` requires jamf-cli **v1.16.1** because `pro device <id>` gained a
platform-section nil-guard in that release (PR #185), and v1.15 added URL normalization
at all entry points. Upstream latest is v1.17.0; nothing in v1.17.0 invalidates the
floor. **The floor is correct — the documentation that contradicts it is what is wrong**
(see below). One refinement worth making during execution: v1.17.0 added a `--compact`
flag intended for token-efficient agent output; not required, but worth a one-line
mention in the CLI wiki page as a future option.

### Every stale / incorrect jamf-cli reference in the current docs

| Location | Stale claim | Correct fact |
|---|---|---|
| `README.md:144` | "use `jamf-cli 1.6.0+`" for Protect | Floor is v1.16.1; Protect commands are current. |
| `README.md:162–187` | Platform API sheets framed as "preview … depends on a jamf-cli build that exposes the new `pro report` platform commands" | The four platform reports are real commands in current jamf-cli (Platform API itself is still beta). Reframe as "requires Platform Gateway auth," not "a build that exposes them." |
| `README.md` (throughout) | `--output json` long form | Valid, but `-o json` is the idiomatic upstream form — prefer it in new examples. |
| `docs/wiki/Home.md:21–24` | "Jamf Protect … driven by `jamf-cli 1.6`"; "`jamf-cli school` live data (jamf-cli 1.7+)" | Floor is v1.16.1; state it once. |
| `docs/wiki/01-Setup-and-Prerequisites.md` | body says "use `jamf-cli 1.6.0+`" for Protect (the header already says v1.16.1+) | Remove the v1.6 body reference. |
| `docs/wiki/03-jamf-cli-Workflow.md` | per-command version gates `app-status (v1.2.0+)`, `update-status (v1.2.0+)`, `mobile-devices list (v1.10.0+)`, "available as of v1.11.0"; Protect "experimental, `jamf-cli 1.6`" | All gates are below the v1.16.1 floor — delete them and state the floor once. |
| `docs/wiki/08-Jamf-School-Workflow.md` | "Live collection requires jamf-cli 1.7 or later" | Floor is v1.16.1. |
| `docs/onboarding/GETTING_STARTED.md`, `FIRST_RUN_CHECKLIST.md` | use `jamf-cli auth login` | Not a current command — the setup command is `jamf-cli pro setup`. |
| `docs/onboarding/WITHOUT_CSV.md`, `docs/templates/CUSTOMIZATION_GUIDE.md` | wizard "runs `jamf-cli pro report ea-coverage`" | The real report subcommand is `pro report ea-results`. Verify against the app's actual call and correct the wrong side. |
| Wiki Home + multiple pages | "written against jamf-cli v1.6" framing | The project code targets v1.16.1; the wiki's stated baseline is stale and contradicts the repo's own `CLAUDE.md`. |

**Setup-flow note for the writer:** `jamf-cli pro setup` did not rename — it still works
and remains the simplest single-tenant path to document. The change since v1.6 is that
`jamf-cli platform setup` now *also* exists. Docs that present `pro setup` as the only
option are not *wrong*, only incomplete; a one-line "Platform Gateway users: see
`jamf-cli platform setup`" is sufficient.

---

## 2. Verified app feature inventory

Rebuilt from `app/Sources/JamfReports/` source on 2026-05-22, not from `CLAUDE.md` or
memory. Every showcase claim below cites the View/Service that proves it. **Anything not
verifiable in source is excluded** (see "Exclusions" at the end of this section).

### Navigable screens (the showcase set — 24 screens)

The `Tab` enum has 24 cases (`Services/WorkspaceStore.swift:603–699`); the sidebar
groups them (`Views/Sidebar.swift:27–35`). Core, non-hideable tabs are `overview`,
`devices`, `sources`, `settings`, `onboarding` (`WorkspaceStore.swift:687–698`); every
other tab is user-toggleable via Settings → Sidebar Visibility, backed by
`@AppStorage("hiddenTabs")` and `TabVisibility` (`WorkspaceStore.swift:710–756`).

| Sidebar group | Screens (file) |
|---|---|
| **REPORTS** | Overview (`OverviewView.swift`), Fleet Overview (`FleetOverviewView.swift`), Devices (`DevicesView.swift`), Device Lookup (`DeviceLookupView.swift`), Trends (`TrendsView.swift`), Health Audit (`AuditView.swift`), Generated (`ReportsView.swift`) |
| **POSTURE** | Security Posture (`SecurityPostureView.swift`), Compliance Posture (`CompliancePostureView.swift`), Offline Outreach (`OutreachView.swift`) |
| **OPERATIONS** | Patch Compliance (`PatchView.swift`), OS Updates (`UpdatesView.swift`), Policies & Profiles (`PolicyProfileView.swift`), Extension Attributes (`ExtensionAttributesView.swift`) |
| **FLEET** | Mobile Fleet (`MobileFleetView.swift`), Jamf Protect (`ProtectView.swift`) |
| **AUTOMATION** | Schedules (`SchedulesView.swift`), Run History (`RunsView.swift`) |
| **CONFIGURATION** | Config (`ConfigView.swift`), Customize (`CustomizeView.swift`), Data Sources (`SourcesView.swift`), Backups (`BackupsView.swift`) |
| **SYSTEM** | Settings (`SettingsView.swift`) |
| (off-sidebar) | Onboarding (`OnboardingView.swift`) — reached only on first run or via the workspace chip's "Add workspace…" item. |

### Capabilities verifiable in source

- **Native Swift report engine.** `struct ReportEngine` at
  `app/Sources/JamfReports/Engine/ReportEngine.swift:18` generates every report
  (xlsx/HTML/PDF). The `Engine/` directory also holds `CoreDashboard`, `CSVDashboard`,
  `SchoolDashboard`, `HtmlReport`, `ChartRenderer`, `OOXMLWriter`, `PDFExporter`.
  **Note for the writer:** `CLAUDE.md`'s file tree omits the `Engine/` directory
  entirely — do not rely on `CLAUDE.md` for the app's internal layout.
- **Schedule run modes** — `Schedule.RunMode`, `Models/Models.swift:88–93`: four cases,
  raw values `snapshot-only`, `jamf-cli-only`, `jamf-cli-full`, `csv-assisted`.
- **Onboarding** — `Services/OnboardingFlow.swift`: a 7-step `@Observable` flow —
  welcome → installCLI → workspace → authenticate → validate → csvMapping →
  firstReport. Credentials are passed to jamf-cli over a PTY and zeroed afterward.
- **Security Score** — `Services/SecurityScoreCalculator.swift`, weights editable via
  `ConfigView` → Scoring tab (`ConfigView.swift:154`), backed by
  `@AppStorage("securityScoreWeights")`.
- **Risk scoring** — `Services/RiskScoringService.swift`, per-device factor scorer
  feeding the DevicesView "Priority Risk" panel. (`CLAUDE.md` says "14-factor"; source
  shows ~13 distinct factors — describe it as "multi-factor," not a precise count.)
- **Historical Trends** — `Services/TrendStore.swift` + `SummaryJSONParser.swift` read
  `summary_*.json` snapshots; `TrendsView` plots up to 52 weeks.
- **Collection cadence** — `CadencePreset` / `CadenceResolver` / `CollectionTier`
  (On-prem / Cloud / Custom presets; Refresh / Inventory / Scan tiers).
- **Diagnostic bundle** — `SettingsView` "Copy Diagnostic Command" copies the command
  and opens Terminal; the app never executes the bundled script.
- **Smart Group apply** — `SmartGroupApplySheet` + `SmartGroupApplyService` wrap
  `pro sg apply` (the only Jamf-tenant *write* path). **Depends on jamf-cli's `pro sg`
  namespace from upstream PR #205, which is not in v1.17.0** — the service guards on
  namespace availability. Document this as conditional, not as a shipped capability.

### Exclusions — do NOT showcase these

Source inspection found **six View structs with zero callers** — defined but never
presented. Documenting them would be documenting phantom features:

- `WorkspaceView.swift`, `CustomizationWizard.swift`, `HealthCheckView.swift`,
  `GenerateSheet.swift` (the View struct; its `GenerateSheetState` helper *is* used),
  `AppToolbar.swift`, `WhatsNewBanner.swift`.

The in-app health-audit feature is delivered by `AuditView` ("Health Audit" tab), **not**
by `HealthCheckView`. The live customization screen is `CustomizeView`, **not**
`CustomizationWizard`.

Two further `CLAUDE.md` claims could not be verified and must not be repeated in docs:
`LegacyHistoryImporter` is described as "Triggered from SettingsView" but has **no UI
caller** in source; and the "27 screens" count does not match the 24-case `Tab` enum.

> **Pre-execution gate (see §9):** the six unwired Views are a code-hygiene finding, not
> a documentation finding. File them to **Epic #104 (Code hygiene & refactors)** —
> which already has a "Dead code" section (e.g. *"`LaunchAgentService.swift` orphan
> parser arms…"*) — *before* the wiki content PR lands, so the docs and the code agree
> on what exists.

---

## 3. Current-state doc inventory

### Surfaces and what each contains

| Surface | Size | Audience | State |
|---|---|---|---|
| `README.md` | 1,393 lines | Python CLI | App is one section at the top; lines 50–1393 document the script. Holds the API-permissions table, full config reference, integrity-envelope section, troubleshooting. |
| `docs/wiki/` | `Home`, `_Sidebar`, `01`–`08` (8 numbered) + `images/` (7 PNGs) | Python CLI | A linear `python3 jamf-reports-community.py …` workflow, Home → 01 → 07. Page 08 (School) is orphaned from the reading order. Source for the live GitHub Wiki (published manually — §8). |
| `docs/` tree | `INDEX.md`, `GLOSSARY.md`, `testing.md`, `architecture/` (4), `onboarding/` (3), `operations/` (3), `templates/` (2) | App | A second, app-centric doc set. `docs/INDEX.md` explicitly calls `docs/wiki/` "legacy." |
| `ARCHITECTURE.md` (root) | 309 lines | Both | Design doc. **Heavily stale** — see below. |
| `app/README.md` | 215 lines | Build-from-source | **Heavily stale** — titled `dev-app/2.0`, claims "all 12 screens implemented," lists `LaunchAgent round-trip / config.yaml read/write / live trend parsing` as "TODO." |
| `CLAUDE.md` / `AGENTS.md` | identical, 51 KB each | AI agents | Not user docs, but factually drifted (omits `Engine/`, "27 screens", false `LegacyHistoryImporter` claim). Out of scope here; flagged in §10. |

### Overlap map (one-home-per-topic violations)

| Topic | Currently documented in |
|---|---|
| Setup / prerequisites / install | wiki `01`; `docs/onboarding/GETTING_STARTED.md`; `docs/onboarding/FIRST_RUN_CHECKLIST.md`; `README §Prerequisites`; `app/README.md §Quick start` |
| "jamf-cli is the engine / what this is NOT" | `docs/architecture/JAMF_CLI_FIRST.md`; `GETTING_STARTED.md`; `ARCHITECTURE.md`; wiki `03`; `WITHOUT_CSV.md`; `README` |
| Workspace / on-disk layout | `ARCHITECTURE.md`; `GETTING_STARTED.md`; `JAMF_CLI_FIRST.md`; `RELEASE_NOTES_SUMMARY.md`; wiki `01` + wiki `06` |
| LaunchAgent / background scheduling | wiki `07`; `docs/operations/BACKGROUND_REFRESH.md`; `ARCHITECTURE.md §Scheduling`; `tiered-collection-adr.md`; `RELEASE_NOTES_SUMMARY.md`; `FIRST_RUN_CHECKLIST.md` — **four mutually inconsistent tier-model descriptions** |
| config.yaml / scaffolding / column mapping | wiki `04`; `docs/templates/CUSTOMIZATION_GUIDE.md`; `WITHOUT_CSV.md`; `README §Configuration Guide`; `config.example.yaml` (canonical) |
| Custom EA types + recipes | wiki `04`; `CUSTOMIZATION_GUIDE.md`; `GLOSSARY.md`; `README §custom_eas` |
| Customization Wizard walkthrough | `WITHOUT_CSV.md` **and** `CUSTOMIZATION_GUIDE.md` — near-duplicate 4-step walkthroughs |
| Historical trends / snapshots | wiki `06`; `ARCHITECTURE.md`; `JAMF_CLI_FIRST.md`; `GLOSSARY.md`; `RELEASE_NOTES_SUMMARY.md` |
| Report templates | `docs/templates/REPORT_TEMPLATES.md`; `WITHOUT_CSV.md`; `RELEASE_NOTES_SUMMARY.md`; `GETTING_STARTED.md` |
| Reporting cadence | wiki `05`; wiki `06`; `REPORT_TEMPLATES.md` |
| Security model / hardening | `docs/architecture/jamf-reports-community-threat-model.md`; `ARCHITECTURE.md`; `RELEASE_NOTES_SUMMARY.md`; wiki `05` |

### Stale-claim register (fix-on-touch during execution)

- **HOT/WARM/COLD collection tiers** (deleted PR-23, replaced by Refresh/Inventory/Scan):
  still in `ARCHITECTURE.md §Scheduling`, `docs/operations/RELEASE_NOTES_SUMMARY.md`,
  `docs/onboarding/FIRST_RUN_CHECKLIST.md`, `docs/onboarding/GETTING_STARTED.md`,
  `docs/operations/TROUBLESHOOTING.md`, and partially in `docs/GLOSSARY.md`.
- **Screen count** stated as 12 (`app/README.md`), 14 (`RELEASE_NOTES_SUMMARY.md`),
  16 (`ARCHITECTURE.md`), 24 (`GETTING_STARTED.md`, `GLOSSARY.md`), 27 (`CLAUDE.md`).
  **Verified count: 24 navigable tabs** (§2).
- **LaunchAgent plist prefix** wrong as `com.example.report` (wiki `07`) and
  `com.jamfreports.*` (`ARCHITECTURE.md`, `RELEASE_NOTES_SUMMARY.md`,
  `TROUBLESHOOTING.md`). Correct prefix:
  `com.github.tonyyo11.jamf-reports-community.*`.
- **Broken image paths** — wiki pages `02`, `05`, `06`, `07` embed `../images/<file>.png`,
  which resolves outside the wiki dir. Images live at `docs/wiki/images/`; only
  `Home.md` uses the correct `./images/` form. (When published to the GitHub Wiki the
  pages are flat, so the published reference must be `images/<file>.png` — see §8.)
- **`ARCHITECTURE.md` factual errors** — claims the app "bundles both the Python runtime
  and the CLI script" and uses the Python CLI as a "fallback for Excel edge cases."
  Per `CLAUDE.md` and §2, the app never executes the bundled script; `ReportEngine`
  (native Swift) does all generation.
- **`docs/INDEX.md` contradiction** — labels `docs/wiki/` "legacy," but `docs/wiki/Home.md`
  presents itself as the current long-form guide. No other file acknowledges a split.
- **`docs/operations/RELEASE_NOTES_SUMMARY.md`** — header carries a worktree codename
  (`big-flies-care-zd3bz`), references "Phase 3 baseline" and a "reverted Tab IA reorg."
  This is internal-phase scratch, not a release record; `CHANGELOG.md` is canonical.
- **`docs/wiki/06` §Future Directions** — "tested on Jamf Pro only," lists Protect and
  Mobile as "likely next areas." The shipped app has Protect and Mobile Fleet
  dashboards.

---

## 4. New README outline

**Target: ~150–220 lines** (down from 1,393). The README becomes a front door, not a
manual. It states what the project is, points at the two components, and routes the
reader to the wiki. The straw-man §A is validated below with two refinements: it omitted
a Documentation section and a License/attribution section, both of which the current
README needs to keep.

### Section briefs

| # | Section | ~Lines | Content brief |
|---|---|---|---|
| 1 | Title + one-liner | 4 | Project name; one sentence: "Config-driven macOS fleet reporting for Jamf Pro and Jamf School — a native macOS app, with an optional Python CLI for headless use." |
| 2 | Community Showcase line | 1 | Keep the existing jamf-cli Community Showcase link verbatim. |
| 3 | Hero screenshot | 2 | One image — the Overview "Meridian Health Fleet Overview" dashboard (`overview.png` from the 2026-05-22 capture set; see §7). |
| 4 | **The macOS app** (primary) | 45–60 | "Recommended way to use this tool." What it does in two sentences. Dashboard groups at a glance — Reports / Posture / Operations / Fleet (cite §2; do **not** enumerate all 24). Key capabilities: configurable Security Score, Historical Trends, scheduled collection, native Swift engine (no Python needed for any report path). Requirements: macOS 14+, jamf-cli optional. "Download" → Releases page; "Build from source" → `app/README.md`. |
| 5 | **The Python CLI** (optional) | 25–35 | "Optional, secondary — for headless, CI/Linux, server-side, and automation use." 5–6 bullets: multi-sheet xlsx, self-contained HTML report, Jamf School reports, scheduled LaunchAgents, scaffold/check config tooling. "Python 3.11+; jamf-cli optional." One install line. Link to the wiki CLI Workflow page for everything else. |
| 6 | **Try it offline** | 15 | Keep the `./scripts/demo.sh` block (and `html`/`xlsx`/`mobile`/`school` variants) — it works for both audiences and needs no credentials. |
| 7 | **Documentation** | 8 | One prominent link to the wiki. One-line pointers: `CHANGELOG.md` for release history, `docs/testing.md` for the test suites, `docs/architecture/` for ADRs and the threat model. |
| 8 | **License & attribution** | 6 | MIT; HTML report design adapted from @DevliegereM; `NOTICE.md` trademark line. |

### Migration map — current README → destination

| Current README section (line) | Action | Destination |
|---|---|---|
| `macOS App` (8) | Rewrite, keep & expand | New README §4 |
| `What This Is` (50) | Condense to one paragraph | New README §4–5 |
| `Prerequisites` (86) — Python, pip, hash-pinned install, matplotlib | Move | Wiki **06 — CLI Workflow** |
| `Prerequisites` — jamf-cli install + `pro setup` | Move | Wiki **01 — Installation** |
| `Prerequisites` — **API permissions table** | Move (with the §1 caveat) | Wiki **01 — Installation** |
| `Prerequisites` — `protect.enabled` / `platform.enabled` YAML | Move | Wiki **04 — Configuration & Templates** |
| `Prerequisites` — multi-profile / `allow_live_overview` notes | Move | Wiki **04 — Configuration & Templates** |
| `Try It Offline` (237) | Keep | New README §6 |
| `Automated Tests` (275) | Replace with one-line pointer | `docs/testing.md` (stays in-repo) |
| `Releases` / `build-release.sh` (310) | Move | Wiki **06 — CLI Workflow** |
| `Quick Start` steps 1–7 (349) | Move | Wiki **06 — CLI Workflow** (CLI steps); Wiki **02 — App Onboarding** (app first-run) |
| `CLI Reference` (528) | Move | Wiki **06 — CLI Workflow** |
| `What Gets Generated` sheet table (791) | Move | Wiki **06 — CLI Workflow** |
| `Integrity envelope` (826) | Move | Wiki **08 — Diagnostics & Troubleshooting** |
| `Configuration Guide` (880) | Move | Wiki **04 — Configuration & Templates** |
| `Adapting Column Names` (1268) | Move | Wiki **04 — Configuration & Templates** |
| `Troubleshooting` (1300) | Move | Wiki **08 — Diagnostics & Troubleshooting** |
| `Getting Help` (1385) | Condense to 2 lines | New README §7 |

**Invariant:** the move of the Configuration Guide must preserve every config key name
exactly — `last_checkin` (not `last_contact`), `failures_count_column`,
`true_value`, `warning_threshold`, etc. (`CLAUDE.md` lists the common confusions). No
key is renamed by this overhaul.

---

## 5. New wiki structure

The wiki becomes **the single long-form home for operator documentation**, app-first.
It absorbs the useful app-centric content currently stranded in the `docs/` tree (§6).
The 8-page Python-CLI workflow is consolidated; the CLI is one comprehensive page,
reflecting its secondary status.

### Final page list & reading order

| # | Page file | Purpose |
|---|---|---|
| — | `Home.md` | Both products; audience-first "pick your path" routing. |
| 01 | `01-Installation.md` | Install the app (download release / build from source); install jamf-cli (`brew install Jamf-Concepts/tap/jamf-cli`); prerequisites; the API-permissions table. |
| 02 | `02-App-Onboarding.md` | The 7-step in-app Onboarding flow; first profile; first report; the no-CSV path. |
| 03 | `03-App-Dashboards.md` | Dashboard tour, one section per sidebar group; Settings → Sidebar Visibility. |
| 04 | `04-Configuration-and-Templates.md` | `config.yaml`, scaffolding, column mapping, the five custom-EA types, the five report templates, the Customize tab. |
| 05 | `05-Scheduling-and-Automation.md` | Schedules tab; the four run modes; collection-cadence presets (Refresh/Inventory/Scan); LaunchAgents (app + CLI `launchagent-setup`). |
| 06 | `06-Historical-Trends.md` | The Trends screen; `summary.json` snapshots; the metric picker; legacy history import. |
| 07 | `07-CLI-Workflow.md` | The optional Python CLI: when to use it, install, command reference, the Jamf Pro CSV path, the jamf-cli data path. |
| 08 | `08-Jamf-School.md` | Jamf School reporting — app `SchoolDashboard` and CLI `school-*` commands. |
| 09 | `09-Diagnostics-and-Troubleshooting.md` | The `diagnostic-bundle` command; troubleshooting; `[skip]` lines; exit codes; the report integrity envelope. |
| — | `Glossary.md` | Canonical vocabulary (from `docs/GLOSSARY.md`). |

**Reading order in `Home.md`:** app path = 01 → 02 → 03 → 04 → 05 → 06; CLI path =
01 → 07; everyone = 08 (if Jamf School), 09 + `Glossary` as reference. This is 9
numbered pages + Home + Glossary = 11 pages — versus today's 9 + Home. The growth is
the app pages (02, 03) that today exist only as stranded `docs/` files.

### Per-page outlines (section headers + one-line notes — not drafted prose)

**`Home.md`** — Rewrite.
- *One-paragraph intro* — what the project is; app is recommended, CLI is optional.
- *Pick your path* — two columns: "I want the macOS app" → 01–06; "I want the headless CLI" → 01, 07.
- *Try it offline* — pointer to `scripts/demo.sh`.
- *What this does not replace* — keep the existing jamf-cli links.

**`01-Installation.md`** — from wiki `01` (split) + `docs/onboarding/` prereqs.
- *Requirements* — macOS 14+; jamf-cli v1.16.1+ (optional); Xcode 16+ only to build from source.
- *Install the app* — download from Releases; or build (`cd app && ./build-app.sh release`), link `app/README.md`.
- *Install jamf-cli* — `brew install Jamf-Concepts/tap/jamf-cli`; `jamf-cli pro setup --url …`; one line on `jamf-cli platform setup`.
- *Jamf Pro API permissions* — the table from README, with the §1 caveat.
- *Verify* — `jamf-cli config validate -p <profile>`.

**`02-App-Onboarding.md`** — from `docs/onboarding/GETTING_STARTED.md` + `FIRST_RUN_CHECKLIST.md` + `WITHOUT_CSV.md`.
- *The 7-step onboarding flow* — welcome → installCLI → workspace → authenticate → validate → csvMapping → firstReport.
- *Where data lives* — `~/Jamf-Reports/<profile>/` workspace layout.
- *Your first report* — generate from the GUI.
- *Running without a CSV* — jamf-cli-only path; what CSV adds.
- *First-run checklist* — the printable tick-box list, as a closing section.

**`03-App-Dashboards.md`** — new; built from §2.
- One subsection per sidebar group — *Reports*, *Posture*, *Operations*, *Fleet*, *Automation*, *Configuration* — each a short paragraph naming its verified screens.
- *Sidebar Visibility* — how to hide unused tabs; core tabs cannot be hidden.
- Cross-links: Trends → page 06, Schedules → page 05, Config/Customize → page 04.

**`04-Configuration-and-Templates.md`** — from wiki `04` + `docs/templates/REPORT_TEMPLATES.md` + `CUSTOMIZATION_GUIDE.md`.
- *config.yaml overview* — point at `config.example.yaml` as canonical.
- *Scaffolding* — `scaffold` / `check`; the Customize tab; **one** wizard walkthrough (the `WITHOUT_CSV` / `CUSTOMIZATION_GUIDE` duplication collapses here).
- *Column mapping* — exact key names; the `Adapting Column Names` content.
- *Custom EA types* — boolean / percentage / version / text / date, with recipes.
- *Report templates* — the five shipping templates, audiences, cadences.
- *Platform & Protect opt-in* — `platform.enabled` / `protect.enabled` YAML.

**`05-Scheduling-and-Automation.md`** — Rewrite/merge of wiki `07` + `docs/operations/BACKGROUND_REFRESH.md`.
- *The Schedules tab* — create/edit a schedule in the app.
- *Run modes* — the four `Schedule.RunMode` cases, exact behavior (cite §2).
- *Collection cadence* — Refresh / Inventory / Scan tiers; On-prem / Cloud / Custom presets. **Delete every HOT/WARM/COLD reference.**
- *LaunchAgents* — what gets written; correct prefix `com.github.tonyyo11.jamf-reports-community.*`; `launchctl` inspection.
- *CLI path* — `launchagent-setup` for headless scheduling.

**`06-Historical-Trends.md`** — Rewrite of wiki `06` (drop the stale "Extensibility / Future Directions" tail).
- *Why history matters* — what a snapshot is.
- *The Trends screen* — metric picker, 4-week default, up to 52 weeks.
- *summary.json* — the snapshot files; the app and CLI chart paths share them.
- *Legacy history import* — importing v3.5 `fleet_health_metrics_history.json`.

**`07-CLI-Workflow.md`** — Merge of wiki `02` + `03` + `05` + README's CLI Reference / Quick Start / What Gets Generated.
- *When to use the CLI* — headless, CI/Linux, automation.
- *Install* — Python 3.11+, packages, hash-pinned install, matplotlib.
- *Command reference* — `generate`, `collect`, `inventory-csv`, `html`, `scaffold`, `check`, `backup`, `workspace-init`, `launchagent-setup/-run`, `capabilities`, `diagnostic-bundle`.
- *Jamf Pro CSV path* — export, scaffold, generate.
- *jamf-cli data path* — `collect` vs `generate`; cached snapshots.
- *Reporting cadence* — weekly/monthly rhythms.
- *Releases* — `build-release.sh`, the tag-driven release workflow.

**`08-Jamf-School.md`** — Rewrite (light) of wiki `08`.
- *When to use* — Jamf School tenants.
- *App path* — the `SchoolDashboard` screens.
- *CLI path* — `school-scaffold` / `school-check` / `school-collect` / `school-generate`; `jamf-cli school` commands. **Correct the v1.7 reference to the v1.16.1 floor.**

**`09-Diagnostics-and-Troubleshooting.md`** — new; from `docs/operations/TROUBLESHOOTING.md` + README troubleshooting + integrity envelope.
- *Diagnostic bundle* — what it bundles, redaction defaults, `--keep-*` flags, the app's "Copy Diagnostic Command" button, the `--no-redact` local-only warning.
- *Common failure modes* — PATH, expired token, slug regex, full disk, `[skip]` lines.
- *Exit codes* — the 0–6 table.
- *Report integrity envelope* — the `.sha256` sidecar and HTML `<meta>` fingerprint.

**`Glossary.md`** — Move `docs/GLOSSARY.md` verbatim; fix the stale entries (Hot/Warm/Cold tier entries; "24 dashboards" vs the verified count; the `pro sg` "once it ships" note).

### `_Sidebar.md` update

Replace the flat 9-link list with a grouped structure mirroring the new pages:

```
### jamf-reports-community

**Start here**
- [Home](Home)

**macOS app**
- [Installation](01-Installation)
- [App Onboarding](02-App-Onboarding)
- [Dashboards](03-App-Dashboards)
- [Configuration & Templates](04-Configuration-and-Templates)
- [Scheduling & Automation](05-Scheduling-and-Automation)
- [Historical Trends](06-Historical-Trends)

**Python CLI**
- [CLI Workflow](07-CLI-Workflow)

**Reference**
- [Jamf School](08-Jamf-School)
- [Diagnostics & Troubleshooting](09-Diagnostics-and-Troubleshooting)
- [Glossary](Glossary)
```

### Keep / rewrite / merge / split / retire — the 8 existing wiki pages

| Existing page | Decision | Becomes |
|---|---|---|
| `Home.md` | **Rewrite** | New `Home.md` — app-first, pick-your-path. |
| `01-Setup-and-Prerequisites.md` | **Split** | App/jamf-cli install → `01-Installation`; CLI-only setup → `07-CLI-Workflow`. |
| `02-Jamf-Pro-CSV-Workflow.md` | **Merge** | Into `07-CLI-Workflow` (CSV path section). |
| `03-jamf-cli-Workflow.md` | **Merge** | Into `07-CLI-Workflow` (jamf-cli data path); jamf-cli surface updated to v1.17, per-command version gates deleted. |
| `04-Config-and-Scaffolding.md` | **Rewrite** | New `04-Configuration-and-Templates` (absorbs `docs/templates/*`). |
| `05-Reporting-Cadence-and-Operations.md` | **Split & retire** | Cadence → `07-CLI-Workflow`; scheduling/operations → `05-Scheduling-and-Automation`; security guidance → `09-Diagnostics-and-Troubleshooting`. No standalone successor. |
| `06-Historical-Trends-and-Extensibility.md` | **Rewrite** | New `06-Historical-Trends` (stale "Extensibility/Future Directions" tail dropped). |
| `07-LaunchAgent-Automation.md` | **Rewrite & merge** | New `05-Scheduling-and-Automation` (absorbs `docs/operations/BACKGROUND_REFRESH.md`; HOT/WARM/COLD removed; plist prefix corrected). |
| `08-Jamf-School-Workflow.md` | **Rewrite (light)** | New `08-Jamf-School` (app path added; jamf-cli floor corrected). |

Every page survives contact with the §2 inventory — no proposed page describes an
unverified feature. The straw-man's separate `Diagnostic-Bundle` page is folded into
`09` rather than standing alone (one command does not need its own page); the
straw-man's `App-Dashboards` page is kept as `03`.

---

## 6. `docs/` vs `docs/wiki/` reconciliation

**Rule: one home per topic, split by audience.**

- **Operator-facing** content (how to install, configure, schedule, read dashboards,
  troubleshoot) → **the wiki**. Single home.
- **Contributor-facing** content that must stay versioned with the code it describes
  (ADRs, the threat model, the test-suite guide) → **`docs/` in the repo**. Single home.
- **The README** carries neither in full — it routes to both.

Applying that rule:

### `docs/` files — disposition

| File | Disposition |
|---|---|
| `docs/wiki/` | **Stays** — it is the wiki source (restructured per §5). |
| `docs/architecture/JAMF_CLI_FIRST.md` | **Stays in-repo** — contributor architecture narrative. |
| `docs/architecture/clibridge-error-typing-adr.md` | **Stays in-repo** — ADR. |
| `docs/architecture/tiered-collection-adr.md` | **Stays in-repo** — ADR. |
| `docs/architecture/jamf-reports-community-threat-model.md` | **Stays in-repo** — security artifact; fix the "not yet shipped" line. |
| `docs/testing.md` | **Stays in-repo** — add the missing Swift `swift test` section; keep the Python pytest section. |
| `docs/GLOSSARY.md` | **Move** → wiki `Glossary.md`. Delete the repo copy. |
| `docs/INDEX.md` | **Retire** — its only job was to bridge the two-doc-set split; once the split is gone it is obsolete. A short `docs/README.md` can replace it ("operator docs are in the wiki; ADRs and the threat model are here"). |
| `docs/onboarding/GETTING_STARTED.md` | **Merge** → wiki `01` + `02`. Delete. |
| `docs/onboarding/FIRST_RUN_CHECKLIST.md` | **Merge** → wiki `02` (checklist section). Delete. |
| `docs/onboarding/WITHOUT_CSV.md` | **Merge** → wiki `02` + `04`. Delete. |
| `docs/operations/BACKGROUND_REFRESH.md` | **Merge** → wiki `05`. Delete. |
| `docs/operations/TROUBLESHOOTING.md` | **Merge** → wiki `09`. Delete. |
| `docs/operations/RELEASE_NOTES_SUMMARY.md` | **Retire** — `CHANGELOG.md` is the canonical release record; this file is internal-phase scratch. Delete, do not merge. |
| `docs/templates/REPORT_TEMPLATES.md` | **Merge** → wiki `04`. Delete. |
| `docs/templates/CUSTOMIZATION_GUIDE.md` | **Merge** → wiki `04`. Delete. |

After reconciliation `docs/` contains exactly: `docs/wiki/`, `docs/architecture/` (4
files), `docs/testing.md`, and a small `docs/README.md`. The `onboarding/`,
`operations/`, `templates/` subtrees and `INDEX.md` / `GLOSSARY.md` are gone.

### Root `ARCHITECTURE.md`

`ARCHITECTURE.md` (root, 309 lines) is **not** in this session's off-limits list, and it
is the worst-drifted file in the repo (HOT/WARM/COLD scheduling, "16 screens," wrong
plist prefix, the false "Python CLI is a fallback / app bundles the script" claims). It
duplicates `docs/architecture/`. **Recommendation: retire it** — replace it with a short
pointer file ("system architecture is documented in `docs/architecture/`; operator docs
are in the wiki"), or fold any still-accurate diagram into `docs/architecture/` and
delete it. Leaving it as-is reproduces exactly the root-vs-tree drift this overhaul
exists to end. Flagged for maintainer decision in §10.

### `app/README.md`

Stays — it is the build-from-source reference and the wiki `01` page links to it. But it
is heavily stale (`dev-app/2.0` title, "12 screens," obsolete TODO list). It must be
de-staled. Because it is small and front-door-adjacent, fold its de-staling into the
README PR (§9, PR-A) rather than giving it a PR of its own. *(This session does not edit
it — the plan only schedules it.)*

---

## 7. Screenshot audit

**The maintainer supplied a fresh 28-capture v2.0 demo set on 2026-05-22**
(`~/Desktop/Screenshots/JamfReportsDemoScreenshot/`, timestamped 13:02–13:04). This set
**supersedes the 7 PNGs currently in `docs/wiki/images/`**. The in-repo 7 were reviewed
earlier and found to be genuine v2.0 captures but saved under scrambled filenames (every
file named a different screen than it contained). The plan no longer renames those 7 —
**PR-B deletes them and replaces them** with a curated selection from the new set.

All 28 new captures are v2.0-current and org-neutral: they use the built-in "Meridian
Health" demo tenant (the app's `DemoData` fictional org — no real tenant data), show the
shipped v2.0 sidebar grouping (REPORTS / POSTURE / OPERATIONS / FLEET / AUTOMATION /
CONFIGURATION / SYSTEM), and match the §2 code-verified layouts — the Config capture
shows the seven `ConfigTab` tabs; the Schedules capture shows the four run modes.

### The 28-capture source set (reviewed visually)

| Screen | Source file (`Screenshot 2026-05-22 at …`) |
|---|---|
| Overview — "Meridian Health Fleet Overview" | `1.02.56 PM` |
| Overview ▸ Stability Index (drill-in) | `1.02.59 PM` |
| Overview ▸ Top Failing Rules (drill-in) | `1.03.05 PM` |
| Overview ▸ Security Agents ▸ 1Password (drill-in) | `1.03.10 PM` |
| Fleet Overview — multi-profile roll-up | `1.03.13 PM` |
| Fleet Overview ▸ meridian-prod (profile drill-in) | `1.03.16 PM` |
| Devices — inventory + detail panel | `1.03.19 PM` |
| Historical Trends — default / Stability Index / FileVault metric | `1.02.52`, `1.03.30`, `1.03.34 PM` |
| Health Audit — Instance Health Audit (empty state) | `1.03.39 PM` |
| Security Posture — score ring | `1.03.45 PM` |
| Compliance Posture — bands | `1.03.53 PM` |
| Offline Outreach (two stale-tier tabs) | `1.03.56`, `1.04.01 PM` |
| Patch Compliance | `1.04.03 PM` |
| OS Updates | `1.04.08 PM` |
| Policies & Profiles — Policies tab / Profiles tab | `1.04.12`, `1.04.15 PM` |
| Extension Attributes | `1.04.17 PM` |
| Mobile Fleet | `1.04.19 PM` |
| Schedules — Scheduled Runs | `1.04.27 PM` |
| Config — Columns / Security Agents / Thresholds / Platform API tabs | `1.04.30`, `1.04.32`, `1.04.37`, `1.04.41 PM` |
| Customize — Customize Reports | `1.04.47 PM` |
| Data Sources | `1.04.49 PM` |

This covers 19 of the 24 navigable screens. **Not captured:** Device Lookup, Generated
(Reports), Run History, Settings, and — the only gap the docs care about — **Onboarding**.
The new set closes the two gaps the earlier draft of this plan flagged: an Overview shot
for the README hero, and a Schedules shot for wiki `05`, both now exist.

### Curated set for the docs (8 images)

Per small-set discipline, the wiki/README use a curated 8 — not all 28. PR-B copies these
from the source set into `docs/wiki/images/` under the names below.

| Wiki filename | Depicts | Source | Used on |
|---|---|---|---|
| `overview.png` | Overview — Meridian Health Fleet Overview | `1.02.56 PM` | README hero; wiki `Home`; wiki `03` |
| `devices.png` | Devices — inventory + detail panel | `1.03.19 PM` | wiki `03` |
| `security-posture.png` | Security Posture — score ring | `1.03.45 PM` | wiki `03` |
| `patch-compliance.png` | Patch Compliance | `1.04.03 PM` | wiki `03` |
| `mobile-fleet.png` | Mobile Fleet | `1.04.19 PM` | wiki `03` |
| `historical-trends.png` | Historical Trends (default view) | `1.02.52 PM` | wiki `06` |
| `schedules.png` | Schedules — Scheduled Runs | `1.04.27 PM` | wiki `05` |
| `config-editor.png` | Config — Columns tab | `1.04.30 PM` | wiki `04` |

`overview`, `devices`, `security-posture`, `patch-compliance`, and `mobile-fleet` give
wiki `03` one illustration per sidebar group (REPORTS / POSTURE / OPERATIONS / FLEET);
the other dashboards on that page are described in text. `historical-trends`,
`schedules`, and `config-editor` illustrate their dedicated pages.

**Alternates** — swap from the source set if a different shot reads better when a page is
written: Fleet Overview (`1.03.13`), Compliance Posture (`1.03.53`), OS Updates
(`1.04.08`), Extension Attributes (`1.04.17`), Policies & Profiles (`1.04.12`), Customize
(`1.04.47`), Data Sources (`1.04.49`), or any drill-in detail view. Keep the on-wiki
total at ~8.

### Still missing — one capture

The 28-shot set has **no Onboarding-flow capture**. Wiki `02` (App Onboarding) either
gets one screenshot the maintainer still must take (a step of the 7-step flow), or ships
without an image — see §10 Q6. This is the only outstanding screenshot dependency.

### Path note

Fix the broken `../images/` paths (wiki `02/05/06/07`) when the pages are rewritten. In
the in-repo source use `images/<file>.png`; that relative form also resolves once
published to the flat GitHub Wiki (§8).

---

## 8. Wiki publish workflow

There is **no automated sync**. `docs/wiki/` is the source of truth; the live wiki is a
separate repo published by hand. After a wiki content PR merges to `main`, the maintainer
republishes:

```bash
# 1. Clone the wiki repo (separate from the code repo) into a scratch dir.
cd /tmp
git clone https://github.com/tonyyo11/jamf-reports-community.wiki.git
cd jamf-reports-community.wiki

# 2. Mirror docs/wiki/ from a fresh checkout of main. The wiki repo is flat —
#    page files and images/ sit at the repo root, no docs/wiki/ prefix.
#    --delete removes pages retired by the restructure (old 01–08, etc.).
rsync -av --delete \
  --exclude='.git/' \
  /path/to/jamf-reports-community/docs/wiki/ ./

# 3. Review, commit, push. GitHub serves the wiki from the default branch.
git add -A
git status                       # confirm retired pages show as deletions
git commit -m "Sync wiki from docs/wiki/ @ <main short-SHA>"
git push origin master           # the .wiki.git default branch is 'master'
```

Notes for whoever runs this:
- The wiki repo is **flat** — `docs/wiki/Home.md` becomes `Home.md`, images land at
  `images/`. The in-repo `images/<file>.png` reference resolves correctly post-publish.
- `_Sidebar.md` is a GitHub Wiki convention file — it renders as the sidebar only on the
  live wiki, and must be at the wiki repo root.
- The first publish after the restructure deletes the old `01-`…`08-` pages; verify the
  `git status` deletion list before pushing so no page is orphaned with a stale URL.
- **Optional follow-up (not part of this overhaul):** a GitHub Actions workflow could
  automate steps 1–3 on push to `main` touching `docs/wiki/**`. Worth filing as its own
  enhancement issue; out of scope here.

---

## 9. Execution breakdown

### Pre-execution gate

Before any PR: file the **six unwired Views** from §2 (`WorkspaceView`,
`CustomizationWizard`, `HealthCheckView`, `GenerateSheet`, `AppToolbar`,
`WhatsNewBanner`) as a new checklist item under the **Dead code** section of
**Epic #104**. Rationale: §2's showcase excludes them; the epic is the authoritative
inventory per `CLAUDE.md`'s anti-churn rules; docs and code must agree on what exists
before the wiki describes the app.

### Proposed PRs — in order

| PR | Scope | Size | Depends on |
|---|---|---|---|
| **PR-A — README + app/README** | Rewrite `README.md` to the §4 outline (~150–220 lines). De-stale `app/README.md` (drop `dev-app/2.0`, fix "12 screens," remove the obsolete TODO list). | Medium | — |
| **PR-B — Wiki content** | Restructure all of `docs/wiki/` to §5: rewrite `Home.md` + `_Sidebar.md`, create `01`–`09` + `Glossary.md`, retire old `01`–`08`, fix image paths. Merge in the app-centric content from `docs/onboarding/`, `docs/operations/`, `docs/templates/`, `docs/GLOSSARY.md` (copy the content; the source files are deleted in PR-C). | Large | PR-A (so wiki links resolve against the new README) |
| **PR-C — docs/ retirement** | Delete `docs/onboarding/`, `docs/operations/`, `docs/templates/`, `docs/INDEX.md`, `docs/GLOSSARY.md` (content now lives in the wiki). Add `docs/testing.md`'s Swift section. Add a short `docs/README.md`. Retire root `ARCHITECTURE.md` per the §10 decision. Fix the threat model's "not yet shipped" line. | Medium | PR-B (content must exist in the wiki first) |
| **Manual — wiki publish** | Run §8 after PR-B merges. | Small | PR-B merged |

Splitting B and C matters: merging `docs/` content into the wiki without then deleting
the originals just rebuilds the two-doc-set problem this overhaul exists to remove.

### Per-file execution checklist

A future writing session can work straight down this list.

**PR-A**
- [ ] `README.md` — rewrite to §4 outline; verify final length is 150–250 lines.
- [ ] `README.md` — every config key name preserved exactly (no renames).
- [ ] `README.md` — jamf-cli references corrected per §1 (no v1.6; `-o json`).
- [ ] `app/README.md` — drop `dev-app/2.0`; fix screen count; remove obsolete "TODO" list; verify build commands against `app/build-app.sh`.

**PR-B**
- [ ] `docs/wiki/Home.md` — rewrite (app-first, pick-your-path).
- [ ] `docs/wiki/_Sidebar.md` — replace with the grouped §5 structure.
- [ ] Create `01-Installation.md` … `09-Diagnostics-and-Troubleshooting.md` (9 pages).
- [ ] Create `Glossary.md` from `docs/GLOSSARY.md`; fix its stale entries.
- [ ] Delete old `01-`…`08-` pages.
- [ ] Replace `docs/wiki/images/` — delete the 7 superseded scrambled-name PNGs; add the curated 8-image set (§7) copied and renamed from the maintainer's 2026-05-22 capture pool.
- [ ] Fix `../images/` → `images/` in every page that embeds an image.
- [ ] Every jamf-cli command string verified against §1; no pre-v1.16.1 version gates.
- [ ] No page describes a §2-excluded (unwired) View.
- [ ] Screen references match the 24-tab verified inventory.
- [ ] Plist prefix `com.github.tonyyo11.jamf-reports-community.*` everywhere.
- [ ] No HOT/WARM/COLD tier language anywhere.

**PR-C**
- [ ] Delete `docs/onboarding/`, `docs/operations/`, `docs/templates/`.
- [ ] Delete `docs/INDEX.md`, `docs/GLOSSARY.md`.
- [ ] Add `docs/README.md` (pointer: operator docs → wiki; ADRs → `docs/architecture/`).
- [ ] `docs/testing.md` — add the Swift `swift test` section.
- [ ] `docs/architecture/jamf-reports-community-threat-model.md` — fix "not yet shipped."
- [ ] Root `ARCHITECTURE.md` — retire per §10 decision.

**Manual**
- [ ] Run the §8 publish sequence; verify the deletion list before pushing.

---

## 10. Open questions for the maintainer

1. **Root `ARCHITECTURE.md` — retire or rewrite?** Recommendation: retire to a short
   pointer file (system architecture lives in `docs/architecture/`; operator docs in the
   wiki). It is the most-drifted file in the repo and duplicates `docs/architecture/`.
   Decide before PR-C.
2. **Does `docs/architecture/` stay in-repo, or move into the wiki as a contributor
   section?** Recommendation: **stay in-repo** — ADRs and the threat model should be
   versioned alongside the code that implements them, and the wiki is operator-facing.
   But this is a genuine fork in the road — confirm before PR-C.
3. **`CLAUDE.md` / `AGENTS.md` drift.** Both contain verified factual errors (the
   `Engine/` directory is omitted from the file tree; "27 screens" vs the verified 24;
   `LegacyHistoryImporter` described as "Triggered from SettingsView" with no UI caller).
   These are agent-orientation files, not user docs, so they are out of this overhaul's
   scope — but they should get a small correction pass. File as a standalone issue, or
   fold into Epic #104?
4. **Wiki auto-publish workflow.** §8 is manual. Worth a GitHub Actions workflow that
   syncs `docs/wiki/**` → the `.wiki.git` repo on merge to `main`? Recommendation: yes,
   as a separate enhancement issue after this overhaul lands — not bundled into PR-B.
5. **Releases bundle contents.** The current README's "Releases" section lists the files
   in the end-user zip (`jamf-reports-community.py`, `requirements*.txt`,
   `config.example.yaml`, `CHANGELOG.md`, `README.md`). With the README slimmed and the
   manual moved to the wiki, should the release zip also include a `CLI-WORKFLOW.md`
   (an export of wiki page 07) so offline CLI users still have the reference? Decide
   when writing wiki page 07.
6. **One screenshot still missing.** The maintainer supplied a 28-capture v2.0 demo set
   on 2026-05-22 covering Overview, Schedules, Config, and every dashboard (§7) — this
   closes the Overview-hero and Schedules gaps the earlier draft flagged. The only page
   still without an image is wiki `02` (App Onboarding): the 28-shot set has no
   onboarding-flow capture. Either the maintainer supplies one, or wiki `02` ships
   without a screenshot. Confirm.

### Conflicts with the existing backlog

`BACKLOG.md` indexes Epics #101 (Accessibility), #102 (Test coverage), #103 (Security &
silent-failure), #104 (Code hygiene). **This plan supersedes none of them.** It *adds*
one finding to Epic #104 (the six unwired Views — §9 pre-execution gate). Epic #104
already references `CustomizationWizard.swift:1283` as a live callsite for a
`CLIBridge.deviceDetail` migration — note for whoever files the dead-code item that the
*struct* `CustomizationWizard` is unreachable even though a line *inside* that file is
cited by an existing #104 task; the two are compatible (the file has live and dead
regions). No documentation epic exists today; if this overhaul is tracked as an epic, it
would be a new one, not a merge into #101–#104.
