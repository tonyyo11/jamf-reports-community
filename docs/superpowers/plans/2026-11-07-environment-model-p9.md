# Environment model P9: the daily summary names the products — implementation plan

Status: shipped in 2.12 on `dev/2-12-0`. The boxes below are the original task list and were not ticked as the work landed; `CLAUDE.md` describes what was built.

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The daily summary records which products collected, the Protect figures and the aggregate device maps; Trends and alerts read the new figures; Config Doctor warns when a Protect pairing looks wrong; one environment finalize writes the environment-level fields for every product mix.

**Architecture:** New optional `DailySummary` fields, built by pure builders from the snapshots already on disk. The MDM summary writers (Jamf Pro `finalizeCollect`, School `writeSchoolSummary`) keep writing today's summary; the aggregate maps join them. After every product has run, `CollectRouter` runs one environment finalize that adds `products` and the Protect figures to today's summary (and writes the Protect-only summary through the same step). Trends, alerts and Doctor read the new fields; nothing reads a field that is absent.

**Tech Stack:** Swift 6 (strict concurrency, builds on Swift 6.1, 6.2, 6.4), SwiftPM in `app/`, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-19-environment-model-design.md` sections 4 (rule 5, `environment.protect_match`), 7.1 (one environment finalize), 8 (daily summary additions), phase row P9; `docs/superpowers/specs/2026-10-19-mobile-first-class-design.md` section 7 (P9 keeps `products`, the Protect figures and the aggregate maps; the mobile fields went to M2).

## Global Constraints

- **Absent is not zero.** Every new field is nil when its product or device type is absent or nothing reports it. A map leaves out a key with no devices; it is nil, not `{}`, when there are no devices of that type. A share needs a denominator above 0.
- **An alert on an absent product never fires** (a nil never fires; `MetricAlertEvaluator` already skips nil).
- **Old summaries read as before.** A summary file without the new keys decodes with them nil, and the existing fields keep their values. `filling(from:)` carries every new field, `numbersAreInRange` checks them (counts ≥ 0 and ≤ `maxSummaryNumber`, shares 0-100), `freshSummaryIsBetter` treats a newly measured field as an upgrade.
- **Golden and shape tests:** existing key values stay byte-identical. A golden summary file gains only the new keys; regenerate it per its README and state the diff in the commit body.
- **Out of scope:** `storageBuckets` (needs P10's `computer-storage` kind), `securityRiskCounts`/`securityCoveredPct` (P12, blocked on a tenant), per-figure report source lines (#284), Fleet Overview tiles and `FleetRollup` (mobile spec M6), the patch-history summary fields (separate spec after P8; leave field names free of `patch`/`time_to_patch` prefixes so that spec can add them).
- **Fixtures from real jamf-cli output**, never written from documentation: reuse the captured Protect, `computers`, `mobile-devices-list` and School fixtures already in `app/Tests/JamfReportsTests` (find them with `rg -l "protect-computers|hardware|mobile-devices-list|lastCheckin" app/Tests`).
- **Fix the class:** every place that constructs or rebuilds a `DailySummary` (`rg -n "DailySummary\(" app/Sources`) gets the new fields or a stated reason it does not.
- GUI text through `L()` in all six catalog languages (`app/scripts/sync-strings.zsh --prune-stale`, `app/Localization/glossary.md`); summary JSON keys, alert keys, Doctor row ids and log lines stay English.
- Lines ≤100 characters, no force unwraps, tests never run jamf-cli (stubs never named `jamf-cli`), `@MainActor` XCTest classes keep mutable fixtures `nonisolated(unsafe)` with `setUpWithError` (Swift 6.1 CI).
- Commits: imperative subject ≤72 characters, no attribution trailer. CHANGELOG bullets tagged (#305). CLAUDE.md and AGENTS.md stay byte-identical.

## Rulings

- **P9-R1 (`products`):** the summary's `products` is the sorted list of slot names (`jamf_pro`, `jamf_school`, `platform`, `protect`, `security_cloud`) whose collect landed at least one source in a run that day. A later same-day run unions with the list already in the file. `platform` counts when a Platform-only kind landed under the `platform` slot (or, without a `profiles:` block, under a platform auth profile). A run that landed nothing for a product adds nothing.
- **P9-R2 (Protect figures):** from the newest `protect-computers` and `protect-alerts` snapshots, only when the Protect collect landed in this run or the summary already has them:
  - `protectComputerCount`: number of Protect computer rows.
  - `protectMatchedPct`: `ProtectProCorrelation` matched ÷ (Protect computers − those with no identifier) × 100, one decimal; nil when there is no inventory to match against (Protect-only, no `computers`/`school-devices` snapshot) or the denominator is 0.
  - `protectOpenAlerts`: open alerts (status not `Resolved`/`AutoResolved`); 0 is a real value when the alerts snapshot exists and has no open alert; nil when there is no alerts snapshot.
  - `protectAlertCounts`: the same open alerts by lowercased severity (`high`, `medium`, `low`, `informational`); a severity with none is left out; nil when there is no alerts snapshot or no open alert (never `{}`).
- **P9-R3 (aggregate maps), written by the MDM summary writers:**
  - `osMajorCounts: [String: Int]?`, keys `"macOS 26"`, `"iOS 18"`, `"iPadOS 18"`, `"tvOS 18"` (platform name plus major), from `computers` and `mobile-devices-list` (Jamf Pro) or `school-devices` `os` (School). A device whose version has no readable major is left out.
  - `modelFamilyCounts: [String: Int]?`, computers only, by the marketing model name in `computers` hardware: `MacBook Air`, `MacBook Pro`, `MacBook`, `Mac mini`, `iMac`, `Mac Pro`, `Mac Studio`, else `Other` (prefix match, longest first; a model identifier like `Mac14,13` alone is `Other`). Jamf Pro only.
  - `mobileFormFactorCounts: [String: Int]?`, keys `iPad`, `iPhone`, `Apple TV`, `Other`, through `MobileFleetService.formFactor(of:)`. Jamf Pro only.
  - `lastSeenBuckets: LastSeenBuckets?` with `computers` and `mobile`, each `{underOneDay, underSevenDays, sevenDaysOrMore, never}` counts (`never` only for computers, from `StaleAge.never`). Computers by the workspace's `StaleRule` age (the stale basis, as `staleCount` uses); mobile by last inventory (Jamf Pro) or last check-in (School). A device with no known date is left out.
- **P9-R4 (finalize):** `ReportEngine.finalizeEnvironmentSummary(summariesDir:dataDir:environment:landed:day:onLine:)` runs once in `CollectRouter` after every product ran and before the claim is released, for every run that passed the gate. It reads today's summary through `SummaryJSONParser`; when there is none it writes one only for a Protect-only environment (`protectOnlySummary`, which moves into this step so the router's separate Protect-only write goes away). It sets `products` (P9-R1) and the Protect figures (P9-R2), and writes through `writeSummaryFile`. It never creates a summary for an MDM environment whose MDM wrote none (a failed MDM collect must not read as a Trends day). A failure logs `ReportEngine.summaryNotWrittenMarker` as today.
- **P9-R5 (Trends):** new metrics `protectComputers` (count, neutral polarity), `protectMatched` (share, higher is better) and `protectOpenAlerts` (count, lower is better), offered only when a loaded summary carries the field (as the mobile metrics are). They join the Overview score card picker only where the environment has Protect. The maps are not Trends series in P9 (M6 draws them).
- **P9-R6 (alerts):** new keys `protect_computer_count`, `protect_matched_pct`, `protect_open_alert_count`, `protect_high_alert_count` (the `high` entry, nil when there is no alerts snapshot, 0 when the snapshot has no open high alert). `config.example.yaml`'s key list comment gains them.
- **P9-R7 (Doctor):** `environment.protect_match`: from the newest snapshots through `ProtectProCorrelation.load`; nothing when Protect is not connected, there is no inventory, or fewer than 5 Protect computers carry an identifier; `.warn` when the matched share of those is under 50% ("probably paired with the wrong environment", naming the Protect profile and the share, never device names); `.pass` otherwise. Runs off the main actor with the other snapshot families.

---

### Task 1: the new summary fields

**Files:**
- Modify: `app/Sources/JamfReports/Services/SummaryJSONParser.swift` (`DailySummary`: CodingKeys, properties, memberwise init, `init(from:)`, `encode(to:)`, `filling(from:)`, `numbersAreInRange`), `app/Sources/JamfReports/Engine/ReportEngine.swift` (`freshSummaryIsBetter`)
- Create: `app/Sources/JamfReports/Models/LastSeenBuckets.swift`
- Test: `app/Tests/JamfReportsTests/SummaryEnvironmentFieldsTests.swift`

**Interfaces produced:**

```swift
struct LastSeenBuckets: Codable, Equatable, Sendable {
    struct Counts: Codable, Equatable, Sendable {
        var underOneDay: Int?, underSevenDays: Int?, sevenDaysOrMore: Int?, never: Int?
        var total: Int { [underOneDay, underSevenDays, sevenDaysOrMore, never].compactMap { $0 }.reduce(0, +) }
    }
    var computers: Counts?
    var mobile: Counts?
}
// DailySummary gains (all optional, JSON key = name):
//   products: [String]?, protectComputerCount: Int?, protectMatchedPct: Double?,
//   protectOpenAlerts: Int?, protectAlertCounts: [String: Int]?,
//   osMajorCounts: [String: Int]?, modelFamilyCounts: [String: Int]?,
//   mobileFormFactorCounts: [String: Int]?, lastSeenBuckets: LastSeenBuckets?
// plus `func withEnvironment(products: [String]?, protect: ProtectSummaryFigures?) -> DailySummary`
struct ProtectSummaryFigures: Equatable, Sendable {
    var computerCount: Int?, matchedPct: Double?, openAlerts: Int?, alertCounts: [String: Int]?
}
```

- [ ] Add the fields as optional `private(set) var` stored properties with defaulted memberwise parameters, decoded with `decodeIfPresent` and encoded with `encodeIfPresent`.
- [ ] `filling(from:)` keeps an older value for each new field this run did not measure; `products` unions (sorted, no repeats).
- [ ] `numbersAreInRange`: every count ≥ 0 and ≤ `maxSummaryNumber`, `protectMatchedPct` 0-100, map values ≥ 0, and `protectOpenAlerts` ≥ each `protectAlertCounts` entry.
- [ ] `freshSummaryIsBetter`: a fresh summary that measures a new field the existing one lacks is an upgrade.
- [ ] Tests: an old summary JSON (copy one from an existing fixture) decodes with every new field nil and re-encodes byte-identical; a full round trip; `filling` carries and unions; range check rejects a negative count, a share over 100; `withEnvironment` sets only what it is given. Commit.

### Task 2: the aggregate maps

**Files:**
- Create: `app/Sources/JamfReports/Services/SummaryDeviceMaps.swift`
- Modify: `ReportEngine.swift` (`buildSummaryFromCLI`, `mobileOnlySummary`), `Engine/ReportEngine+SchoolSummary.swift` (`schoolSummary(from:...)`), and every other `DailySummary(` construction the class grep finds
- Test: `app/Tests/JamfReportsTests/SummaryDeviceMapsTests.swift`, plus the golden/shape suites (`GoldenFleetTests`, `SummaryJSONEmitTests`, `SchoolSummaryTests`, `MobileOnlySummaryTests`)

**Interfaces produced:**

```swift
enum SummaryDeviceMaps {
    static func modelFamily(_ marketingName: String?) -> String          // P9-R3 families
    static func osMajorKey(platform: String, version: String?) -> String? // "macOS 26"
    static func computers(_ records: [DeviceInventoryRecord], rule: StaleRule, now: Date)
        -> (osMajor: [String: Int], modelFamily: [String: Int], lastSeen: LastSeenBuckets.Counts?)
    static func mobile(_ rows: [MobileDeviceListRow], now: Date)
        -> (osMajor: [String: Int], formFactor: [String: Int], lastSeen: LastSeenBuckets.Counts?)
    static func school(_ devices: [SchoolFleetService.Device], now: Date)
        -> (osMajor: [String: Int], computersLastSeen: LastSeenBuckets.Counts?, mobileLastSeen: LastSeenBuckets.Counts?)
}
```

- [ ] Builders per P9-R3, pure. Read the model name, OS version and dates from the fields the existing readers already use (`DeviceInventoryRecord`, `MobileDeviceListRow`, `SchoolFleetService.Device`); confirm each field against a real fixture before relying on it. A map with no entries is nil in the summary.
- [ ] Wire into the Jamf Pro summary (Mac and mobile-only) and the School summary (`osMajorCounts`, `lastSeenBuckets` only). The School history backfill (`ReportEngine+SchoolBackfill`) goes through `schoolSummary(from:)` and so fills them for past days from that day's snapshot, measured as of the snapshot's stamp.
- [ ] Tests from real fixtures: families incl. an identifier-only model as `Other`, a version with no major left out, the bucket edges (exactly 1 and 7 days), `never`, no devices → nil maps, School rows, a mobile-only fleet. Regenerate goldens for added keys only. Commit.

### Task 3: one environment finalize

**Files:**
- Modify: `ReportEngine.swift` (add `finalizeEnvironmentSummary`, `protectSummaryFigures`; fold `writeProtectOnlySummary` into it), `Services/CollectRouter.swift` (call it once after the products ran, inside the claim)
- Test: `app/Tests/JamfReportsTests/EnvironmentFinalizeTests.swift`, `ProtectOnlyCollectTests.swift`, `CollectRouterTests.swift`

**Interfaces produced:**

```swift
extension ReportEngine {
    static func protectSummaryFigures(dataDir: URL, workspace: WorkspaceID) -> ProtectSummaryFigures?
    @discardableResult
    static func finalizeEnvironmentSummary(
        summariesDir: URL, dataDir: URL, environment: EnvironmentProfiles,
        workspace: WorkspaceID, landed: [EnvironmentProducts.Product: Set<String>],
        day: Date = Date(), onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) -> SummaryEmitOutcome
}
```

- [ ] `CollectRouter` gathers which products landed which kinds in this run (Jamf Pro and School from their collect's landed set, Protect from `protectCollect`'s landed kinds, `platform` from landed Platform-only kinds under P9-R1) and calls the finalize once per run that passed the gate, after the Protect follow, before the claim is released; also after a failed MDM collect that still ran Protect (the finalize then writes nothing new unless a summary already exists for today).
- [ ] Behaviour per P9-R4; Protect figures per P9-R2 (`protectSummaryFigures` uses `ProtectDashboardService.load(dataDir:)` and `ProtectProCorrelation.load`, never device names).
- [ ] Tests: Pro + Protect run → summary has `products: ["jamf_pro","protect"]` and the Protect figures; Pro collect failed + Protect landed with no summary today → no summary written; Protect-only → summary with `totalDevices` 0, Mac and mobile figures nil, Protect figures set, `protectMatchedPct` nil; second same-day run unions `products`; a gate stop runs no finalize; School + Protect. Commit.

### Task 4: Trends and alert keys

**Files:**
- Modify: `Models/Models.swift` (`TrendSeries.Metric` cases, raw values, labels, unit, polarity, `isDeviceCount`, axis), `Models/OverviewLayout.swift` (`isOffered`), `Services/TrendStore.swift` (`value(for:in:)`, `offers`), `Services/WorkspaceStore.swift` (`availableMetrics`), `Theme`/`Engine/ChartPalette.swift` (any exhaustive switch), `Services/MetricAlertEvaluator.swift` (`AlertMetric` keys, `label`, `isPercentage`, `value(in:)`), `config.example.yaml` (key list comment)
- Test: `TrendStoreTests` or a new `TrendStoreProtectMetricsTests.swift`, `MetricAlertEvaluatorTests.swift`

- [ ] Metrics and keys per P9-R5 and P9-R6; raw values `protectComputers`, `protectMatched`, `protectOpenAlerts` (never renamed later). Labels through `L()`, six languages.
- [ ] Tests: offered only when a summary carries the field; not offered on an environment without Protect; an alert on each key fires on a value and never fires when the field is absent; `protect_high_alert_count` reads 0 from a snapshot with no open high alert. Commit.

### Task 5: `environment.protect_match` Doctor row

**Files:**
- Modify: `Services/ConfigDoctorService+Products.swift` (new `protectMatchRows`), `Services/ConfigDoctorService.swift` (register it beside `protectProfileProductRows`)
- Test: `app/Tests/JamfReportsTests/EnvironmentDoctorRowsTests.swift (as built; the row is in ConfigDoctorService+Environment.swift)`

- [ ] Per P9-R7, with an injectable correlation input so tests need no snapshots on disk; the row text through `L()`.
- [ ] Tests: threshold edges (49.9% warns, 50% passes), fewer than 5 identified computers → no row, no inventory → no row, Protect not connected → no row, School inventory counts as inventory. Commit.

### Task 6: docs

**Files:** `CHANGELOG.md`, `CLAUDE.md`, `AGENTS.md`

- [ ] CHANGELOG bullets (#305) for the new summary figures, Trends and alerts, and the Doctor row. CLAUDE.md/AGENTS.md: one paragraph on the P9 summary fields and the environment finalize near the mobile summary paragraph; the Protect-only summary line points at the finalize. Commit.
