# Phase 2 — Churn / Wasted-Change Inventory

Scope: top-10 hottest code files on `origin/main..HEAD` plus targeted
symbol-level archaeology for suspected flip-flops.

## Headline waste finding (high-confidence)

### F1. 8 services/views added then deleted as "dead code" 3 days later

**Files** (all under `app/Sources/JamfReports/`):

| file | added | size at add | deleted | size at delete |
|---|---|---|---|---|
| `Services/JamfProtectSnapshotService.swift` | `e52e88e` 2026-04-26 | 406 | `d4376a7` 2026-04-29 | 406 |
| `Services/JamfSchoolSnapshotService.swift`  | `e52e88e` 2026-04-26 | 280 | `d4376a7` 2026-04-29 | 280 |
| `Services/PlatformBenchmarkService.swift`   | `e52e88e` 2026-04-26 | 374 | `d4376a7` 2026-04-29 | 374 |
| `Services/UnifiedHistoryService.swift`      | `e52e88e` 2026-04-26 | 195 | `d4376a7` 2026-04-29 | 195 |
| `Views/JamfProtectStatusView.swift`         | `e52e88e` 2026-04-26 | 204 | `d4376a7` 2026-04-29 | 204 |
| `Views/JamfSchoolStatusView.swift`          | `e52e88e` 2026-04-26 | 255 | `d4376a7` 2026-04-29 | 255 |
| `Views/PlatformBenchmarkView.swift`         | `e52e88e` 2026-04-26 | 202 | `d4376a7` 2026-04-29 | 202 |
| `Views/UnifiedHistoryView.swift`            | `e52e88e` 2026-04-26 | (n/a) | `d4376a7` 2026-04-29 | ~250 |

Total deleted as "dead code": **~2,171 lines, 8 files, 3 days alive**.

`e52e88e`'s body even self-describes each removed item ("JamfProtectSnapshotService:
discover and index Protect JSON caches, count trends" etc.). The next first-parent
commit on `dev-app/2.0` that touches the same domain is `8b53be8` (Apr 30, "feat:
add health audit and group hygiene reporting"), and then the real replacement
services land much later in `c21f32e` (May 13, "carry forward dashboards, services,
tests, and docs from prior emdash sessions") with different names and shapes:

- `ProtectDashboardService.swift` (235 lines, different shape from `JamfProtectSnapshotService`)
- school is folded into the Python-side `SchoolDashboard` + `SchoolColumnMapper`
  (the Swift `JamfSchoolSnapshotService` has no direct Swift replacement)
- `PlatformBenchmarkService` has no direct replacement — `AuditView` covers part
  of the surface and the v3.5-port wave's `CompliancePostureService` covers
  control-gap counting.
- `UnifiedHistoryService` has no direct replacement — `RunHistoryService`,
  `TrendStore`, and `ReportLibrary` each cover a slice.

**Verdict**: classic "feature scaffolded but never wired to the UI" pattern. The
commit message `d4376a7 Harden app automation and prune dead code` is a one-liner
with no body, so the reasoning isn't captured. From the diff this is a net
loss of −72 lines (2,121 insertions / 2,193 deletions) — most of the deletions
are these 8 files; the insertions are real W5 hardening work.

**Cost framing**: ~2,200 lines AI-generated + reviewed + landed + deleted. Mid-sized
fully wasted iteration. Replaced by smaller, differently-shaped services 17 days
later.

---

## Confirmed within-branch self-corrections

### F2. `c88fe03` reverts `fadc144`'s `layoutPriority(1)` 75 min later

- `fadc144` 2026-05-04 16:29:56 "feat(ui): design polish across 8 views" — added
  `.layoutPriority(isPrimary ? 1 : 0)` to `OverviewView.statRow` HStack tiles.
- `c88fe03` 2026-05-04 17:43:16 "fix(ui): adaptive grid for Overview stat tiles
  instead of HStack with layoutPriority" — replaced HStack with `LazyVGrid` and
  *dropped* the just-added `.layoutPriority` modifier.

Commit body of `c88fe03` admits the root cause: "the W21 design polish gave the
primary 'Stability' tile `.layoutPriority(1)` to differentiate it. Combined with
`.frame(maxWidth: .infinity)` on every tile via the StatTileHealth modifier,
SwiftUI handed every spare point to the priority-1 tile and starved the others."

This is a same-day Claude-on-Claude correction discovered when the previous
commit was tested on a remote Mac.

**Cost**: small (one modifier added, one helper rewritten), but a clear marker
that the W21 design polish wasn't visually verified before merging.

### F3. Two literal-duplicate "sync to jamf-cli v1.17.0" commits

- `8f44536` 2026-05-14 15:15:57 (parent `d412c62`)
- `13f7fa3` 2026-05-14 15:16:25 (parent `4795689`)

Both are 13-line patches touching the same two files (`.jamf-cli-tracked-version`
and `CHANGELOG.md`), with identical bodies including the same Claude session URL
`https://claude.ai/code/session_014HuYWuLEMZpZktQ63W3duz`. Both reach HEAD via
the `f0b6161 Merge PR #53 jamf-cli-sync-v1.17.0-app` merge tree. The second
patch is a no-op because the file is already at v1.17.0; the CHANGELOG entry it
adds is a duplicate of the one in `8f44536`.

**Cost**: trivial (1 line of code + 12 lines of CHANGELOG re-added), but a
recurring symptom that the same Claude session was cherry-picked into two
branches and both landed.

### F4. SchedulesView exit-code parser was added then rewritten ~1h later

- `2d9e661` 2026-05-13 18:07:23 "views: schedules exit-code pill always shows
  code + icon (5.2)" — added the
  `msg.components(separatedBy: "exit ").last.flatMap(Int.init) ?? -1` parser
- `7a698b4` 2026-05-14 09:02:27 "fix: replace brittle SchedulesView exit-code
  parser with regex" — replaced the parser with a regex and 10 unit tests.

The `7a698b4` body attributes the rewrite to *Gemini's 2026-05-14 security
review SHOULD-FIX*, not a self-discovered bug. So the parser was brittle from
day-one of its introduction (`2d9e661`); the rewrite came from external feedback
~14 hours later. Acceptable iteration, but the parser had two known failure
modes the first-pass implementation didn't anticipate.

**Cost**: small (~26 lines of view + 84 lines of tests, plus the original parser
discarded). Acceptable when triaged through review, but is a marker that the
W12 polish wave (which produced `2d9e661`) wasn't testing the value-format
edge cases at commit time.

---

## Per-file iteration verdicts (top 10)

| file | commits | verdict | rationale |
|---|---|---|---|
| `jamf-reports-community.py` | 24 | **intentional iteration** | Each commit adds non-overlapping surface (school, partial-success status, ruff, _safe_write routing). No same-function rewrites. |
| `Views/SchedulesView.swift` | 22 | **intentional iteration** + 1 churn (F4) | Most commits are scoped polish (Dynamic Type, popover height, exit-code icon). One brittle parser → regex rewrite within ~14h. |
| `Services/CLIBridge.swift` | 22 | **intentional iteration** | W4 hardening + later review-driven hardening. No function rewritten ≥2x with no caller change. |
| `Services/WorkspaceStore.swift` | 20 | **intentional iteration** | Mostly additive: new methods/properties for new dashboards. `c21f32e` (carry-forward) adds a large block; `c68930b` adds `hasUnsavedChanges`; W4 commits add profile-aware methods. |
| `Views/TrendsView.swift` | 19 | **intentional iteration** | Scoped polish chain (1.2, 2.1, 2.2, … 3.5). Each commit has a single-issue scope per W12 plan. |
| `Views/Sidebar.swift` | 18 | **intentional iteration** | Sidebar surface tier work + Dynamic Type adoption. Multiple commits because of the deliberate granular polish numbering scheme. |
| `Theme/Components.swift` | 14 | **intentional iteration** | Design-system file — high churn during W12 a11y/contrast/Dynamic-Type sweep is expected. |
| `Views/OverviewView.swift` | 13 | **intentional + 1 churn (F2)** | One self-correction same-day (`fadc144` → `c88fe03`). Otherwise scoped polish. |
| `Models/Models.swift` | 13 | **intentional iteration** | Additive field/enum growth for new dashboards. |
| `Views/RunsView.swift` | 12 | **intentional + 1 CI-driven split** | `2be97df fix: split RunsView.runListItem to keep CI Swift type-checker under budget` is a Swift-compiler-driven split, not a feature regression — reasonable. |

---

## W4 hardening cluster — verdict

The Apr 27 cluster (12 commits in 8 hours touching `WorkspaceStore`, `CLIBridge`,
`OnboardingFlow`, `ProfileService`) is **legitimate fix-sprint, not waste**. Each
commit has a distinct concern:

- `3fb77f9` resolve jrc/python (CSV vs jamf-cli source plumbing)
- `4e4c130` profile-aware admin workflows (new feature)
- `1a1f6e7` post-review hardening (post-review checklist)
- `35386af` data-dir from config
- `34f2e29` summaries from configured dir
- `8ecb900` separate workspace-init from collect (logic separation)
- `b41184f` onboarding auth + scaffold profile propagation
- `477fb14` "preserve local hardening refinements" — explicit merge-rescue commit
- `5622198` delegate LaunchAgent setup to Python (architecture refinement, not flip-flop — LaunchAgentWriter.swift kept growing)

The two `Merge branch 'fix/...' into fix/...` commits (`399df40`, `5235b12`)
reflect real branch coordination, not Claude rebasing on itself.

**Verdict**: intentional iteration, no wasted commits in this cluster.

---

## W9 CI-fix chain (May 9) — verdict

Six consecutive `fix(ci):` commits in 37 minutes:
`2ceffe5` `9cbefce` `7150e50` `b1c1dc9` `a8cd190` `8a414b3`. Each fixed a
specific CI failure (Bool? switch, dependabot ecosystem, MainActor hop,
nonisolated(unsafe), async setUp, env-dependent assertions). This is normal
"watch CI fail, fix, push" cadence, not waste.

**Verdict**: legitimate; CI feedback loop. Each commit moved the green-bar
further.

---

## Renames / moves on branch

`git log --diff-filter=R` returns empty — **zero renames** in the 157-commit
range. Files are added and (rarely) deleted but never renamed within branch.

---

## Symbol-level archaeology probes

Negative results worth noting:

- `ensureWorkspaceInitialized` — search returned no commits with `git log -S` on
  either `WorkspaceStore.swift` or `OnboardingFlow.swift`. The introduce/move
  pattern isn't present at the symbol level for this name.
- `LaunchAgentWriter.swift` was added in `e52e88e` (Apr 26) and never deleted;
  current size 1,051 lines. The "delegate LaunchAgent setup to Python" commit
  (`5622198`) modified 211 lines and added 158 (net +53), so the file kept
  growing — there is no Swift→Python→Swift flip-flop in the file's lifecycle.

---

## Summary table

| finding | severity | scope | commits |
|---|---|---|---|
| F1: 8 dashboards/services added → "dead code"-deleted 3d later (~2,171 lines) | **high** | branch-only waste | `e52e88e` → `d4376a7` |
| F2: `OverviewView` `layoutPriority(1)` added then reverted 75 min later | low | branch-only waste | `fadc144` → `c88fe03` |
| F3: Two literal-duplicate v1.17.0 sync commits | low | branch-only waste | `8f44536` ≡ `13f7fa3` |
| F4: SchedulesView exit-code parser brittle from intro, replaced 14h later | low | branch-only waste | `2d9e661` → `7a698b4` |

Total quantifiable AI-iteration waste this branch: **~2,250 lines added and
then removed on the same branch with no replacement in HEAD**, almost all from F1.
Other 156 commits are intentional iteration.

---

## What was NOT flagged

- Pre-existing files modified many times in waves of incremental scope (e.g.
  `RunsView` polish 1.1 → 6.3, `TrendsView` polish 1.2 → 3.5). These follow a
  numbered polish plan and aren't symptomatic of self-correction.
- The Sparkle integration in W23 — touches many files but each touch is
  feature-additive.
- The carry-forward commit `c21f32e` (May 13, +10,859 lines / −60) is a real
  feature merge from prior emdash sessions, not waste. The PR description in the
  body enumerates every new service/view/test.
