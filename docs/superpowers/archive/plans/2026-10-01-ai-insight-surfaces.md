# On-device insight on more screens

Owner decisions (2026-10-01): one shared insight seam instead of per-screen copies; insight
cards on Trends, Security Posture + Compliance Posture, and Audit; the never-built
`ai.tier: external` is removed. All model calls stay on-device (Apple Foundation Models,
macOS Golden Gate 27, opt-in through the `ai:` block). No Private Cloud Compute code or
tracking of any kind.

The existing layer is described in `CLAUDE.md`, paragraph "Intelligence layer (2.5.0 — opt-in,
macOS 27+, off by default)". Files: `app/Sources/JamfReports/Intelligence/`,
`Views/AIInsightCard.swift`, `AIConfig` in `Engine/ConfigDecoder.swift`.

## Global Constraints

- Work only inside your worktree. Do not push, open a PR, or edit GitHub issues.
- Do not edit `CHANGELOG.md`, `CLAUDE.md`, `AGENTS.md` or `BACKLOG.md`; put the proposed
  CHANGELOG line in your report.
- Before the first edit of each file, run `git log --oneline origin/main..HEAD -- <path>` and
  put the count in your report. At 3 or more, state why your change does not undo that work.
- One commit per logical change. Subject `<type>(ai): <imperative, ≤72 chars>`, no attribution
  or co-author trailers. Do not use: critical, crucial, essential, significant, comprehensive,
  robust, elegant.
- Test first. Tests never run the real model, never read the real `~/Jamf-Reports`, never run
  `jamf-cli`, and clean up `UserDefaults` keys with a per-test `defer` (no `tearDown` override
  on a `@MainActor` test class). A test class for a SwiftUI `View` type carries class-level
  `@MainActor`.
- Swift 6 strict concurrency; CI compiles with Swift 6.1 (stricter about `@MainActor` than the
  local 6.4) and with a toolchain that has no FoundationModels, so everything outside
  `#if canImport(FoundationModels) && compiler(>=6.4)` must build and pass without it. No
  force-unwrap in production code, functions ≤100 lines, lines ≤100 columns, no new package
  dependency, no new Service/View/Model file without a caller in the same commit.
- Privacy rule for every prompt input: aggregates only. No device names, serials, usernames,
  email addresses, host names, extension-attribute values or free text from a CSV. Names of
  metrics, security controls, macOS versions and audit categories are allowed. Every adapter
  has a test that builds its input from a fixture containing a device name, serial and
  username and asserts none of them appears in `promptContext`.
- Model output is untrusted text: rendered as plain text only, never as markup, never executed.
- A screen's card is hidden entirely when `ModelAvailability.platformSupported` is false, when
  `ai.enabled` is false, and in demo mode. It never blocks or delays the screen's own data.
- Do not change SwiftUI layout primitives beyond inserting the card where the task says; a
  commit that inserts a card carries `DRAFT — needs visual verification` in its body.
- Gate before each commit, from `<worktree>/app`:
  `swift build --build-tests 2>&1 | grep "error:" || echo OK`, then
  `swift test --filter '<SuiteA>|<SuiteB>'` for the suites you touched. Report actual counts.
- If something does not reproduce or a task would pass ~250 changed source lines, stop and
  report instead of building it.

## Task 1: Remove the external tier and the Private Cloud Compute wording (G28)

Files: `Engine/ConfigDecoder.swift` (`AIConfig`, `AIExternalConfig`), `Intelligence/*.swift`
(`GeneratorKind`, the `.external` branches in every conformer and factory),
`Intelligence/ModelAvailability.swift`, `Views/SettingsView.swift` (AI panel),
`Views/AIInsightCard.swift` (`tierLabel`), `config.example.yaml`, tests.

1. Delete the `external` tier: the `Tier` case, `AIExternalConfig`, the `GeneratorKind` case,
   every `.external` branch, and the keys that only served it in `config.example.yaml`.
2. Backward compatibility is the decoder's existing unknown-value fallback: a config that says
   `tier: external` (or the legacy `tier: pcc`) resolves to on-device, and a stale `external:`
   sub-block is ignored. Add a decode test for both. The next Settings save writes the
   normalized block (`AIConfigWriter`).
3. The Settings AI panel and its doc comment no longer mention Private Cloud Compute or an
   external provider. The panel says the model runs on this Mac and nothing leaves it.
4. `ModelAvailability` no longer has a path that reports ready for a tier that cannot run.
5. Out of scope: any new tier, any network call.

## Task 2: One generic insight seam, with both-sides wording (Fleet Insight inversions)

Files: `Intelligence/FleetInsight.swift`, `Intelligence/FleetInsightGenerator.swift`,
`Intelligence/FoundationModelsInsightGenerator.swift`, `Views/AIInsightCard.swift`,
`Views/OverviewView.swift` (the one call site), tests.

Background: on a live fleet the card wrote "OS is not current on 0.0% of devices" for the
input line `OS current: 0.0%` and "SIP and Firewall are disabled on 1.0% and 0.0%" for
`SIP enabled: 1.0%`, `Firewall enabled: 0.0%`. Nothing in the prompt states polarity, and
deltas print `%` where they mean percentage points.

1. Generalize the input. Replace the `DailySummary`-specific fields of `FleetInsightInput`
   with a generic shape and keep the type name:
   `struct FleetInsightInput { let title: String; let focus: String; let facts: [Fact]; let notes: [String] }`
   and `struct Fact { let label: String; let value: Value; let prior: Value?; let polarity: Polarity }`
   where `Value` is `.percent(Double)`, `.count(Int)` or `.text(String)` and `Polarity` is
   `.higherIsBetter`, `.lowerIsBetter` or `.neutral`. The existing `DailySummary` mapping moves
   into `static func fleet(current: DailySummary, previous: DailySummary?) -> FleetInsightInput`
   and produces the same facts as today. Keep `safeDate` and `budget`.
2. `promptContext` states both sides of every percentage whose complement is meaningful:
   `- SIP enabled on 1.0% of devices; not enabled on 99.0%`. For "OS current" the complement
   reads `not on the newest release of its macOS version, or version not listed`. Changes
   versus the prior value print as percentage points (`+2.0 pp`), counts as signed integers.
   A fact with `.neutral` polarity prints its value only.
3. The model instructions gain two sentences: every percentage is the share of devices where
   the named control is on or the named state is true; say which direction is good using the
   line's own wording, never restate a percentage as its opposite. The per-screen `focus`
   goes in the prompt header, not in `instructions`, so the prewarmed session is unchanged.
4. `AIInsightCard` takes `title`, `idleText`, `provenanceText` and `input: FleetInsightInput?`
   as parameters; it hides itself per the Global Constraints (fold the
   `ModelAvailability.platformSupported` and demo-mode checks that the Overview does today
   into the card), and clears a shown insight when `input` changes (today a stale insight
   stays after a refresh). The Overview call site passes `.fleet(current:previous:)` and
   renders exactly as before.
5. Tests: `promptContext` golden lines for the two reported inputs (both sides present, `pp`
   for deltas); the `fleet` factory yields the same facts as before; card invalidation on
   input change through its view-model/state, not by rendering.
6. Manual check, reported not automated: on this macOS 27 host run the two reported inputs
   through the on-device model five times each with the `fm` command-line tool (`man fm`),
   using the new instructions and prompt text, and paste the outputs in your report. If `fm`
   is unavailable or the model is not enabled, say so; do not add a live-model test.
7. Out of scope: `RunFailureExplaining` and `ReportNarrativeGenerating` stay as they are.

## Task 3: Trends insight

Files: `Views/TrendsView.swift`, the service that already computes the Trends series
(`TrendStore` and/or `PeriodReportModel`), tests.

Consumes from Task 2: `FleetInsightInput(title:focus:facts:notes:)`, `Fact`, `Value`,
`Polarity`, and `AIInsightCard(title:idleText:provenanceText:input:)`.

1. A pure adapter (a static function next to the existing series code, no new file unless the
   host file would pass 100 lines for it) builds the input from what the screen already
   shows for the selected range: for each metric with data, its value at the start and end of
   the range and the change; plus the stability index when the screen shows one. Start and end
   dates go in `notes` through `safeDate`. A metric with fewer than two points in the range is
   left out; if no metric qualifies the input is nil and the card shows its idle text.
2. Focus line: which metrics moved together or against each other over the period, and which
   change matters most. Title: "Trend insight".
3. The card sits under the hero block, above the charts. It follows the selected range: a
   range change replaces the input (and so clears the shown insight).
4. Tests: adapter facts for a three-summary fixture; nil for a single summary; the privacy test.

## Task 4: Security Posture and Compliance Posture insight

Runs after the security-policy work has merged, because the inputs come from it.

Files: `Views/SecurityPostureView.swift`, `Views/CompliancePostureView.swift`,
`Services/SecurityPostureService.swift` / `Services/CompliancePostureService.swift` (adapter
only), tests.

Consumes from Task 2: the same types and card as Task 3.

1. One adapter serves both screens: per control, the share passing, and the counts classed as
   failing and as warning under the workspace's security policy; P0 and P1 action-item counts;
   the compliance band counts; the per-macOS-major breakdown the Compliance screen already
   shows. Controls the policy sets to ignore are left out.
2. Focus line: which control and which macOS major account for most of the gap, and what to
   do first. Title: "Posture insight". The wording of facts follows the policy: a
   hardware-encrypted Mac with FileVault off is reported under warnings, never as unencrypted.
3. One card on each screen, under the score/KPI row.
4. Tests: adapter facts under the default policy and under a policy with the hardware rule set
   to warning; the privacy test.

## Task 5: Audit insight

Files: `Views/AuditView.swift`, the audit service/model that holds findings and drift, tests.

Consumes from Task 2: the same types and card as Task 3.

1. Adapter input: findings grouped by severity and category with the number of affected
   objects, and the counts of findings new and resolved since the previous audit. Category and
   check names are allowed; object names (policy, script, profile, group names) are not sent —
   only their counts — so the privacy test fixture includes a policy name that must not appear.
2. Focus line: which categories to work first and what changed since the last audit.
   Title: "Audit insight".
3. The card sits above the findings list. No card when there is no audit snapshot.
4. Tests: adapter facts; the privacy test.

## Task 6: Narrative on the collect-then-generate path

Files: `Views/OverviewView.swift` (`runGenerate` and the collect-then-generate branch), tests if
the branch logic is reachable without the view.

Reported, verify first: the Overview passes `aiNarrative` to the report only on the
skip-collect branch; the collect-then-generate branch never requests one, so a report
generated right after a collect has no AI summary paragraph while one generated from fresh
cache does. If confirmed, request the narrative on both branches through the same
`ReportNarrative.makeForGUIGenerate` call (same 10-second timebox, same aggregates-only
input). If it is not as described, report what the code does and change nothing.
