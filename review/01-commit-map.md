# Phase 1 — Commit Map (origin/main..HEAD)

**Scope verification**

| check | expected | observed |
|---|---|---|
| current branch | `emdash/spotty-eels-shock-ngj6f` | matches |
| merge base vs `origin/main` | `b04519d` | matches |
| commits ahead | 157 | 157 |
| HEAD vs `origin/dev-app/2.0` | same SHA | both `cd3598e` |
| shortstat | ~384 files / ~89k+ / ~767− | 384 / 89,797 / 767 |

The entire `dev-app/2.0` lineage is in-scope.

## First-parent waves (33 merge points)

```
b60ea69  feat(app): scaffold native SwiftUI macOS GUI               2026-04-25
e26ca89  build(app): add build-app.sh wrapper                       2026-04-25
a4121df  feat(app): Spectrum icon, NSWorkspace, real CLI            2026-04-26
fafa510  Merge PR #37 emdash/3-reports-scan                          2026-04-26
643a1e0  Merge PR #38 emdash/4-onboarding                            2026-04-26
fead99b  Merge PR #39 emdash/5-trends-parser                         2026-04-26
cdd61cc  Merge PR #40 emdash/6-docs                                  2026-04-26
f0b91da  Merge PR #41 dedicated devices                              2026-04-26
e52e88e  feat: stable JSON summaries, Protect/School/Benchmark…     2026-04-26
8b2b732  refactor: security audit hardening                          2026-04-26
3fb77f9  Resolve jrc/python and ensure workspace init                2026-04-27
35386af  fix: resolve jamf-cli data dir from config                  2026-04-27
34f2e29  fix: trends summaries from historical_csv_dir               2026-04-27
8ecb900  fix: separate workspace-init from collect                   2026-04-27
399df40  Merge post-review-hardening                                 2026-04-27
477fb14  fix: preserve local hardening refinements                   2026-04-27
5235b12  Merge onboarding-auth-and-profile                           2026-04-27
5622198  fix: delegate LaunchAgent setup to Python                   2026-04-27
f59546e  fix: dedupe error strings in update_status                  2026-04-28
f9dd1a3  fix: normalize cached update errors                         2026-04-28
c31a9d7  Add source-aware jamf-cli updates                           2026-04-28
71476a3  Improve app scheduling and workspace handling               2026-04-28
d4376a7  Harden app automation and prune dead code                   2026-04-29
7f80fc2  fix: data integrity / error handling                        2026-04-30
8b53be8  feat: health audit + group hygiene reporting                2026-04-30
1656c86  Harden app security boundaries                              2026-05-03
7186a78  Merge PR #43 dependabot-workflows                           2026-05-04
4fc830f  Merge PR #44 emdash/fancy-ears-start                        2026-05-04
4e31788  Merge PR #45 emdash/app-dev-may (W21+W22)                   2026-05-04
791d074  Merge PR #49 emdash/big-flies-care (W23)                    2026-05-09
d412c62  fix(app): multi-agent functional bug review                 2026-05-09
f0b6161  Merge PR #53 jamf-cli-sync-v1.17.0-app                      2026-05-14
cd3598e  Merge PR #55 emdash/lovely-rivers-stay-v0ryv (smart-group)  2026-05-15
```

## Thematic waves

### W0 — Scaffold (April 25-26, 3 commits)
`b60ea69`, `e26ca89`, `a4121df`. Initial SwiftUI app scaffold + build script +
icon/NSWorkspace integration. Roughly +30k lines (entirely new files under
`app/Sources/JamfReports/`). Sets the architecture: SwiftPM executable target,
macOS 14+, Swift 6 strict concurrency, `@Observable` state, services-based.

### W1 — Wave-1 PRs (April 26, PRs #37-#40)
Four feature merges: reports-scan, onboarding, trends-parser, docs. Each was a
fresh emdash session. CHANGELOG.md merge conflict resolved at `8ed191b`. Files
mainly added under `app/Sources/JamfReports/Views/` and `Services/`.

### W2 — Dedicated devices screen (April 26, PR #41)
`780a9e6`, `974ceda`, `86f718a`, `f0b91da`. Introduces `DevicesView`,
`DeviceInventoryService`. Annotation evaluation bug fixed immediately
(`974ceda`) — same wave self-correction.

### W3 — Stable JSON + dashboard pack (April 26)
`e52e88e` — single commit, large surface: `summary.json`, Protect/School
services, unified history, Fleet Drift, config tabs, trend charts. Touches
many existing Wave-1 files.

### W4 — Security audit hardening + workspace plumbing (April 26-28)
`8b2b732` (security audit hardening) immediately followed by `3fb77f9` and
six `fix:` commits over April 27 reverting and re-applying parts of the
workspace path resolution. This is the **first dense fix cluster** — likely
candidate for churn drilling.

- `8b2b732` refactor security audit hardening
- `3fb77f9` resolve jrc/python and ensure workspace init
- `4e4c130` profile-aware jamf-cli admin workflows
- `1a1f6e7` post-review hardening across CLI bridge, trends, summary JSON
- `35386af`, `34f2e29`, `8ecb900`, `b41184f` — four consecutive fixes
- `399df40` merges `fix/post-review-hardening`
- `477fb14` preserve local hardening refinements
- `5235b12` merges `fix/onboarding-auth-and-profile`
- `5622198` delegate LaunchAgent setup to Python (then later moved back to Swift?)
- `f59546e`, `f9dd1a3`, `c31a9d7`, `71476a3` source-aware updates + scheduling

### W5 — Hardening + health audit (April 29-30)
`d4376a7` (harden automation + prune dead code), `7f80fc2` (data integrity),
`8b53be8` (group hygiene), `1656c86` (harden security boundaries), `134a691`
(additional tests). Stabilizes after W4 chaos.

### W6 — Dependabot + CI infrastructure (May 4, PR #43-#44)
`6652250`, `005d7bc` dependabot config; `7181f4c`, `c84b5a5` CI fix for Swift
6 concurrency on macos-latest. Dual dependabot config commits (`6652250` and
`005d7bc`) — possible duplicate work.

### W7 — W21+W22 jamf-cli v1.14 graduation + Swift app polish (May 4, PR #45)
`dbc9f99`, `12bfdf5`, `69d705c`, `fae9f65`, `fe94fd4`. Lifts jamf-cli floor to
v1.14, graduates Platform + Protect to first-class. Polish layer: Issues
filter, API scope, token status, console links.

### W8 — Frontend design polish + W23 Sparkle/Protect/Device Lookup (May 4-5)
`fadc144` design polish across 8 views, `8ab6e9d` `0244c4d` `d8f850e`
`c88fe03` four follow-up fixes the same day. `81269f7` align fixtures.
`fe299e8` W23 Protect standard pack + Device Lookup + Sparkle + consoleURL.

### W9 — May-9 multi-agent review wave (PR #49)
`9aa5124` (MUST-FIX issues + tests from pass-4), `5ce53ec` (5-agent parallel
review), `0d00e00` (ARCHITECTURE.md), `841bfcb` (gitignore AI artifacts), six
`fix(ci):` commits chained (`2ceffe5` `9cbefce` `7150e50` `b1c1dc9` `a8cd190`
`8a414b3`), `8a414b3` last CI fix. **High fix density — second churn cluster.**

### W10 — Post-review functional bug review (May 9)
`d412c62` corrects functional bugs from multi-agent review (PR #49 just
merged). `c68930b` impl/all-units (UX + retention + dev tooling, +20+ files).
`7f188b4`, `c31df46` two test fixes immediately after.

### W11 — Post-PR-50 hardening + retention (May 9-10)
`7fb6543` codesign check + canonicalize CSV paths, `ee745f9` address findings
from multi-agent security/silent-failure/test-coverage review.

### W12 — May-13 carry-forward + design review 3 wave + a11y (May 13)
`05d9a67` (packaging + UI overhaul + schedule-fix), `c21f32e` (carry-forward
dashboards/services/tests/docs from prior emdash sessions) — **note this is a
catch-up commit, suggesting earlier emdash session content was reapplied**.
Then 4-stage design polish (`2057d76` `1df5907` `6e9f1a5` `3a2d3c4`),
WCAG 2.1 audit, Dynamic Type adoption, then a 22-commit polish chain (1.1–7.1
each focused). Also `9804b69` schedules multi-profile Run now, `5d69c28`
yaml/cli stdout leak fixes, `5d920b3` PR review findings.

### W13 — May-14 polish, docs, ruff, security routing (May 14)
`e9b4dbb`, `ed41516` docs sync; `459bc03`, `2aea5bf`, `0455344`, `fc7ec4d`,
`5cdb257`, `04de079`, `54fa3b5`, `329d0bb`, `7c9441a`, `5f34947`, `ac54165`,
`9994192`, `63af86d`, `3d140da`, `be34de2`, `7a698b4`, `4795689` — eighteen
small commits in one morning. **Highest commit-rate cluster.** Largely
security/python/test additions.

### W14 — jamf-cli v1.17.0 sync (May 14, PR #53/#54)
`8f44536`, `13f7fa3` (note **two identical-subject commits**, both syncing to
v1.17.0 — duplicate or amend pattern), `2be97df` (split RunsView for CI type
checker), then merge-chain `f0b6161` `7e54ec7` `1f08a63` `495b805` `d7caf62`.

### W15 — Smart-group integration (May 14-15, PR #55)
`d772b30` (Stage 1, read-only), `5f9c1c7` (Stage 2 apply + sheet), `37f2df1`
`adcb7c8` `c66fe83` `831df8d` (Stages 3.1-3.4 view wiring), `04fff30`
(post-integration fix: stderr + exit code dispatch), `9cbc88a` docs (v1.17.0
shipped without PR #205 upstream), `f80753b` (contract drift discovered against
live PR #205 build), `2ae28e7` (defaultName guards empty slug). Note the
last three fixes are this-branch self-corrections of the just-shipped feature.

## Adjacent waves touching the same files (churn candidates)

| adjacent waves | shared touch surface | drill priority |
|---|---|---|
| W3 ↔ W4 ↔ W5 | `WorkspaceStore`, `OnboardingFlow`, `JamfCLIBridge` Python + Swift | **high** |
| W9 ↔ W10 ↔ W11 | `CLIBridge.swift`, `ReportEngine.swift`, `OnboardingFlow.swift` | **high** |
| W12 ↔ W13 ↔ W14 ↔ W15 | `RunsView.swift`, `SchedulesView.swift`, `Sidebar.swift`, `Views/*` | **very high** |
| W7 ↔ W8 | `Models.swift`, `OverviewView.swift`, dashboard views | medium |
| W8 ↔ W12 | `TrendsView.swift`, `Theme/Components.swift` | medium |

These are the wave-pair candidates for churn analysis in Phase 2.

## Top-25 hottest files (`git log --name-only | sort | uniq -c | sort -rn`)

```
25 CHANGELOG.md                                                  ← expected
24 jamf-reports-community.py                                     ← single-file Python engine, expected
22 app/Sources/JamfReports/Views/SchedulesView.swift             ← churn candidate
22 app/Sources/JamfReports/Services/CLIBridge.swift              ← churn candidate
20 app/Sources/JamfReports/Services/WorkspaceStore.swift         ← churn candidate
19 app/Sources/JamfReports/Views/TrendsView.swift                ← churn candidate
18 app/Sources/JamfReports/Views/Sidebar.swift                   ← churn candidate
14 app/Sources/JamfReports/Theme/Components.swift
14 BACKLOG.md                                                    ← expected (tracking doc)
13 app/Sources/JamfReports/Views/OverviewView.swift
13 app/Sources/JamfReports/Models/Models.swift
12 app/Sources/JamfReports/Views/RunsView.swift
12 app/Sources/JamfReports/Services/LaunchAgentWriter.swift
11 app/Sources/JamfReports/Views/SettingsView.swift
11 app/Sources/JamfReports/Views/DevicesView.swift
10 app/Sources/JamfReports/Views/ConfigView.swift
10 app/Sources/JamfReports/App/ContentView.swift
 9 UpdatesView / SecurityPostureView / CompliancePostureView / AuditView
 8 SourcesView / ReportsView / OutreachView / TrendStore / ProfileService / OnboardingFlow / JamfCLIInstaller
```

## Phase 2 drill targets (top 10)

Tracking-file count (CHANGELOG, BACKLOG) excluded — they're meta. Top 10 code
files for Phase 2 churn drill:

1. `jamf-reports-community.py` (24)
2. `app/Sources/JamfReports/Views/SchedulesView.swift` (22)
3. `app/Sources/JamfReports/Services/CLIBridge.swift` (22)
4. `app/Sources/JamfReports/Services/WorkspaceStore.swift` (20)
5. `app/Sources/JamfReports/Views/TrendsView.swift` (19)
6. `app/Sources/JamfReports/Views/Sidebar.swift` (18)
7. `app/Sources/JamfReports/Theme/Components.swift` (14)
8. `app/Sources/JamfReports/Views/OverviewView.swift` (13)
9. `app/Sources/JamfReports/Models/Models.swift` (13)
10. `app/Sources/JamfReports/Views/RunsView.swift` (12)

## Calibration note

The branch-review prompt left `TODO` markers under each "what counts as wasted/
regression" block — the examples printed above each `TODO` are being treated
as the operative calibration. This is called out in the final REPORT.md.
