# Environment model P8: screens follow the products, Protect-only environments — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** what an environment has decides what runs and what shows. The collect gate (the once-a-day guard and the shared-workspace claim) moves out of `ReportEngine.collect` into `CollectRouter`, so it stops every product. An environment with only a Jamf Protect profile (#207 L3) is a workspace that collects, writes a daily summary and opens on the Protect screen. `EnvironmentProducts` is the one answer the tabs, Overview, Config tabs, reports and webhook cards read. School kinds join the freshness strip (L6).

**Architecture:**
- **`ReportEngine.environmentGate`** holds the day guard and `coordinationGate`, moved verbatim from `collect`. `CollectRouter.routed` runs it after the pin checkpoint and before any product, and releases the claim when the run ends.
- **`EnvironmentProfiles.isProtectOnly`** (a `profiles:` block with a `protect` slot and no MDM slot). `refusal(workspace:)` allows it when `protect` is the workspace (D17: named by its first filled slot). `proCommandRefusal(workspace:)` keeps refusing it for every command that needs Jamf Pro.
- **`EnvironmentProducts`** (Models) is derived from `EnvironmentProfiles` plus the composition `WorkspaceStore` already reads. `WorkspaceStore.environmentProducts` replaces `protectConnected`, and `isSchoolWorkspace` reads it.

**Tech stack:** Swift 6, SwiftUI, XCTest. Build with `swift build --build-tests` and test with `swift test`, both from `app/`.

**Spec:** `docs/superpowers/specs/2026-10-19-environment-model-design.md`, sections 5 (item 6), 7.1, 7.2, 7.5, 8 and the P8 row of section 13. The spec is on branch `docs/env-model-z1-z3` (#379), and this branch carries it. P8 stacks on P7 (`feat/env-model-p7`, #386).

## Global constraints

- **Golden test unchanged.** `EnvironmentProfilesGoldenTests.testEveryOldShapeRunsTheSameCommandLines` passes with its hashes as they are. A file without `profiles:` collects with the same command lines and router lines as today.
- **Fail closed for Jamf Pro commands.** A Protect-only environment never reaches a `pro` command: backup, backup diff, Health audit, group analysis, device lookup, the CLI `device` command and `schedules add --mode backup` refuse it with one sentence, before the tick lock and before any write. Collect and generate are allowed.
- **Absent is not zero.** A Protect-only daily summary has `totalDevices` 0 (as `mobileOnlySummary` writes it) and every other Mac and mobile figure nil.
- **Fix the class.** Each task lists the grep for its class. Every site the grep finds is fixed in that task or named in the ledger with a reason.
- Demo mode reads no workspace and is unchanged: `EnvironmentProducts.demo` is Jamf Pro plus Platform API, with Macs and mobile devices.
- User-visible GUI text goes through `L()` in whole sentences and is translated into all six catalog languages using `app/Localization/glossary.md`. Then run `app/scripts/sync-strings.zsh --prune-stale`. `LocalizationCatalogTests` must pass. Log lines, webhook cards and report text stay English.
- Any SwiftUI layout change needs visual verification at `PageScaffold.minSupportedWidth`. If you can't verify it, write `DRAFT — needs visual verification` in the commit body.
- Lines are at most 100 characters. No force unwraps. Functions at most 100 lines. Comments explain why. Match the surrounding style. Tests never run jamf-cli and never touch the real tick lock, schedule store or Application Support: inject every effect, and use the `JRC_TEST_WORKSPACES_ROOT` root the nearby tests use. A jamf-cli stub is never named `jamf-cli`.
- Commit subjects are imperative, at most 72 characters, with no attribution lines. CHANGELOG `Unreleased` gets plain-language bullets tagged (#305). CLAUDE.md and AGENTS.md stay byte-identical, and each task updates the CLAUDE.md lines its change makes wrong.

## Rulings

- **R1 (gate for School):** lifting the gate gives Jamf School the shared-workspace claim and the day guard, which it never had (spec 7.1: "a stand-down or the day guard stops every product"). A second full, unforced School collect on the same day is now skipped, as on Jamf Pro; Refresh and a `jamf-cli-full` schedule (`forcesCollect`) still force it. Cost if wrong: a School workspace collects once a day unless forced.
- **R2 (Protect after a gate stop):** a stand-down or the day guard still calls `collectProtect` with that disposition, so its existing `[skip] protect: …` line is unchanged.
- **R3 (Protect-only failure):** in a Protect-only run Protect is the whole run, so a Protect collect that throws, or one where no source landed, fails the run (`collectDead`), unlike the follow rule after an MDM, which logs `[partial]` and carries on.
- **R4 (Protect-only backup):** refused ("needs Jamf Pro"). `protect backup` alone is a later feature. Cost if wrong: a Protect-only environment has no configuration backup until then.
- **R5 (Overview):** on a Protect-only environment the Overview tab shows `ProtectView` (as a School workspace shows `SchoolOverviewView`). No new Overview section in P8.
- **R6 (Trends):** hidden on a Protect-only environment until P9 gives the summary Protect fields; its summary holds no figure to chart.
- **R7 (Platform tabs):** `platform` counts as present when the slot is set or, for a file without `profiles:`, when the active profile's auth method is `platform` (today's rule). Compliance Benchmarks shows only with `platform`. DDM Blueprints stays a Jamf Pro tab, because it unlocks from per-device inventory since 2.8.0. The Config › Platform API tab shows only with `platform`.
- **R8 (Mobile Devices tab):** hidden only when the composition is `macsOnly`. `unknown` keeps it.
- **R9 (report source lines):** spec 8's per-figure source line (#284 "reports name the connection") is not in P8. P8 adds one HTML header line listing the products and their profiles. The workbook is unchanged (Power BI reads its layout). The per-figure lines go to epic #284.
- **R10 (adoption):** `ExistingCLISetupFlow` keeps refusing a Protect login (it runs only before any workspace exists). A Protect-only environment is created from the Add sheet (Task 5) or by hand in config.yaml.
- **R11 (School blueprints):** `school-blueprints` stays out of `expectedKinds`. It is experimental and skipped without Platform fields; judging it would raise a banner on most School workspaces.

---

### Task 1: lift the collect gate into the router

**Class grep:** `rg -n "coordinationGate|already collected today|alreadyCollected|stoodDown" app/Sources app/Tests`

**Files:**
- Modify: `app/Sources/JamfReports/Engine/ReportEngine.swift` (the day guard and the coordination block in `collect`, about lines 2145-2200)
- Modify: `app/Sources/JamfReports/Services/CollectRouter.swift`
- Modify tests: `Engine/CollectOncePerdayGuardTests.swift`, `SharedWorkspaceCollectGateTests.swift`, `CollectRouterTests.swift`, `CollectHonestyTests.swift` as the grep finds

**Interfaces produced:**

```swift
extension ReportEngine {
    enum EnvironmentGate: Equatable, Sendable {
        case proceed(holdsClaim: Bool)
        case stop(CollectDisposition)   // .alreadyCollected or .stoodDown
    }
    /// The day guard, then `coordinationGate`, moved from `collect` with their log lines.
    static func environmentGate(
        workspace: WorkspaceID, workspacePaths: WorkspacePaths.Type, tiers: Set<CollectionTier>,
        force: Bool, now: Date,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) -> EnvironmentGate
}
// CollectRouter.run gains `gate:` (a closure with environmentGate's shape, defaulting to it).
```

- [ ] Move the day guard and the coordination block out of `collect` into `environmentGate` unchanged: same conditions (`isFullCollect`, `isSameDayRetry`, the summary's `date`/`totalDevices`/`source` keys), same lines and levels, and `now` as the guard's day (`collect` used `collectDay`, the local day of its `now`). `collect` keeps everything after the claim, and its `defer` release moves to the router.
- [ ] In `CollectRouter.routed`, after `SharedConfigPin.checkpoint` and before the product switch, call `gate`. On `.stop(d)`, call `collectProtect` with `d` (R2) and return. On `.proceed(holdsClaim: true)`, release the claim when `routed` returns or throws (`SharedWorkspace.release(profile: workspace.name)`).
- [ ] The School branch runs behind the same gate (R1).
- [ ] Tests: move each gate test that called `collect` to `environmentGate` or to `CollectRouter.run`, keeping its assertion. New router tests: the day guard stops Jamf Pro and Protect; a stand-down stops Jamf School and Protect; a claim the router takes is released after a thrown collect; `force` passes the guard. The golden test stays green.
- [ ] Update the CLAUDE.md lines that place the guard and the gate inside `collect` (the `shared_workspace` section and the `CollectRouter` row). Commit.

### Task 2: a Protect-only environment collects

**Class grep:** `rg -n "\.refusal\(workspace|proRunRefusal|backupRefusal|guard let mdm" app/Sources`

**Files:**
- Modify: `app/Sources/JamfReports/Services/EnvironmentProfiles.swift`, `Services/CollectRouter.swift`, `Services/CLIBridge.swift` (`refusesProCommand` and the backup binding), `Engine/ReportEngine.swift` (`protectCollect`, the summary writer)
- Test: `EnvironmentProfilesTests.swift`, `CollectRouterTests.swift`, a new `ProtectOnlyCollectTests.swift`

**Interfaces produced:**

```swift
extension EnvironmentProfiles {
    /// A `profiles:` block with a `protect` slot and neither MDM slot.
    var isProtectOnly: Bool { get }
    /// `refusal`, plus a refusal for a Protect-only environment: for commands that need Jamf Pro.
    func proCommandRefusal(workspace: WorkspaceID) -> String?
}
extension ReportEngine {
    /// Returns the number of Protect sources that landed (was Void).
    @discardableResult static func protectCollect(...) async throws -> Int
    static func protectOnlySummary(date: String, collectionSources: [String: String],
                                   collectedByHost: String?) -> DailySummary
}
// CollectRouter.ProtectCollect returns Int.
```

- [ ] `refusal(workspace:)`: under a block, neither MDM slot is allowed when `protect` is set, and the "names another profile" check compares the first filled slot (`mdm ?? protect`) with the workspace. Both MDM slots stays refused, and so does a block with no `jamf_pro`, `jamf_school` or `protect`.
- [ ] `proCommandRefusal`: `refusal`, else for `isProtectOnly` "'<workspace>' holds only a Jamf Protect profile; <operation needs> Jamf Pro." Switch every caller that runs a Jamf Pro command to it: `CLIBridge.refusesProCommand`, the backup binding, and `CollectRouter.backupRefusal` (R4). `CollectRouter.proRunRefusal` keeps `refusal`, so a collect or scheduled run of a Protect-only environment is allowed, and its product probe (`refusesProCommand`) is skipped for a Protect-only environment.
- [ ] Router: for `isProtectOnly`, after the gate, log `[info] routing <workspace> → Jamf Protect collect (no Jamf Pro or Jamf School in this environment)` and run the Protect collect directly (`SharedConfigPin.protectAllowed` and `ProfileAuthMethod.protectRefusal` still apply, as in `collectProtect`). A throw rethrows. Zero sources landed throws `ReportEngineError.collectDead(profile:failedCount:)` (R3). Otherwise write today's summary through `protectOnlySummary`: `totalDevices` 0, every other figure nil, `collectionSources` with `live` for each Protect kind that landed, `source` `jamf-cli`, `collectedByHost` as `collectingHostLabel` gives it. It replaces an existing same-day summary only when that one also has `totalDevices` 0 and no `mobile`. A summary that cannot be written logs `summaryNotWrittenMarker`, as the Jamf Pro path does.
- [ ] Tests: a block with only `protect` naming the workspace resolves, collects Protect, writes a summary with Mac and mobile figures nil, and a second unforced full collect the same day is stopped by the day guard. A Protect-only environment is refused by backup, audit and device lookup with the sentence. A block whose `protect` names another profile than the workspace is refused. Protect collect failing, or landing nothing, fails the run.
- [ ] Update the CLAUDE.md lines on `EnvironmentProfiles.refusal`, `CollectRouter` and `protectCollect`. Commit.

### Task 3: discovery, run targets and freshness know Protect-only and School kinds

**Class grep:** `rg -n "isNeverAWorkspace|ProfileProductType.detect|expectedKinds\(|protectKinds" app/Sources`

**Files:**
- Modify: `Services/ProfileService.swift` (`droppingPairedProductProfiles`, `runnableWorkspaces`), `Services/AddSheetPlan.swift`, `App/HeadlessRun.swift` (all-profile runs), `Services/ConfigDoctorService+Products.swift`, `Services/WorkspaceStore+Refresh.swift` (`expectedKinds`), `Services/WorkspaceStore+Automation.swift` (static `expectedKinds`), `Services/DataFreshnessHealth.swift` (`tier(forKind:)`), `Services/CollectSourcesPlan.swift`, `Services/ProtectBackup.swift` (where it calls `detect`)
- Test: the matching test files

**Interfaces produced:**

```swift
extension ProfileService {
    /// True when `name` has a workspace folder whose config.yaml is Protect-only for that name.
    static func isProtectOnlyWorkspace(_ name: String, root: URL? = nil) -> Bool
}
extension DataFreshnessHealth { static let schoolKinds: [String] }
```

- [ ] A Protect login is kept (not dropped as "never a workspace") exactly when `isProtectOnlyWorkspace` is true for it. Apply the one predicate at every `isNeverAWorkspace` site the grep finds. A Protect login named in another workspace's `protect` slot is still dropped.
- [ ] `expectedKinds`: a Protect-only environment expects `protectKinds` alone. A School workspace expects the School kinds `schoolCommandMatrix` names, less `school-blueprints` (R11) and less `collect_skip`, plus `sofa` and the Protect kinds as today. `DataFreshnessHealth.tier(forKind:)` judges a School kind on the cadence `planSchoolCollect` uses for it, and remediates it with that tier.
- [ ] `CollectSourcesPlan` for a Protect-only environment lists only the Protect group.
- [ ] Update the CLAUDE.md lines in the `DataFreshnessHealth` and `ProfileService` rows and the School sections that say School records no per-kind state. Commit.

### Task 4: `EnvironmentProducts`, tabs, Overview and Config tabs

**Class grep:** `rg -n "isSchoolWorkspace|protectConnected|limited\(toSchool|auth\?\.isPlatform|isPlatformProfile|ConfigTab.offered" app/Sources`

**Files:**
- Create: `app/Sources/JamfReports/Models/EnvironmentProducts.swift`
- Modify: `Services/WorkspaceStore.swift`, `App/ContentView.swift`, `Views/ConfigView.swift`, `Views/ComplianceBenchmarksView.swift`, `Views/SettingsView.swift`, `Views/ProtectView.swift`, and the other sites the grep finds
- Test: `EnvironmentProductsTests.swift`, `TabVisibilityTests.swift` (or the file that tests `limited(toSchool:)`)

**Interfaces produced:**

```swift
struct EnvironmentProducts: Equatable, Sendable {
    enum Product: String, CaseIterable, Sendable {
        case jamfPro, jamfSchool, platform, protect, securityCloud
    }
    var products: Set<Product>
    var composition: EnvironmentComposition
    static func from(_ environment: EnvironmentProfiles, composition: EnvironmentComposition,
                     legacyPlatformAuth: Bool) -> EnvironmentProducts
    static let demo: EnvironmentProducts
    var isSchool: Bool { get }        // jamfSchool and not jamfPro
    var isProtectOnly: Bool { get }   // protect and neither MDM
    func has(_ product: Product) -> Bool
}
extension TabVisibility {
    func limited(to products: EnvironmentProducts) -> TabVisibility
}
// WorkspaceStore.environmentProducts replaces protectConnected and refreshProtectConnection().
```

- [ ] `from`: a slot that is set is a product. `platform` also when `legacyPlatformAuth` is true for a file without `profiles:` (R7).
- [ ] `limited(to:)`: School keeps `Tab.schoolTabs` (plus Jamf Protect with `protect`). Protect-only keeps Overview, Jamf Protect, Reports, Automation, Run History, Config, Data Sources, Settings and Onboarding (R6). Jamf Pro hides School Devices, hides Compliance Benchmarks without `platform`, hides Jamf Protect without `protect`, hides Mobile Devices on `macsOnly` (R8). Replace `limited(toSchool:protectConnected:)` at every caller.
- [ ] `WorkspaceStore.environmentProducts` is computed where `protectConnected` was (launch, config load, Data Sources connect and disconnect, profile switch), from `EnvironmentProfiles.read(workspace:)` and `composition`, with `.demo` in demo mode. `isSchoolWorkspace` returns `environmentProducts.isSchool || activeCLIProfile?.product == .school`, so a School workspace whose config.yaml cannot be read is still School.
- [ ] `ContentView`: the Overview tab shows `ProtectView` on a Protect-only environment (R5). Its tab-reset `onChange` watches `environmentProducts`.
- [ ] Config: `ConfigTab.offered` takes `EnvironmentProducts`: School as today, the Platform API tab only with `platform`, Protect-only gets Thresholds, Output and From config.yaml.
- [ ] Compliance Benchmarks and the Config Platform tab read `environmentProducts.has(.platform)` instead of `activeCLIProfile?.auth?.isPlatform`; the tenant-level check keeps reading `platformLevel`.
- [ ] Tests: the tab set for each mix (Pro, Pro + Platform, Pro + Protect, School, School + Protect, Protect-only, Macs-only Pro, demo). `from` for each slot shape and the legacy Platform rule. `DRAFT — needs visual verification` in the commit body. Commit.

### Task 5: create a Protect-only environment from the Add sheet

**Files:**
- Modify: `Services/EnvironmentProposal.swift`, `Services/AddSheetPlan.swift`, the Add sheet view and its accept path (the code that writes `profiles:` and calls `confirmWrittenConfig`)
- Test: `EnvironmentProposalTests.swift`, `AddSheetPlanTests.swift`

- [ ] A Protect login with no environment to join (no proposal suggests one, or the user picks none) can be accepted as "Its own environment (Jamf Protect only)". It is never preselected. Accepting creates the workspace folder named after the login, writes `profiles: {protect: <login>}` through the same writer the other proposals use, and confirms it in the pin. A login already named by a workspace is not offered.
- [ ] Tests: the choice is offered for an unassigned Protect login, not preselected, and the accept writes the block. `DRAFT — needs visual verification`. Commit.

### Task 6: reports and webhook cards name the products; docs

**Class grep:** `rg -n "successFacts|heartbeatFacts|failureFacts|func headerFacts|templateName" app/Sources`

**Files:**
- Modify: `Services/ScheduledRunSignals.swift`, the HTML report header builder (`Engine/HtmlReport*.swift`), `CHANGELOG.md`, `CLAUDE.md`, `AGENTS.md`, `config.example.yaml` (a commented Protect-only `profiles:` example)

- [ ] `EnvironmentProducts.Product.displayName` ("Jamf Pro", "Jamf School", "Platform API", "Jamf Protect", "Security Cloud"), English, never through `L()` here.
- [ ] Webhook success and heartbeat cards in `full` detail add a `Products` fact listing the environment's products in that order; `minimal` adds nothing. Built from `EnvironmentProfiles.read(workspace:)`.
- [ ] The HTML report header adds one line, "Products: Jamf Pro (Example), Platform API (Example-API), Jamf Protect (Example-Protect)", from the workspace's `EnvironmentProfiles`, profile names through `ConfigSchema.displayText` and HTML-escaped. Nothing when the workspace has no config.yaml (tests, a bare engine).
- [ ] CHANGELOG bullets for the whole phase, CLAUDE.md/AGENTS.md lines for `EnvironmentProducts` and the Protect-only environment, and epic #284 gets the deferred per-figure source lines (R9) noted in the ledger for Tony to post. Commit.
