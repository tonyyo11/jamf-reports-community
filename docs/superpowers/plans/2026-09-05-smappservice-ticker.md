# SMAppService Ticker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace every `~/Library/LaunchAgents` plist the app writes with one bundled `SMAppService` agent that wakes every 5 minutes and runs whatever schedule is due, with hand-built schedules stored as per-machine app state.

**Architecture:** A static plist inside the bundle launches `JamfReports --tick`. The tick takes a pid lock, derives managed schedules from `AutomationPolicy`, loads hand-built schedules from `~/Library/Application Support/JamfReports/schedules.json`, decides what is due from each schedule's calendar fire time versus its own last-started stamp, and runs due schedules through the existing `--scheduled-run` body. Legacy plists are imported once and removed only when the operator confirms.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, SwiftPM, XCTest, `ServiceManagement.SMAppService` (macOS 13+; app floor is macOS 15).

**Spec:** `docs/superpowers/specs/2026-09-05-smappservice-ticker-design.md`

## Global Constraints

- Ships in 2.8.0 on `feat/enhance-ddm` (decision 2026-09-05: 2.8.0 releases end of month). The version pair is already 2.8.0; Task 12 writes CHANGELOG entries under `## [2.8.0]`, not `[Unreleased]`, and does not touch the version.
- Swift 6 strict concurrency. CI's floor leg is Xcode 16.4 / Swift 6.1, stricter than local 6.3: a `static` on a SwiftUI `View` is MainActor-isolated there, so pure statics called from nonisolated tests must be `nonisolated static`.
- 100-character lines, functions ≤100 lines, no force-unwrap in production paths, no `UIKit`, no new SwiftPM dependencies (`ServiceManagement` is a system framework).
- Every file path goes through `ProfileService.workspaceURL(for:)` / `WorkspacePaths`; new app-state files live under `AppSupport.directory()` defined in Task 1.
- Labels keep the `LaunchAgentWriter.labelPrefix` form (`com.github.tonyyo11.jamf-reports-community.<profile|multi>.<slug>`); `LaunchAgentWriter.isValidLabel` and `label(for:)` survive this change and stay the only label validators.
- Managed labels: `ManagedAutomation.owns(_:)` exact membership, never a prefix match.
- Nothing in this plan touches `ReportEngine.collect`, the shared-workspace claim, or the freshness gate.
- Tests never touch the real `~/Library/LaunchAgents`, the real Application Support folder, or `SMAppService`; every I/O seam takes an injectable URL or protocol.
- Commit messages: imperative subject ≤72 chars, one logical change, no `Co-Authored-By` trailer unless the session's harness requires one.
- Spec deviations recorded in this plan: (1) "last recorded run start" is a per-label stamp in `tick-state.json` beside the store, because the recorder's status file carries only `finished_at` and a managed schedule's status is one file per profile; (2) Run-now markers live at `AppSupport.directory()/run-now/<label>` rather than in a workspace, because a managed schedule spans profiles.

---

## File Structure

**Create**
- `app/Sources/JamfReports/Services/AppSupport.swift` — the per-machine app-state folder (`~/Library/Application Support/JamfReports`, 0o700).
- `app/Sources/JamfReports/Services/ScheduleStore.swift` — `ScheduleRecord` (Codable, lenient) + `ScheduleStore` (load/save/upsert/remove at an injectable URL).
- `app/Sources/JamfReports/Services/TickScheduler.swift` — `TickState` (per-label last-started stamps), `TickScheduler.due(...)` (pure), `TickLock` (pid file).
- `app/Sources/JamfReports/Services/TickerRegistrar.swift` — `TickerStatus`, `TickerRegistrar` protocol, `SMAppServiceRegistrar`, `StubTickerRegistrar`.
- `app/Sources/JamfReports/Services/ScheduleImport.swift` — pure import of parsed legacy plists into records; first-launch orchestration.
- `app/Sources/JamfReports/Services/TickRunner.swift` — spawns `JamfReports --tick --now <label>` for Run now (GUI and CLI).
- `app/Sources/JamfReports/App/Tick.swift` — `runTick(arguments:now:)`, the agent's entry body.
- `app/Sources/JamfReports/CLI/ScheduleCommands.swift` — `jamf-reports schedules list|add|remove|run`.
- `app/LaunchAgents/com.github.tonyyo11.jamf-reports-community.tick.plist` — the bundled agent (outside `Sources/` so SwiftPM's `.process("Resources")` never touches it).
- Tests: `ScheduleStoreTests.swift`, `TickSchedulerTests.swift`, `TickLockTests.swift`, `TickerRegistrarTests.swift`, `ScheduleImportTests.swift`, `TickPlistTests.swift`, `ScheduleHealthInputsTests.swift`.

**Modify**
- `app/Sources/JamfReports/App/main.swift` — `--tick` dispatch; `runSchedule(_:verbose:)` extracted from `scheduledRun`; headless overdue digest reads schedules, not plists; headless reconcile deleted.
- `app/Sources/JamfReports/Services/LaunchAgentWriter.swift` — keeps labels, `calendarIntervals(for:)` (new internal), path validators; loses plist generation and `launchctl`.
- `app/Sources/JamfReports/Services/LaunchAgentService.swift` — keeps `parse`, `lastScheduledFireDate`, archive helpers, status readers; gains `installedLegacy()` and `healthInputs(schedules:statusProfile:now:)`; loses `list`, `kickstartNow`, `staleExecutableLabels`, `cleanupLegacyAgents`, `removeAgents`, the plist-scanning `healthInputs`.
- `app/Sources/JamfReports/Services/ManagedAutomation.swift` — keeps `ManagedKind`, `label(for:)`, `owns`, `desiredSchedules`, `bundleLocationWarning`; loses `plan`, `reconcile*`, `invalidateManagedPlists`, `migrationShouldComplete`, the signature and the install/remove closures.
- `app/Sources/JamfReports/Services/WorkspaceStore.swift`, `WorkspaceStore+Automation.swift` — schedules from policy + store; ticker registration; health from schedules; Run now via `TickRunner`.
- `app/Sources/JamfReports/Services/ScheduleConsolidation.swift` — repurposed to "imported plists still loaded".
- `app/Sources/JamfReports/Services/ProfileService.swift` — schedule counts from the store.
- `app/Sources/JamfReports/Services/CLIBridge.swift` — `setupLaunchAgent`/`setupMultiLaunchAgent` deleted.
- `app/Sources/JamfReports/Services/ConfigDoctorService.swift` — `evaluateBundleLocation` deleted (banner stays).
- `app/Sources/JamfReports/Views/SchedulesView.swift`, `AutomationView.swift`, `ExistingCLISetupView.swift`, `App/ContentView.swift` — store-backed mutations, ticker banner, import card.
- `app/Sources/JamfReports/CLI/JamfReportsCLI.swift` — registers `Schedules`.
- `app/build-app.sh` — copies the bundled plist.
- Docs: `CLAUDE.md` ≡ `AGENTS.md`, `CHANGELOG.md`, `README.md`, `docs/wiki/05-Scheduling-and-Automation.md`, `05b-Automation-Trust.md`, `07-Command-Line.md`, `10-Security-and-Operational-Considerations.md`, `Glossary.md`, `Home.md`.

**Delete (tests)**: the plan/reconcile/migration tests in `ManagedAutomationTests.swift`; the `nativeSingleWrite`/`nativeMultiWrite`/manual-run-plan tests in `LaunchAgentWriterTests.swift`; the kickstart, stale-executable and plist-scanning health-input tests in `LaunchAgentServiceTests.swift`; `ScheduleConsolidationTests.swift` (replaced). `CLIBridgeRunNowTests` pins `CLIBridge.runNow(profile:mode:)`, the mode-contract reference implementation, and is untouched.

**Build gate for every task** (the controller runs it; implementers do not run `swift build`/`swift test` unless the task says so):

```bash
cd app && swift build --build-tests 2>&1 | grep -E "error:|Build complete" | tail -3
cd app && swift test --filter "<SuiteName>" 2>&1 | grep -E "Executed [0-9]+ tests|error: -" | tail -3
```

Demand an `Executed N tests` line per named suite; a filter that matches nothing prints no such line.

---

### Task 1: AppSupport folder and ScheduleStore

**Files:**
- Create: `app/Sources/JamfReports/Services/AppSupport.swift`
- Create: `app/Sources/JamfReports/Services/ScheduleStore.swift`
- Test: `app/Tests/JamfReportsTests/ScheduleStoreTests.swift`

**Interfaces:**
- Consumes: `Schedule`, `Schedule.RunMode`, `CollectionTier`, `MultiTarget`, `LaunchAgentWriter.label(for:)`, `LaunchAgentWriter.isValidLabel`, `ManagedAutomation.owns`.
- Produces: `AppSupport.directory(fileManager:home:) -> URL`; `ScheduleRecord` (`label, name, profile, allProfiles, excludedProfiles, mode: String, tiers: [String]?, schedule, enabled`, `init?(schedule:)`, `toSchedule() -> Schedule`); `ScheduleStore(url:)` with `load() -> [ScheduleRecord]`, `save(_:) throws`, `upsert(_:) throws`, `remove(label:) throws`, `static let defaultURL`.

- [ ] **Step 1: Write the failing tests**

```swift
// app/Tests/JamfReportsTests/ScheduleStoreTests.swift
import XCTest
@testable import JamfReports

final class ScheduleStoreTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedule-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func sample(name: String = "nightly", profile: String = "alpha") -> Schedule {
        Schedule(
            name: name, profile: profile, schedule: "Daily 06:20", cadence: "daily",
            mode: .jamfCLIFull, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, tiers: [.refresh, .scan]
        )
    }

    func testAppSupportDirectoryIsCreatedPrivate() throws {
        let home = try tempDir()
        let dir = AppSupport.directory(home: home)
        XCTAssertEqual(dir.path, home.appendingPathComponent(
            "Library/Application Support/JamfReports").path)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o700)
    }

    func testRecordRoundTripsThroughSchedule() throws {
        let record = try XCTUnwrap(ScheduleRecord(schedule: sample()))
        XCTAssertEqual(record.label, "com.github.tonyyo11.jamf-reports-community.alpha.nightly")
        let back = record.toSchedule()
        XCTAssertEqual(back.name, "nightly")
        XCTAssertEqual(back.profile, "alpha")
        XCTAssertEqual(back.mode, .jamfCLIFull)
        XCTAssertEqual(back.tiers, [.refresh, .scan])
        XCTAssertEqual(back.schedule, "Daily 06:20")
        XCTAssertEqual(back.launchAgentLabel, record.label)
        XCTAssertFalse(back.isMulti)
    }

    func testMultiRecordKeepsExclusions() throws {
        var s = sample(name: "fleet")
        s.multiTarget = MultiTarget(scope: .all)
        s.excludedProfiles = ["dummy"]
        let record = try XCTUnwrap(ScheduleRecord(schedule: s))
        XCTAssertTrue(record.allProfiles)
        XCTAssertEqual(record.label, "com.github.tonyyo11.jamf-reports-community.multi.fleet")
        let back = record.toSchedule()
        XCTAssertTrue(back.isMulti)
        XCTAssertEqual(back.excludedProfiles, ["dummy"])
        XCTAssertEqual(back.profile, "")
    }

    func testRecordRefusesManagedLabelAndInvalidName() {
        var managed = sample(name: "managed-freshness")
        managed.multiTarget = MultiTarget(scope: .all)
        XCTAssertNil(ScheduleRecord(schedule: managed))
        XCTAssertNil(ScheduleRecord(schedule: sample(name: "")))
    }

    func testStoreLoadsEmptyWhenFileMissingOrCorrupt() throws {
        let url = try tempDir().appendingPathComponent("schedules.json")
        XCTAssertEqual(ScheduleStore(url: url).load(), [])
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(ScheduleStore(url: url).load(), [])
    }

    func testUpsertReplacesByLabelAndRemoveDeletes() throws {
        let url = try tempDir().appendingPathComponent("schedules.json")
        let store = ScheduleStore(url: url)
        var a = try XCTUnwrap(ScheduleRecord(schedule: sample()))
        try store.upsert(a)
        a.enabled = false
        try store.upsert(a)
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(store.load().first?.enabled, false)
        try store.remove(label: a.label)
        XCTAssertEqual(store.load(), [])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    func testDecodeIsLenientToUnknownAndMissingKeys() throws {
        let json = """
        [{"label":"com.github.tonyyo11.jamf-reports-community.alpha.x","name":"x",
          "profile":"alpha","mode":"backup","schedule":"Mon 07:00","futureKey":1}]
        """
        let url = try tempDir().appendingPathComponent("schedules.json")
        try Data(json.utf8).write(to: url)
        let records = ScheduleStore(url: url).load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.enabled, true)
        XCTAssertEqual(records.first?.allProfiles, false)
        XCTAssertNil(records.first?.tiers)
    }
}
```

- [ ] **Step 2: Run the suite to verify it fails to compile**

Run: `cd app && swift build --build-tests 2>&1 | grep -E "error:" | head -3`
Expected: errors naming `AppSupport`, `ScheduleRecord`, `ScheduleStore`.

- [ ] **Step 3: Implement AppSupport and ScheduleStore**

```swift
// app/Sources/JamfReports/Services/AppSupport.swift
import Foundation

/// Per-machine app state that is NOT workspace data: the schedule store, the
/// tick stamps and lock. Never inside a workspace — a workspace may be a synced
/// team folder, and schedules belong to one Mac.
enum AppSupport {
    static func directory(
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let dir = home.appendingPathComponent(
            "Library/Application Support/JamfReports", isDirectory: true)
        try? fileManager.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }
}
```

```swift
// app/Sources/JamfReports/Services/ScheduleStore.swift
import Foundation

/// One hand-built schedule as persisted. Managed schedules are never stored —
/// they are derived from `AutomationPolicy` on every tick.
struct ScheduleRecord: Codable, Sendable, Equatable {
    var label: String
    var name: String
    /// Owning profile slug; "" when `allProfiles`.
    var profile: String
    var allProfiles: Bool
    var excludedProfiles: [String]
    /// `Schedule.RunMode.rawValue`. Stored as a string so an unknown future
    /// mode decodes and is skipped rather than failing the whole file.
    var mode: String
    /// `CollectionTier.rawValue`s, sorted; nil = mode default.
    var tiers: [String]?
    /// Cadence string in the `LaunchAgentWriter.calendarIntervals(for:)` form.
    var schedule: String
    var enabled: Bool

    init?(schedule: Schedule) {
        guard let label = LaunchAgentWriter.label(for: schedule),
              !ManagedAutomation.owns(label) else { return nil }
        self.label = label
        self.name = schedule.name
        self.allProfiles = schedule.isMulti
        self.profile = schedule.isMulti ? "" : schedule.profile
        self.excludedProfiles = schedule.excludedProfiles ?? []
        self.mode = schedule.mode.rawValue
        self.tiers = schedule.tiers.map { $0.map(\.rawValue).sorted() }
        self.schedule = schedule.schedule
        self.enabled = schedule.enabled
    }

    enum CodingKeys: String, CodingKey {
        case label, name, profile, allProfiles, excludedProfiles, mode, tiers, schedule, enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? label
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? ""
        allProfiles = try c.decodeIfPresent(Bool.self, forKey: .allProfiles) ?? false
        excludedProfiles = try c.decodeIfPresent([String].self, forKey: .excludedProfiles) ?? []
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? Schedule.RunMode.jamfCLIOnly.rawValue
        tiers = try c.decodeIfPresent([String].self, forKey: .tiers)
        schedule = try c.decodeIfPresent(String.self, forKey: .schedule) ?? "Daily 06:00"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func toSchedule() -> Schedule {
        let runMode = Schedule.RunMode(rawValue: mode) ?? .jamfCLIOnly
        let tierSet: Set<CollectionTier>? = tiers.map {
            Set($0.compactMap(CollectionTier.init(rawValue:)))
        }
        return Schedule(
            name: name,
            profile: profile,
            schedule: schedule,
            cadence: "custom",
            mode: runMode,
            next: "—",
            last: "—",
            lastStatus: .ok,
            artifacts: [],
            enabled: enabled,
            launchAgentLabel: label,
            multiTarget: allProfiles ? MultiTarget(scope: .all, sequential: true) : nil,
            tiers: tierSet,
            excludedProfiles: allProfiles ? excludedProfiles : nil
        )
    }
}

/// JSON file of `ScheduleRecord`s. Missing or corrupt → empty (logged); writes
/// are atomic and 0o600. Every method re-reads the file, so two processes
/// (GUI + tick) never overwrite each other's edits with a stale copy.
struct ScheduleStore: Sendable {
    static let defaultURL = AppSupport.directory().appendingPathComponent("schedules.json")
    let url: URL

    init(url: URL = ScheduleStore.defaultURL) { self.url = url }

    func load() -> [ScheduleRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([ScheduleRecord].self, from: data)
        } catch {
            AppLogger.schedule.error(
                "schedules.json could not be decoded: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func save(_ records: [ScheduleRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func upsert(_ record: ScheduleRecord) throws {
        var records = load().filter { $0.label != record.label }
        records.append(record)
        try save(records.sorted { $0.label < $1.label })
    }

    func remove(label: String) throws {
        try save(load().filter { $0.label != label })
    }
}
```

- [ ] **Step 4: Run the suite**

Run: `cd app && swift test --filter ScheduleStoreTests 2>&1 | grep -E "Executed [0-9]+ tests|error: -" | tail -3`
Expected: `Executed 7 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/JamfReports/Services/AppSupport.swift \
        app/Sources/JamfReports/Services/ScheduleStore.swift \
        app/Tests/JamfReportsTests/ScheduleStoreTests.swift
git commit -m "feat(schedules): per-machine ScheduleStore under Application Support"
```

---

### Task 2: Cadence intervals, TickState, and the due decision

**Files:**
- Modify: `app/Sources/JamfReports/Services/LaunchAgentWriter.swift` (add `calendarIntervals(for:)` beside `setupCadence`, around line 624)
- Create: `app/Sources/JamfReports/Services/TickScheduler.swift`
- Test: `app/Tests/JamfReportsTests/TickSchedulerTests.swift`

**Interfaces:**
- Consumes: `LaunchAgentWriter.setupCadence(from:)` (private) and `CadenceOptions.startCalendarIntervals` (private), `LaunchAgentService.lastScheduledFireDate(from:before:)`, `Schedule.RunMode.runsAtLoad`.
- Produces: `LaunchAgentWriter.calendarIntervals(for cadence: String) throws -> [[String: Int]]`; `TickState` (`var lastStarted: [String: Date]`, `static func load(url:) -> TickState`, `func save(url:) throws`, `static let defaultURL`); `TickScheduler.due(schedules:lastStarted:runNowLabels:now:) -> [Schedule]`; `TickScheduler.nonCatchUpWindow`.

- [ ] **Step 1: Write the failing tests**

```swift
// app/Tests/JamfReportsTests/TickSchedulerTests.swift
import XCTest
@testable import JamfReports

final class TickSchedulerTests: XCTestCase {

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        return Calendar.current.date(from: c)!
    }

    private func schedule(
        _ name: String, cadence: String, mode: Schedule.RunMode, enabled: Bool = true
    ) -> Schedule {
        Schedule(
            name: name, profile: "alpha", schedule: cadence, cadence: "custom", mode: mode,
            next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: enabled,
            launchAgentLabel: "com.github.tonyyo11.jamf-reports-community.alpha.\(name)"
        )
    }

    func testCalendarIntervalsCoverEveryCadenceForm() throws {
        XCTAssertEqual(try LaunchAgentWriter.calendarIntervals(for: "Daily 06:20"),
                       [["Hour": 6, "Minute": 20]])
        XCTAssertEqual(try LaunchAgentWriter.calendarIntervals(for: "Mon 07:00"),
                       [["Weekday": 1, "Hour": 7, "Minute": 0]])
        XCTAssertEqual(try LaunchAgentWriter.calendarIntervals(for: "Weekdays 09:00").count, 5)
        XCTAssertEqual(try LaunchAgentWriter.calendarIntervals(for: "Day 15 06:20"),
                       [["Day": 15, "Hour": 6, "Minute": 20]])
        XCTAssertThrowsError(try LaunchAgentWriter.calendarIntervals(for: "whenever"))
    }

    func testDueAtOrAfterFireWhenNeverStarted() {
        let s = schedule("collect", cadence: "Daily 06:20", mode: .snapshotOnly)
        let due = TickScheduler.due(
            schedules: [s], lastStarted: [:], runNowLabels: [], now: date(2026, 9, 7, 6, 21))
        XCTAssertEqual(due.map(\.name), ["collect"])
    }

    func testNotDueWhenLastStartAlreadyCoversTheLatestFire() {
        let s = schedule("collect", cadence: "Daily 06:20", mode: .snapshotOnly)
        let label = s.launchAgentLabel!
        // 06:19 today: the latest fire is YESTERDAY 06:20, already covered.
        XCTAssertTrue(TickScheduler.due(
            schedules: [s], lastStarted: [label: date(2026, 9, 6, 6, 21)], runNowLabels: [],
            now: date(2026, 9, 7, 6, 19)).isEmpty)
        // Started after this morning's fire → nothing to do.
        XCTAssertTrue(TickScheduler.due(
            schedules: [s], lastStarted: [label: date(2026, 9, 7, 6, 22)], runNowLabels: [],
            now: date(2026, 9, 7, 6, 25)).isEmpty)
    }

    func testMissedFireFiresOnceNotPerMissedDay() {
        let s = schedule("collect", cadence: "Daily 06:20", mode: .snapshotOnly)
        let label = s.launchAgentLabel!
        // Last started a week ago; six fires were missed. One run, then quiet.
        let first = TickScheduler.due(
            schedules: [s], lastStarted: [label: date(2026, 8, 31, 6, 21)], runNowLabels: [],
            now: date(2026, 9, 7, 14, 0))
        XCTAssertEqual(first.count, 1)
        let second = TickScheduler.due(
            schedules: [s], lastStarted: [label: date(2026, 9, 7, 14, 0)], runNowLabels: [],
            now: date(2026, 9, 7, 14, 5))
        XCTAssertTrue(second.isEmpty)
    }

    func testNonCatchUpModesRunOnlyWithinFifteenMinutesOfTheFire() {
        let backup = schedule("backup", cadence: "Mon 07:00", mode: .backup)
        let generate = schedule("gen", cadence: "Daily 06:20", mode: .jamfCLIOnly)
        // 2026-09-07 is a Monday.
        XCTAssertEqual(TickScheduler.due(
            schedules: [backup, generate], lastStarted: [:], runNowLabels: [],
            now: date(2026, 9, 7, 7, 10)).map(\.name), ["backup"])
        XCTAssertTrue(TickScheduler.due(
            schedules: [backup, generate], lastStarted: [:], runNowLabels: [],
            now: date(2026, 9, 7, 7, 16)).isEmpty)
    }

    func testDisabledNeverDueAndRunNowAlwaysDue() {
        let s = schedule("collect", cadence: "Daily 06:20", mode: .snapshotOnly, enabled: false)
        XCTAssertTrue(TickScheduler.due(
            schedules: [s], lastStarted: [:], runNowLabels: [], now: date(2026, 9, 7, 6, 21)
        ).isEmpty)
        XCTAssertEqual(TickScheduler.due(
            schedules: [s], lastStarted: [:], runNowLabels: [s.launchAgentLabel!],
            now: date(2026, 9, 7, 3, 0)).map(\.name), ["collect"])
    }

    func testUnparseableCadenceIsSkippedNotFatal() {
        let bad = schedule("bad", cadence: "whenever", mode: .snapshotOnly)
        let good = schedule("good", cadence: "Daily 06:20", mode: .snapshotOnly)
        XCTAssertEqual(TickScheduler.due(
            schedules: [bad, good], lastStarted: [:], runNowLabels: [],
            now: date(2026, 9, 7, 6, 21)).map(\.name), ["good"])
    }

    func testInputOrderIsPreserved() {
        let a = schedule("a", cadence: "Daily 06:00", mode: .snapshotOnly)
        let b = schedule("b", cadence: "Daily 06:10", mode: .snapshotOnly)
        XCTAssertEqual(TickScheduler.due(
            schedules: [b, a], lastStarted: [:], runNowLabels: [],
            now: date(2026, 9, 7, 6, 30)).map(\.name), ["b", "a"])
    }

    func testTickStateRoundTripsAndLoadsEmptyWhenMissing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-state-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(TickState.load(url: url).lastStarted, [:])
        var state = TickState()
        state.lastStarted["x"] = date(2026, 9, 7, 6, 21)
        try state.save(url: url)
        XCTAssertEqual(TickState.load(url: url).lastStarted["x"], date(2026, 9, 7, 6, 21))
    }
}
```

- [ ] **Step 2: Run to verify compile failure**

Run: `cd app && swift build --build-tests 2>&1 | grep -E "error:" | head -3`
Expected: errors naming `calendarIntervals`, `TickScheduler`, `TickState`.

- [ ] **Step 3: Add `calendarIntervals(for:)` to LaunchAgentWriter**

Insert directly above `private static func setupCadence(from raw: String)`:

```swift
    /// The launchd `StartCalendarInterval` entries a cadence string denotes —
    /// the one place the tick and the dead-man switch turn "Daily 06:20" into
    /// fire times. Throws `WriterError.cadenceParseError` for anything else.
    static func calendarIntervals(for cadence: String) throws -> [[String: Int]] {
        try setupCadence(from: cadence).startCalendarIntervals
    }
```

- [ ] **Step 4: Implement TickScheduler and TickState**

```swift
// app/Sources/JamfReports/Services/TickScheduler.swift
import Foundation

/// Per-label "last started" stamps. Lives beside the schedule store, not in
/// a workspace: the recorder's status file has no start time, and a managed
/// schedule's status is one file per profile.
struct TickState: Codable, Sendable {
    static let defaultURL = AppSupport.directory().appendingPathComponent("tick-state.json")

    var lastStarted: [String: Date] = [:]

    static func load(url: URL = TickState.defaultURL) -> TickState {
        guard let data = try? Data(contentsOf: url) else { return TickState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(TickState.self, from: data)) ?? TickState()
    }

    func save(url: URL = TickState.defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Pure "what is due" decision. Input order is preserved so the caller
/// controls run order (managed kinds first, then hand-built by label).
enum TickScheduler {
    /// Modes that do NOT catch up (generate-from-cache, backup) only run when
    /// the missed fire is this recent — matches their old `RunAtLoad: false`.
    static let nonCatchUpWindow: TimeInterval = 15 * 60

    static func due(
        schedules: [Schedule],
        lastStarted: [String: Date],
        runNowLabels: Set<String>,
        now: Date
    ) -> [Schedule] {
        schedules.filter { schedule in
            guard let label = schedule.launchAgentLabel else { return false }
            if runNowLabels.contains(label) { return true }
            guard schedule.enabled else { return false }
            guard let entries = try? LaunchAgentWriter.calendarIntervals(for: schedule.schedule),
                  let fire = LaunchAgentService.lastScheduledFireDate(from: entries, before: now)
            else {
                AppLogger.schedule.warning(
                    "tick: \(label, privacy: .public) has an unreadable cadence and was skipped")
                return false
            }
            let started = lastStarted[label] ?? .distantPast
            guard fire > started else { return false }
            return schedule.mode.runsAtLoad || now.timeIntervalSince(fire) <= nonCatchUpWindow
        }
    }
}
```

- [ ] **Step 5: Run the suite**

Run: `cd app && swift test --filter TickSchedulerTests 2>&1 | grep -E "Executed [0-9]+ tests|error: -" | tail -3`
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/JamfReports/Services/LaunchAgentWriter.swift \
        app/Sources/JamfReports/Services/TickScheduler.swift \
        app/Tests/JamfReportsTests/TickSchedulerTests.swift
git commit -m "feat(tick): pure due decision over cadence fire times and last-started stamps"
```

---

### Task 3: TickLock

**Files:**
- Modify: `app/Sources/JamfReports/Services/TickScheduler.swift` (append)
- Test: `app/Tests/JamfReportsTests/TickLockTests.swift`

**Interfaces:**
- Produces: `TickLock(url:)` with `func acquire(pid:isAlive:) -> Bool`, `func release()`, `static let defaultURL`.

- [ ] **Step 1: Write the failing tests**

```swift
// app/Tests/JamfReportsTests/TickLockTests.swift
import XCTest
@testable import JamfReports

final class TickLockTests: XCTestCase {

    private func lockURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tick-\(UUID().uuidString).lock")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAcquireWritesPidAndReleaseRemovesIt() throws {
        let lock = TickLock(url: lockURL())
        XCTAssertTrue(lock.acquire(pid: 4242, isAlive: { _ in true }))
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), "4242")
        lock.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.url.path))
    }

    func testLivePidBlocksASecondAcquire() {
        let lock = TickLock(url: lockURL())
        XCTAssertTrue(lock.acquire(pid: 1, isAlive: { _ in true }))
        XCTAssertFalse(lock.acquire(pid: 2, isAlive: { _ in true }))
    }

    func testDeadPidIsTakenOver() throws {
        let lock = TickLock(url: lockURL())
        try Data("99999".utf8).write(to: lock.url)
        XCTAssertTrue(lock.acquire(pid: 7, isAlive: { $0 != 99999 }))
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), "7")
    }

    func testGarbageLockFileIsTakenOver() throws {
        let lock = TickLock(url: lockURL())
        try Data("not a pid".utf8).write(to: lock.url)
        XCTAssertTrue(lock.acquire(pid: 7, isAlive: { _ in true }))
    }
}
```

- [ ] **Step 2: Run to verify compile failure**

Run: `cd app && swift build --build-tests 2>&1 | grep -E "error:" | head -3`
Expected: error naming `TickLock`.

- [ ] **Step 3: Implement TickLock** (append to `TickScheduler.swift`)

```swift
/// One tick at a time. A pid file: a live holder blocks, a dead or garbage
/// holder is taken over — the 300-second wake must never pile a second run
/// on top of a 20-minute collect.
struct TickLock: Sendable {
    static let defaultURL = AppSupport.directory().appendingPathComponent(".tick.lock")
    let url: URL

    func acquire(
        pid: Int32 = getpid(),
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    ) -> Bool {
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let holder = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           holder != pid, isAlive(holder) {
            return false
        }
        do {
            try Data(String(pid).utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            AppLogger.schedule.error(
                "tick lock could not be written: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func release() {
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 4: Run the suite**

Run: `cd app && swift test --filter TickLockTests 2>&1 | grep -E "Executed [0-9]+ tests|error: -" | tail -3`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/JamfReports/Services/TickScheduler.swift app/Tests/JamfReportsTests/TickLockTests.swift
git commit -m "feat(tick): pid-file lock so wakes never overlap a running schedule"
```

---

### Task 4: TickerRegistrar

**Files:**
- Create: `app/Sources/JamfReports/Services/TickerRegistrar.swift`
- Test: `app/Tests/JamfReportsTests/TickerRegistrarTests.swift`

**Interfaces:**
- Produces: `enum TickerStatus { case enabled, requiresApproval, notRegistered, unavailable }` with `var isRunning: Bool`; `protocol TickerRegistrar: Sendable { func register() throws; func unregister() throws; var status: TickerStatus { get }; func openLoginItems() }`; `struct SMAppServiceRegistrar: TickerRegistrar` with `static let plistName`, `static func isBundled(bundleURL:fileManager:) -> Bool`, `nonisolated static func map(_ status: SMAppService.Status) -> TickerStatus`; `final class StubTickerRegistrar: TickerRegistrar` recording `registerCalls`, `unregisterCalls`, settable `status`, `registerError: Error?`.

- [ ] **Step 1: Write the failing tests**

```swift
// app/Tests/JamfReportsTests/TickerRegistrarTests.swift
import XCTest
import ServiceManagement
@testable import JamfReports

final class TickerRegistrarTests: XCTestCase {

    func testStatusMappingCoversEveryCase() {
        XCTAssertEqual(SMAppServiceRegistrar.map(.enabled), .enabled)
        XCTAssertEqual(SMAppServiceRegistrar.map(.requiresApproval), .requiresApproval)
        XCTAssertEqual(SMAppServiceRegistrar.map(.notRegistered), .notRegistered)
        XCTAssertEqual(SMAppServiceRegistrar.map(.notFound), .unavailable)
    }

    func testOnlyEnabledCountsAsRunning() {
        XCTAssertTrue(TickerStatus.enabled.isRunning)
        for s in [TickerStatus.requiresApproval, .notRegistered, .unavailable] {
            XCTAssertFalse(s.isRunning)
        }
    }

    func testIsBundledRequiresAppBundleWithThePlist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("JamfReports.app", isDirectory: true)
        let agents = app.appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        XCTAssertFalse(SMAppServiceRegistrar.isBundled(bundleURL: app))
        try Data().write(to: agents.appendingPathComponent(SMAppServiceRegistrar.plistName))
        XCTAssertTrue(SMAppServiceRegistrar.isBundled(bundleURL: app))
        XCTAssertFalse(SMAppServiceRegistrar.isBundled(bundleURL: root.appendingPathComponent("JamfReports")))
    }

    func testStubRecordsCallsAndSurfacesErrors() throws {
        let stub = StubTickerRegistrar()
        try stub.register()
        try stub.unregister()
        XCTAssertEqual(stub.registerCalls, 1)
        XCTAssertEqual(stub.unregisterCalls, 1)
        stub.registerError = NSError(domain: "t", code: 1)
        XCTAssertThrowsError(try stub.register())
        stub.status = .requiresApproval
        XCTAssertEqual(stub.status, .requiresApproval)
    }
}
```

- [ ] **Step 2: Run to verify compile failure**

Run: `cd app && swift build --build-tests 2>&1 | grep -E "error:" | head -3`
Expected: errors naming `TickerStatus`, `SMAppServiceRegistrar`, `StubTickerRegistrar`.

- [ ] **Step 3: Implement**

```swift
// app/Sources/JamfReports/Services/TickerRegistrar.swift
import Foundation
import ServiceManagement

/// What Login Items › "Allow in the Background" says about our one agent.
enum TickerStatus: String, Sendable, Equatable {
    case enabled, requiresApproval, notRegistered
    /// No bundled plist (a `swift run` / dev binary) — registration cannot apply.
    case unavailable

    var isRunning: Bool { self == .enabled }
}

/// Seam over `SMAppService` so the tick loop, `WorkspaceStore` and the health
/// inputs run against a stub; the real calls are exercised only by a beta.
protocol TickerRegistrar: Sendable {
    func register() throws
    func unregister() throws
    var status: TickerStatus { get }
    func openLoginItems()
}

struct SMAppServiceRegistrar: TickerRegistrar {
    static let plistName = "com.github.tonyyo11.jamf-reports-community.tick.plist"

    /// True only for a real .app that ships the agent plist.
    static func isBundled(
        bundleURL: URL = Bundle.main.bundleURL, fileManager: FileManager = .default
    ) -> Bool {
        guard bundleURL.pathExtension == "app" else { return false }
        let plist = bundleURL.appendingPathComponent(
            "Contents/Library/LaunchAgents/\(plistName)")
        return fileManager.fileExists(atPath: plist.path)
    }

    nonisolated static func map(_ status: SMAppService.Status) -> TickerStatus {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .unavailable
        @unknown default: .notRegistered
        }
    }

    private var service: SMAppService { SMAppService.agent(plistName: Self.plistName) }

    func register() throws {
        guard Self.isBundled() else { return }
        try service.register()
    }

    func unregister() throws {
        guard Self.isBundled() else { return }
        try service.unregister()
    }

    var status: TickerStatus {
        Self.isBundled() ? Self.map(service.status) : .unavailable
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

/// Test double. `@unchecked Sendable`: a lock guards every stored property.
final class StubTickerRegistrar: TickerRegistrar, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: TickerStatus
    private var _registerCalls = 0
    private var _unregisterCalls = 0
    private var _registerError: Error?

    init(status: TickerStatus = .enabled) { _status = status }

    var status: TickerStatus {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var registerCalls: Int { lock.withLock { _registerCalls } }
    var unregisterCalls: Int { lock.withLock { _unregisterCalls } }
    var registerError: Error? {
        get { lock.withLock { _registerError } }
        set { lock.withLock { _registerError = newValue } }
    }

    func register() throws {
        try lock.withLock {
            _registerCalls += 1
            if let e = _registerError { throw e }
            _status = .enabled
        }
    }

    func unregister() throws {
        lock.withLock { _unregisterCalls += 1; _status = .notRegistered }
    }

    func openLoginItems() {}
}
```

- [ ] **Step 4: Run the suite**

Run: `cd app && swift test --filter TickerRegistrarTests 2>&1 | grep -E "Executed [0-9]+ tests|error: -" | tail -3`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/JamfReports/Services/TickerRegistrar.swift app/Tests/JamfReportsTests/TickerRegistrarTests.swift
git commit -m "feat(tick): TickerRegistrar seam over SMAppService with a stub"
```

---

### Task 5: The bundled agent plist and build-app.sh

**Files:**
- Create: `app/LaunchAgents/com.github.tonyyo11.jamf-reports-community.tick.plist`
- Modify: `app/build-app.sh` (after line 66, `chmod +x "$APP_OUT/Contents/MacOS/JamfReports"`)
- Test: `app/Tests/JamfReportsTests/TickPlistTests.swift`

**Interfaces:**
- Consumes: `SMAppServiceRegistrar.plistName` (Task 4).
- Produces: the file `build-app.sh` copies to `Contents/Library/LaunchAgents/`.

- [ ] **Step 1: Write the failing test**

```swift
// app/Tests/JamfReportsTests/TickPlistTests.swift
import XCTest
@testable import JamfReports

/// The bundled agent plist is data, not code: pin its shape so a stray edit
/// cannot ship an agent that never fires or points at the wrong program.
final class TickPlistTests: XCTestCase {

    private func plistURL() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(
                "LaunchAgents/\(SMAppServiceRegistrar.plistName)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("bundled agent plist not found above \(#filePath)")
    }

    func testBundledAgentPlistShape() throws {
        let data = try Data(contentsOf: try plistURL())
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String,
                       "com.github.tonyyo11.jamf-reports-community.tick")
        XCTAssertEqual(plist["BundleProgram"] as? String, "Contents/MacOS/JamfReports")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["JamfReports", "--tick"])
        XCTAssertEqual(plist["StartInterval"] as? Int, 300)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["ProcessType"] as? String, "Background")
        XCTAssertNil(plist["StartCalendarInterval"])
        XCTAssertNil(plist["Program"], "SMAppService agents use BundleProgram, never Program")
    }
}
```

- [ ] **Step 2: Run to verify it skips (file absent)**

Run: `cd app && swift test --filter TickPlistTests 2>&1 | grep -E "Executed [0-9]+ tests|skipped" | tail -2`
Expected: `1 test, with 0 failures` and a skip line.

- [ ] **Step 3: Create the plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.github.tonyyo11.jamf-reports-community.tick</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/JamfReports</string>
    <key>ProgramArguments</key>
    <array>
        <string>JamfReports</string>
        <string>--tick</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
```

Save as `app/LaunchAgents/com.github.tonyyo11.jamf-reports-community.tick.plist`.

- [ ] **Step 4: Copy it in build-app.sh**

Insert after line 66:

```bash
# The one SMAppService agent (2.9.0). Lives outside Sources/ so SwiftPM's
# .process("Resources") never rewrites it; signed with the bundle below.
mkdir -p "$APP_OUT/Contents/Library/LaunchAgents"
cp "LaunchAgents/com.github.tonyyo11.jamf-reports-community.tick.plist" \
   "$APP_OUT/Contents/Library/LaunchAgents/"
```

- [ ] **Step 5: Run the test and the shell linters**

Run: `cd app && swift test --filter TickPlistTests 2>&1 | grep -E "Executed [0-9]+ tests|error: -" | tail -2`
Expected: `Executed 1 test, with 0 failures`.

Run: `cd app && shellcheck build-app.sh && plutil -lint LaunchAgents/*.plist`
Expected: no shellcheck output; `OK` from plutil.

- [ ] **Step 6: Commit**

```bash
git add app/LaunchAgents app/build-app.sh app/Tests/JamfReportsTests/TickPlistTests.swift
git commit -m "feat(tick): bundle the SMAppService agent plist and copy it into the .app"
```

---

### Task 6: `runSchedule` extraction and the `--tick` entry

**Files:**
- Modify: `app/Sources/JamfReports/App/main.swift` (`scheduledRun(profile:)` at ~582–681; dispatch at ~948–962)
- Create: `app/Sources/JamfReports/App/Tick.swift`
- Create: `app/Sources/JamfReports/Services/TickRunner.swift`
- Test: none new; `TickSchedulerTests` covers the decision. The tick body is a thin I/O shell like `scheduledRun` (documented untestable — it spawns jamf-cli).

**Interfaces:**
- Consumes: `scheduledRunSingle(profile:mode:tiers:verbose:label:)`, `emitConsolidatedReports()`, `notifyOverdueSchedulesHeadless(profiles:excluding:)`, `ProfileService.discoverLocal/parseExclusions/applyingExclusions`, `ManagedAutomation.desiredSchedules`, `ScheduleStore`, `TickState`, `TickScheduler`, `TickLock`, `AppSupport`.
- Produces: `func runSchedule(_ schedule: Schedule, verbose: Bool) async -> Int32` (main.swift, internal); `func runTick(arguments: [String], now: Date) async -> Int32` (Tick.swift); `TickRunner.runNowMarkerDir`, `TickRunner.requestRunNow(label:) throws`, `TickRunner.consumeRunNowMarkers() -> Set<String>`, `TickRunner.spawnNow(label:wait:onLine:) async -> Int32`.

- [ ] **Step 1: Extract `runSchedule` in main.swift**

Replace the body of `scheduledRun(profile:)` so argument parsing builds a `Schedule` and everything after it lives in `runSchedule`. The parsed values are the same four (`mode`, `tiers`, `label`, `--exclude-profiles`); keep those closures verbatim and then:

```swift
@Sendable
private func scheduledRun(profile: String) async -> Int32 {
    let args = CommandLine.arguments
    let verbose = args.contains("--verbose")
    let allProfiles = args.contains("--all-profiles")
    // … existing `mode`, `tiers`, `label`, `excludeArg` closures unchanged …
    let schedule = Schedule(
        name: label ?? mode.rawValue, profile: profile, schedule: "manual", cadence: "custom",
        mode: mode, next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: true,
        launchAgentLabel: label,
        multiTarget: allProfiles ? MultiTarget(scope: .all, sequential: true) : nil,
        tiers: tiers,
        excludedProfiles: allProfiles ? Array(ProfileService.parseExclusions(excludeArg)) : nil
    )
    let code = await runSchedule(schedule, verbose: verbose)
    // External-scheduler path only: the tick posts its own digest once per wake.
    await notifyOverdueSchedulesHeadless(
        profiles: allProfiles ? ProfileService.discoverLocal().map(\.name) : [profile],
        excluding: Set(schedule.excludedProfiles ?? []))
    return code
}

/// One schedule, start to finish: the body every scheduler shares (`--tick`,
/// `--scheduled-run` from an external cron, Run now). Records under the
/// schedule's label; a multi schedule fans out over discovered profiles minus
/// its exclusions and emits the consolidated fleet report for report modes.
@Sendable
func runSchedule(_ schedule: Schedule, verbose: Bool) async -> Int32 {
    let label = schedule.launchAgentLabel
    guard schedule.isMulti else {
        return await scheduledRunSingle(
            profile: schedule.profile, mode: schedule.mode, tiers: schedule.tiers,
            verbose: verbose, label: label)
    }
    let excluded = Set(schedule.excludedProfiles ?? [])
    let profiles = ProfileService.applyingExclusions(
        ProfileService.discoverLocal(), excluding: excluded)
    guard !profiles.isEmpty else {
        fputs("[error] \(label ?? "all-profiles"): no local profiles found\n", stderr)
        return 1
    }
    if !excluded.isEmpty {
        fputs("[info] excluding: \(excluded.sorted().joined(separator: ", "))\n", stderr)
    }
    var anyFailed = false
    for p in profiles {
        let code = await scheduledRunSingle(
            profile: p.name, mode: schedule.mode, tiers: schedule.tiers,
            verbose: verbose, label: label)
        if code != 0 { anyFailed = true }
    }
    if [.jamfCLIOnly, .jamfCLIFull, .csvAssisted].contains(schedule.mode) {
        emitConsolidatedReports()
    }
    return anyFailed ? 1 : 0
}
```

Delete both `await reconcileManagedAutomationHeadless(currentLabel: label)` calls, the `reconcileManagedAutomationHeadless` function and `shouldReconcileManagedAutomationHeadless` (lines ~107–150). `ProfileService.parseExclusions` returns a `Set<String>`; check its signature (`ProfileService.swift`) and adapt the `Array(...)` conversion if it already returns an array.

- [ ] **Step 2: Add the dispatch**

In the entry-point block, before the `--scheduled-run` branch:

```swift
if cliArgs.count > 1, cliArgs[1] == "--tick" {
    let code = Task.detached { await runTick(arguments: cliArgs) }
    exit(await code.value)
} else if cliArgs.count > 1, cliArgs[1] == "--scheduled-run",
```

- [ ] **Step 3: Write TickRunner**

```swift
// app/Sources/JamfReports/Services/TickRunner.swift
import Foundation

/// Run-now plumbing shared by the GUI and the CLI: a marker the next tick
/// consumes, plus spawning an immediate tick for it.
enum TickRunner {
    static let runNowMarkerDir = AppSupport.directory()
        .appendingPathComponent("run-now", isDirectory: true)

    /// Leave a marker so the label runs even if this process cannot take the
    /// lock right now (another run is in flight) — the next wake picks it up.
    static func requestRunNow(label: String, dir: URL = runNowMarkerDir) throws {
        guard LaunchAgentWriter.isValidLabel(label) else { return }
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data().write(to: dir.appendingPathComponent(label), options: .atomic)
    }

    /// Read and delete every marker. Filenames are labels; anything that fails
    /// `isValidLabel` is removed and ignored.
    static func consumeRunNowMarkers(dir: URL = runNowMarkerDir) -> Set<String> {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var labels: Set<String> = []
        for name in names {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
            if LaunchAgentWriter.isValidLabel(name) { labels.insert(name) }
        }
        return labels
    }

    /// Spawn `JamfReports --tick --now <label>` as a child. With `wait`, stream
    /// its stdout/stderr through `onLine` and return its exit code; without,
    /// return 0 as soon as it is launched (the health-row button).
    static func spawnNow(
        label: String,
        wait: Bool,
        executable: URL? = Bundle.main.executableURL,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void = { _ in }
    ) async -> Int32 {
        guard LaunchAgentWriter.isValidLabel(label), let executable else { return 1 }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--tick", "--now", label]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let collector = LogLineTextCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            for line in text.split(separator: "\n") {
                let l = CLIBridge.LogLine(timestamp: Date(), level: .info, text: String(line))
                collector.append(l)
                onLine(l)
            }
        }
        do { try process.run() } catch { return 1 }
        guard wait else { return 0 }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in c.resume() }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        return process.terminationStatus
    }
}
```

`LogLineTextCollector` already exists in the test target as a Sendable line box; if it is test-only, replace `collector` with nothing (the `onLine` callback is enough) — the collector is not load-bearing.

- [ ] **Step 4: Write the tick body**

```swift
// app/Sources/JamfReports/App/Tick.swift
import Foundation

/// The bundled agent's entry: `JamfReports --tick [--now <label>]`.
/// Exit 0 unless the lock or the state file cannot be written; each
/// schedule's own outcome lands in its Run History record, not in this code.
@Sendable
func runTick(arguments: [String], now: Date = Date()) async -> Int32 {
    if let idx = arguments.firstIndex(of: "--now"), idx + 1 < arguments.count {
        do { try TickRunner.requestRunNow(label: arguments[idx + 1]) } catch {
            fputs("[error] could not queue run-now: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
    let lock = TickLock()
    guard lock.acquire() else {
        fputs("[info] tick: another run holds the lock — queued markers run on the next wake\n",
              stderr)
        return 0
    }
    defer { lock.release() }

    let policy = AutomationPolicy.current()
    let profiles = ProfileService.discoverLocal()
    let base = profiles.first { !policy.excludedProfiles.contains($0.name) }?.name
    let managed = ManagedAutomation.desiredSchedules(for: policy, baseProfile: base)
    let handBuilt = ScheduleStore().load().map { $0.toSchedule() }
        .sorted { ($0.launchAgentLabel ?? "") < ($1.launchAgentLabel ?? "") }
    let schedules = managed + handBuilt

    var state = TickState.load()
    let due = TickScheduler.due(
        schedules: schedules, lastStarted: state.lastStarted,
        runNowLabels: TickRunner.consumeRunNowMarkers(), now: now)
    for schedule in due {
        guard let label = schedule.launchAgentLabel else { continue }
        state.lastStarted[label] = Date()
        do { try state.save() } catch {
            fputs("[error] tick: could not write tick-state.json: \(error.localizedDescription)\n",
                  stderr)
            return 1
        }
        let code = await runSchedule(schedule, verbose: false)
        print("[info] tick: \(label) exit \(code)")
    }
    // Once per wake, after all runs, so a schedule that just fired is not
    // reported overdue by the same process.
    await notifyOverdueSchedulesHeadless(
        profiles: profiles.map(\.name), excluding: Set(policy.excludedProfiles))
    return 0
}
```

`notifyOverdueSchedulesHeadless` is `private` in main.swift; make it internal (drop `private`). It still reads plists until Task 8 swaps its input source; that is fine for this task's build.

- [ ] **Step 5: Build and run the existing scheduled-run suites**

Run: `cd app && swift build --build-tests 2>&1 | grep -E "error:|Build complete" | tail -3`
Expected: `Build complete!`.

Run: `cd app && swift test --filter "ScheduledRunSignalsTests|ScheduledRunConfigHealthTests|TickSchedulerTests" 2>&1 | grep -E "Executed [0-9]+ tests|error: -" | tail -3`
Expected: three `Executed` lines, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/JamfReports/App/main.swift app/Sources/JamfReports/App/Tick.swift \
        app/Sources/JamfReports/Services/TickRunner.swift
git commit -m "feat(tick): --tick entry runs due schedules through the shared runSchedule body"
```

---

### Task 7: Import, store-backed WorkspaceStore, ticker registration

**Files:**
- Create: `app/Sources/JamfReports/Services/ScheduleImport.swift`
- Modify: `app/Sources/JamfReports/Services/LaunchAgentService.swift` (`archiveAndRemove` at ~190; add `installedLegacy()`)
- Modify: `app/Sources/JamfReports/Services/WorkspaceStore.swift` (init ~202–240, `loadProfile` ~256, `reloadFromDisk` ~275–292)
- Modify: `app/Sources/JamfReports/Services/WorkspaceStore+Automation.swift` (`reconcileManagedAutomation` ~191–205)
- Modify: `app/Sources/JamfReports/Services/ProfileService.swift` (~124)
- Modify: `app/Sources/JamfReports/App/ContentView.swift` (~143), `Views/ExistingCLISetupView.swift` (~312–335), `Views/AutomationView.swift` (`AutomationTab` ~13–60)
- Test: `app/Tests/JamfReportsTests/ScheduleImportTests.swift`

**Interfaces:**
- Consumes: `LaunchAgentService.parse`, `LaunchAgentService.launchAgentEntries()` (private → make internal), `ScheduleStore`, `ScheduleRecord`, `TickerRegistrar`.
- Produces: `ScheduleImport.Result { imported: [ScheduleRecord]; managedLabels: [String]; unparseable: [String] }`; `ScheduleImport.plan(installed:unparseable:) -> Result` (pure); `ScheduleImport.runIfNeeded(store:defaults:key:) -> Result?`; `LaunchAgentService.installedLegacy() -> (schedules: [Schedule], unparseable: [String])`; `LaunchAgentService.archiveAndRemove(labels:includingManaged:)`; `WorkspaceStore.tickerRegistrar`, `WorkspaceStore.tickerStatus`, `WorkspaceStore.applyAutomationPolicy() async`, `WorkspaceStore.loadSchedules(policy:store:) -> [Schedule]` (nonisolated static).

- [ ] **Step 1: Write the failing tests**

```swift
// app/Tests/JamfReportsTests/ScheduleImportTests.swift
import XCTest
@testable import JamfReports

final class ScheduleImportTests: XCTestCase {

    private let prefix = LaunchAgentWriter.labelPrefix

    private func schedule(_ label: String, profile: String, multi: Bool = false) -> Schedule {
        Schedule(
            name: label.components(separatedBy: ".").last ?? label, profile: profile,
            schedule: "Daily 06:20", cadence: "custom", mode: .jamfCLIFull, next: "—",
            last: "—", lastStatus: .ok, artifacts: [], enabled: true, launchAgentLabel: label,
            multiTarget: multi ? MultiTarget(scope: .all) : nil)
    }

    func testPlanImportsHandBuiltSkipsManagedReportsUnparseable() {
        let managed = schedule("\(prefix).multi.managed-scan", profile: "", multi: true)
        let user = schedule("\(prefix).alpha.nightly", profile: "alpha")
        let userMulti = schedule("\(prefix).multi.fleet", profile: "", multi: true)
        let result = ScheduleImport.plan(
            installed: [managed, user, userMulti], unparseable: ["broken.plist"])
        XCTAssertEqual(result.imported.map(\.label), [
            "\(prefix).alpha.nightly", "\(prefix).multi.fleet"])
        XCTAssertEqual(result.managedLabels, ["\(prefix).multi.managed-scan"])
        XCTAssertEqual(result.unparseable, ["broken.plist"])
        XCTAssertEqual(result.imported.first?.profile, "alpha")
        XCTAssertEqual(result.imported.last?.allProfiles, true)
    }

    func testRunIfNeededImportsOnceAndSetsTheFlag() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = ScheduleStore(url: dir.appendingPathComponent("schedules.json"))
        let defaults = UserDefaults(suiteName: "ScheduleImportTests-\(UUID().uuidString)")!
        let user = schedule("\(prefix).alpha.nightly", profile: "alpha")

        let first = ScheduleImport.runIfNeeded(
            store: store, defaults: defaults, installed: { ([user], []) })
        XCTAssertEqual(first?.imported.count, 1)
        XCTAssertEqual(store.load().map(\.label), ["\(prefix).alpha.nightly"])

        let second = ScheduleImport.runIfNeeded(
            store: store, defaults: defaults, installed: { ([user], []) })
        XCTAssertNil(second, "a second launch must not re-import")
    }

    func testRunIfNeededNeverOverwritesAnExistingRecord() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = ScheduleStore(url: dir.appendingPathComponent("schedules.json"))
        var existing = try XCTUnwrap(ScheduleRecord(
            schedule: schedule("\(prefix).alpha.nightly", profile: "alpha")))
        existing.enabled = false
        try store.save([existing])
        let defaults = UserDefaults(suiteName: "ScheduleImportTests-\(UUID().uuidString)")!
        _ = ScheduleImport.runIfNeeded(
            store: store, defaults: defaults,
            installed: { ([self.schedule("\(self.prefix).alpha.nightly", profile: "alpha")], []) })
        XCTAssertEqual(store.load().first?.enabled, false)
    }

    @MainActor
    func testLoadSchedulesDerivesManagedFromPolicyAndReadsStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = ScheduleStore(url: dir.appendingPathComponent("schedules.json"))
        try store.save([try XCTUnwrap(ScheduleRecord(
            schedule: schedule("\(prefix).alpha.nightly", profile: "alpha")))])
        var policy = AutomationPolicy(); policy.isManaged = true
        let all = WorkspaceStore.loadSchedules(policy: policy, store: store, baseProfile: "alpha")
        XCTAssertEqual(all.filter { ManagedAutomation.owns($0.launchAgentLabel ?? "") }.count, 4)
        XCTAssertEqual(all.last?.launchAgentLabel, "\(prefix).alpha.nightly")
        policy.isManaged = false
        XCTAssertEqual(WorkspaceStore.loadSchedules(
            policy: policy, store: store, baseProfile: "alpha").count, 1)
    }
}
```

- [ ] **Step 2: Run to verify compile failure**

Run: `cd app && swift build --build-tests 2>&1 | grep -E "error:" | head -3`
Expected: errors naming `ScheduleImport`, `loadSchedules`.

- [ ] **Step 3: LaunchAgentService: `installedLegacy` and `includingManaged`**

Make `launchAgentEntries()` internal (drop `private`). Add beside `parse`:

```swift
    /// Every JRC plist still in `~/Library/LaunchAgents`, parsed, plus the
    /// filenames that would not parse. Import reads this once; the
    /// consolidation card reads it to show what is still loaded.
    static func installedLegacy(in dir: URL = agentsDir) -> (schedules: [Schedule], unparseable: [String]) {
        let prefix = "\(LaunchAgentWriter.labelPrefix)."
        let urls = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "plist" && $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var schedules: [Schedule] = []
        var unparseable: [String] = []
        for url in urls {
            if let s = parse(url) { schedules.append(s) } else { unparseable.append(url.lastPathComponent) }
        }
        return (schedules, unparseable)
    }
```

Change `archiveAndRemove(labels:)` to `archiveAndRemove(labels: [String], includingManaged: Bool = false)` and the guard to `guard includingManaged || !ManagedAutomation.owns(label) else {`. The default keeps every existing caller's behaviour.

- [ ] **Step 4: Write ScheduleImport**

```swift
// app/Sources/JamfReports/Services/ScheduleImport.swift
import Foundation

/// One-time move of legacy plists into the schedule store. Pure `plan`, thin
/// `runIfNeeded`. Managed labels are never imported (the policy describes
/// them); the caller archives and removes those without asking.
enum ScheduleImport {
    static let defaultsKey = "schedulesImportedV1"

    struct Result: Sendable, Equatable {
        let imported: [ScheduleRecord]
        let managedLabels: [String]
        let unparseable: [String]
    }

    static func plan(installed: [Schedule], unparseable: [String]) -> Result {
        var imported: [ScheduleRecord] = []
        var managed: [String] = []
        for schedule in installed {
            guard let label = schedule.launchAgentLabel else { continue }
            if ManagedAutomation.owns(label) { managed.append(label); continue }
            if let record = ScheduleRecord(schedule: schedule) { imported.append(record) }
        }
        return Result(
            imported: imported.sorted { $0.label < $1.label },
            managedLabels: managed.sorted(), unparseable: unparseable)
    }

    /// Runs once per machine. Existing store records win over an imported
    /// plist with the same label — an operator's edit is never undone by a
    /// stale plist. Returns nil when the import already happened.
    @discardableResult
    static func runIfNeeded(
        store: ScheduleStore = ScheduleStore(),
        defaults: UserDefaults = .standard,
        key: String = defaultsKey,
        installed: () -> (schedules: [Schedule], unparseable: [String])
            = { LaunchAgentService.installedLegacy() }
    ) -> Result? {
        guard !defaults.bool(forKey: key) else { return nil }
        let found = installed()
        let result = plan(installed: found.schedules, unparseable: found.unparseable)
        let existing = Set(store.load().map(\.label))
        var failed = false
        for record in result.imported where !existing.contains(record.label) {
            do { try store.upsert(record) } catch {
                failed = true
                AppLogger.schedule.error(
                    "import of \(record.label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        for name in result.unparseable {
            AppLogger.schedule.warning("import skipped unparseable plist \(name, privacy: .public)")
        }
        // A failed write leaves the flag unset so the next launch retries.
        if !failed { defaults.set(true, forKey: key) }
        return result
    }
}
```

- [ ] **Step 5: WorkspaceStore reads the store and registers the ticker**

In `WorkspaceStore.swift`:

```swift
    /// Seam for tests; production uses the real SMAppService registrar.
    let tickerRegistrar: any TickerRegistrar
    var tickerStatus: TickerStatus = .unavailable

    init(demoMode: Bool? = nil, tickerRegistrar: any TickerRegistrar = SMAppServiceRegistrar()) {
        self.tickerRegistrar = tickerRegistrar
        // … existing body, with these replacements:
        //   `let cleanup = LaunchAgentService.cleanupLegacyAgents()`  → delete
        //   `let realSchedules = LaunchAgentService.list()`           → delete
        //   `self.schedules = isDemo ? DemoData.scheduledRuns : realSchedules`
        //       → self.schedules = isDemo ? DemoData.scheduledRuns
        //                               : Self.loadSchedules(baseProfile: realProfiles.first?.name)
        //   `self.launchAgentCleanupMessage = cleanup.message`        → delete
        //   `self.launchAgentStaleLabels = …`                           → delete
        if !isDemo {
            if let result = ScheduleImport.runIfNeeded(), !result.managedLabels.isEmpty {
                _ = LaunchAgentService.archiveAndRemove(
                    labels: result.managedLabels, includingManaged: true)
            }
        }
    }

    /// Managed schedules come from the policy; hand-built from the store.
    nonisolated static func loadSchedules(
        policy: AutomationPolicy = AutomationPolicy.current(),
        store: ScheduleStore = ScheduleStore(),
        baseProfile: String?
    ) -> [Schedule] {
        let managed = ManagedAutomation.desiredSchedules(for: policy, baseProfile: baseProfile)
        let handBuilt = store.load().map { $0.toSchedule() }
            .sorted { ($0.launchAgentLabel ?? "") < ($1.launchAgentLabel ?? "") }
        return managed + handBuilt
    }
```

`desiredSchedules` returns `[]` when `policy.isManaged` is false, which is the behaviour the last test pins. Delete the `launchAgentCleanupMessage` and `launchAgentStaleLabels` properties. In `loadProfile` replace `schedules = LaunchAgentService.list().filter { $0.profile == id }` with `schedules = Self.loadSchedules(baseProfile: id).filter { $0.isMulti || $0.profile == id }`. In `reloadFromDisk` replace the two `LaunchAgentService` lines with `schedules = Self.loadSchedules(baseProfile: real.first?.name)`. The `removeAgents(profile: demoProfile)` call at ~317 becomes `try? ScheduleStore().save(ScheduleStore().load().filter { $0.profile != demoProfile })`.

In `WorkspaceStore+Automation.swift`, replace `reconcileManagedAutomation()` with:

```swift
    /// The policy changed, or the app launched: make Login Items agree with
    /// it. Registered when anything is scheduled; unregistered when nothing is.
    func applyAutomationPolicy() async {
        guard !demoMode else { return }
        let wantsTicker = AutomationPolicy.current().isManaged || !ScheduleStore().load().isEmpty
        do {
            if wantsTicker { try tickerRegistrar.register() } else { try tickerRegistrar.unregister() }
        } catch {
            AppLogger.schedule.error(
                "ticker \(wantsTicker ? "register" : "unregister") failed: \(error.localizedDescription, privacy: .public)")
        }
        tickerStatus = tickerRegistrar.status
        reloadFromDisk()
        await refreshAutomationHealth()
    }
```

Callers: `ContentView.swift:143` → `await workspace.applyAutomationPolicy()`; `ExistingCLISetupView.swift:319–332` → replace the `failed`/toast block with `await workspace.applyAutomationPolicy()` and, when `workspace.tickerStatus != .enabled`, a toast `"Setup finished — allow JamfReports under Login Items › Allow in the Background to start automation"` (style `.danger`); `AutomationTab.reconcileOnPolicyChange` → keep the 800 ms debounce, then `await workspace.applyAutomationPolicy()` and no toast (there are no install/remove counts any more). `ProfileService.discoverLocal` → `let scheduleCounts = Dictionary(grouping: ScheduleStore().load().filter { !$0.allProfiles }, by: \.profile).mapValues(\.count)`.

- [ ] **Step 6: Build and run the suites**

Run: `cd app && swift build --build-tests 2>&1 | grep -E "error:|Build complete" | tail -5`
Expected: `Build complete!` — expect and fix references to the deleted properties in `SchedulesView` (the two legacy banners; delete `legacyCleanupBanner`, `staleExecutableBanner` and their call sites at lines ~59–64) before the build is clean.

Run: `cd app && swift test --filter "ScheduleImportTests|ScheduleStoreTests|WorkspaceMigrationTests|ProfileServiceTests" 2>&1 | grep -E "Executed [0-9]+ tests|error: -" | tail -4`
Expected: 0 failures on every suite that matches.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/JamfReports/Services/ScheduleImport.swift \
        app/Sources/JamfReports/Services/LaunchAgentService.swift \
        app/Sources/JamfReports/Services/WorkspaceStore.swift \
        app/Sources/JamfReports/Services/WorkspaceStore+Automation.swift \
        app/Sources/JamfReports/Services/ProfileService.swift \
        app/Sources/JamfReports/App/ContentView.swift \
        app/Sources/JamfReports/Views/ExistingCLISetupView.swift \
        app/Sources/JamfReports/Views/AutomationView.swift \
        app/Sources/JamfReports/Views/SchedulesView.swift \
        app/Tests/JamfReportsTests/ScheduleImportTests.swift
git commit -m "feat(schedules): import legacy plists once; WorkspaceStore reads policy + store; register the ticker"
```

---

### Task 8: Health inputs from schedules, the ticker issue, headless digest

**Files:**
- Modify: `app/Sources/JamfReports/Services/LaunchAgentService.swift` (replace `healthInputs(in:now:)`, `scannedHealthInputs`, `healthInput(for:now:statusProfile:)`, `healthInputs(for:in:now:)` at ~437–557)
- Modify: `app/Sources/JamfReports/Services/WorkspaceStore+Automation.swift` (`AutomationHealthIssue.Kind`, `AutomationHealth.evaluate`, `refreshAutomationHealth` ~208–226, `runNowFromHealthRow` ~495)
- Modify: `app/Sources/JamfReports/App/main.swift` (`notifyOverdueSchedulesHeadless` ~171)
- Modify: `app/Sources/JamfReports/Views/AutomationView.swift` (`HealthCard.healthRow` ~446)
- Test: `app/Tests/JamfReportsTests/ScheduleHealthInputsTests.swift`; edit `AutomationHealthTests.swift`
- Delete tests: `testMultiHealthInputFallsBackToPerProfileStatusFile`, `testMultiHealthInputPicksNewestProfileStatus`, `testMultiHealthInputNilWhenNoStatusFilesAnywhere`, `testHealthInputsForProfileScopesMultiStatusToRequestingProfileNotNewestAcrossProfiles`, `testHealthInputsForProfileShowsThatProfilesOwnSuccessIndependently`, `testHealthInputsForProfileIgnoresNewerStatusFromADifferentLabel` in `LaunchAgentServiceTests.swift` (they exercise the plist scan; the per-profile status rule is re-pinned below on the schedule-based builder).

**Interfaces:**
- Produces: `LaunchAgentService.healthInputs(schedules:statusProfile:now:) -> [ScheduleHealthInput]`; `AutomationHealthIssue.Kind.tickerDisabled`; `AutomationHealth.evaluate(inputs:tickerStatus:now:)`; `AutomationHealth.tickerLabel`.

- [ ] **Step 1: Write the failing tests**

```swift
// app/Tests/JamfReportsTests/ScheduleHealthInputsTests.swift
import XCTest
@testable import JamfReports

final class ScheduleHealthInputsTests: XCTestCase {

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        return Calendar.current.date(from: c)!
    }

    private func schedule(_ label: String, profile: String, multi: Bool, cadence: String) -> Schedule {
        Schedule(
            name: "n", profile: profile, schedule: cadence, cadence: "custom", mode: .snapshotOnly,
            next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: true,
            launchAgentLabel: label, multiTarget: multi ? MultiTarget(scope: .all) : nil)
    }

    func testInputsCarryExpectedFireProfileAndMultiFlag() {
        let now = date(2026, 9, 7, 14, 30)
        let single = schedule("com.github.tonyyo11.jamf-reports-community.alpha.x",
                              profile: "alpha", multi: false, cadence: "Daily 06:20")
        let multi = schedule("com.github.tonyyo11.jamf-reports-community.multi.y",
                             profile: "", multi: true, cadence: "Mon 07:00")
        let inputs = LaunchAgentService.healthInputs(
            schedules: [single, multi], statusProfile: nil, now: now)
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(inputs[0].expectedFire, date(2026, 9, 7, 6, 20))
        XCTAssertEqual(inputs[0].profile, "alpha")
        XCTAssertFalse(inputs[0].isMulti)
        XCTAssertEqual(inputs[1].expectedFire, date(2026, 9, 7, 7, 0))  // Monday
        XCTAssertTrue(inputs[1].isMulti)
    }

    func testUnreadableCadenceYieldsNoExpectedFire() {
        let s = schedule("com.github.tonyyo11.jamf-reports-community.alpha.x",
                         profile: "alpha", multi: false, cadence: "whenever")
        let inputs = LaunchAgentService.healthInputs(
            schedules: [s], statusProfile: nil, now: Date())
        XCTAssertNil(inputs.first?.expectedFire)
    }

    func testTickerDisabledCollapsesEverythingIntoOneIssue() {
        let now = date(2026, 9, 7, 14, 30)
        let overdue = LaunchAgentService.ScheduleHealthInput(
            label: "com.github.tonyyo11.jamf-reports-community.alpha.x", displayName: "x",
            enabled: true, profile: "alpha", isMulti: false,
            expectedFire: date(2026, 9, 7, 6, 20), lastRunFinishedAt: nil,
            lastRunSuccess: nil, lastRunExitCode: nil)
        for status in [TickerStatus.requiresApproval, .notRegistered] {
            let issues = AutomationHealth.evaluate(inputs: [overdue], tickerStatus: status, now: now)
            XCTAssertEqual(issues.map(\.kind), [.tickerDisabled], "\(status)")
            XCTAssertEqual(issues.first?.label, AutomationHealth.tickerLabel)
            XCTAssertTrue(issues.first?.isMulti == true)
        }
        XCTAssertEqual(AutomationHealth.evaluate(
            inputs: [overdue], tickerStatus: .enabled, now: now).map(\.kind), [.overdue])
        // A dev build (unavailable) is not a disabled ticker.
        XCTAssertEqual(AutomationHealth.evaluate(
            inputs: [overdue], tickerStatus: .unavailable, now: now).map(\.kind), [.overdue])
    }
}
```

- [ ] **Step 2: Run to verify compile failure**

Run: `cd app && swift build --build-tests 2>&1 | grep -E "error:" | head -3`
Expected: errors naming `healthInputs(schedules:`, `tickerStatus:`, `.tickerDisabled`.

- [ ] **Step 3: Replace the plist-scanning builder**

Delete `healthInputs(in:now:)`, `scannedHealthInputs`, `healthInput(for:now:statusProfile:)` and `healthInputs(for:in:now:)`. Keep `ScheduleHealthInput`, `multiRunStatus`, `filterHealthInputs`, the status readers. Add:

```swift
    /// Health inputs from the schedules the tick evaluates. `statusProfile`
    /// keeps the 2.6 rule: a multi schedule's status is read from THAT
    /// profile's own record, never a different profile's later success.
    static func healthInputs(
        schedules: [Schedule], statusProfile: String?, now: Date = Date()
    ) -> [ScheduleHealthInput] {
        schedules.compactMap { schedule in
            guard let label = schedule.launchAgentLabel else { return nil }
            let entries = (try? LaunchAgentWriter.calendarIntervals(for: schedule.schedule)) ?? []
            let expected = entries.isEmpty ? nil : lastScheduledFireDate(from: entries, before: now)
            let status: ParsedRunStatus?
            if schedule.isMulti {
                status = multiRunStatus(label: label, args: [], statusProfile: statusProfile)
            } else {
                status = readRunStatus(
                    from: statusFileURL(from: [], profile: schedule.profile, label: label),
                    profile: schedule.profile)
            }
            return ScheduleHealthInput(
                label: label, displayName: schedule.name, enabled: schedule.enabled,
                profile: schedule.profile, isMulti: schedule.isMulti, expectedFire: expected,
                lastRunFinishedAt: status?.finishedAt, lastRunSuccess: status?.success,
                lastRunExitCode: status?.exitCode)
        }
    }
```

`statusFileURL(from:profile:label:)` with an empty args array already resolves the `<workspace>/automation/<label>_status.json` default (that is how `multiRunStatus` calls it today); confirm at its definition (~964) and adapt if it requires a `--status-file` argument.

- [ ] **Step 4: The ticker issue**

In `WorkspaceStore+Automation.swift`: add `case tickerDisabled` to `AutomationHealthIssue.Kind`; add `static let tickerLabel = "\(LaunchAgentWriter.labelPrefix).tick"` to `AutomationHealth`; change `evaluate` to:

```swift
    static func evaluate(
        inputs: [LaunchAgentService.ScheduleHealthInput],
        tickerStatus: TickerStatus = .enabled,
        now: Date = Date()
    ) -> [AutomationHealthIssue] {
        if tickerStatus == .requiresApproval || tickerStatus == .notRegistered {
            return [AutomationHealthIssue(
                label: tickerLabel,
                displayName: "Background item disabled",
                kind: .tickerDisabled, isMulti: true, profile: "",
                expectedFire: nil, lastRunFinishedAt: nil)]
        }
        // … existing body unchanged …
    }
```

`refreshAutomationHealth` builds inputs with
`LaunchAgentService.healthInputs(schedules: schedules, statusProfile: profile, now: Date())`
filtered through `filterHealthInputs(_:forProfile:)`, and passes `tickerStatus: tickerStatus`.
`runNowFromHealthRow(label:)` becomes
`await TickRunner.spawnNow(label: label, wait: false) == 0`.
In `main.swift`, `notifyOverdueSchedulesHeadless` builds inputs with
`LaunchAgentService.healthInputs(schedules: WorkspaceStore.loadSchedules(baseProfile: profiles.first), statusProfile: nil)`.
In `AutomationView.HealthCard.healthRow`, a `.tickerDisabled` issue renders one `PNPButton(title: "Open Login Items", size: .sm) { workspace.tickerRegistrar.openLoginItems() }` in place of Run now / Run History. Overview's summary banner needs no change: it counts issues.

- [ ] **Step 5: Build and run**

Run: `cd app && swift build --build-tests 2>&1 | grep -E "error:|Build complete" | tail -3`
Expected: `Build complete!`.

Run: `cd app && swift test --filter "ScheduleHealthInputsTests|AutomationHealthTests|LaunchAgentServiceTests|ScheduledRunSignalsTests" 2>&1 | grep -E "Executed [0-9]+ tests|error: -" | tail -4`
Expected: 0 failures on all four.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/JamfReports/Services/LaunchAgentService.swift \
        app/Sources/JamfReports/Services/WorkspaceStore+Automation.swift \
        app/Sources/JamfReports/App/main.swift \
        app/Sources/JamfReports/Views/AutomationView.swift \
        app/Tests/JamfReportsTests/ScheduleHealthInputsTests.swift \
        app/Tests/JamfReportsTests/LaunchAgentServiceTests.swift
git commit -m "feat(health): dead-man inputs from schedules; one issue when the ticker is disabled"
```

---

### Task 9: Schedules screen and Automation screen on the store

**Files:**
- Modify: `app/Sources/JamfReports/Views/SchedulesView.swift` (`runSchedule`/Run now ~575–598, `toggleSchedule` ~601–632, `deleteSchedule` ~634–660, `saveSchedule` ~662–677)
- Modify: `app/Sources/JamfReports/Views/AutomationView.swift` (banner near the item-2 banner ~107, `refreshConsolidationCandidates` ~190, `removeSelectedAgents` ~204, `ConsolidationCard` ~681)
- Modify: `app/Sources/JamfReports/Services/ScheduleConsolidation.swift` (replace `candidates(installed:policy:)`)
- Test: replace `app/Tests/JamfReportsTests/ScheduleConsolidationTests.swift`

**Interfaces:**
- Consumes: `ScheduleStore`, `ScheduleRecord`, `TickRunner.spawnNow`, `LaunchAgentService.installedLegacy`, `LaunchAgentService.archiveAndRemove`, `WorkspaceStore.applyAutomationPolicy`, `WorkspaceStore.tickerStatus`, `tickerRegistrar.openLoginItems()`.
- Produces: `ScheduleConsolidation.stillLoaded(installed:storeLabels:) -> [Candidate]` where `Candidate` keeps `label`, `displayName`, `mode` and `coveredBy` becomes `"the JamfReports background item"`.

- [ ] **Step 1: Replace the consolidation tests**

```swift
// app/Tests/JamfReportsTests/ScheduleConsolidationTests.swift
import XCTest
@testable import JamfReports

final class ScheduleConsolidationTests: XCTestCase {
    private let prefix = LaunchAgentWriter.labelPrefix

    private func schedule(_ label: String, profile: String = "alpha") -> Schedule {
        Schedule(
            name: label.components(separatedBy: ".").last ?? label, profile: profile,
            schedule: "Daily 06:20", cadence: "custom", mode: .jamfCLIFull, next: "—",
            last: "—", lastStatus: .ok, artifacts: [], enabled: true, launchAgentLabel: label)
    }

    func testOnlyImportedPlistsStillOnDiskAreCandidates() {
        let imported = schedule("\(prefix).alpha.nightly")
        let notImported = schedule("\(prefix).alpha.weird")
        let managed = schedule("\(prefix).multi.managed-scan", profile: "")
        let out = ScheduleConsolidation.stillLoaded(
            installed: [imported, notImported, managed],
            storeLabels: ["\(prefix).alpha.nightly"])
        XCTAssertEqual(out.map(\.label), ["\(prefix).alpha.nightly"])
        XCTAssertEqual(out.first?.coveredBy, "the JamfReports background item")
    }

    func testNoPlistsNoCandidates() {
        XCTAssertTrue(ScheduleConsolidation.stillLoaded(installed: [], storeLabels: ["x"]).isEmpty)
    }
}
```

- [ ] **Step 2: Rewrite ScheduleConsolidation**

Keep the `Candidate` struct (fields `label`, `displayName`, `mode`, `coveredBy`); delete `candidates(installed:policy:)` and `coveringCapability`; add:

```swift
    /// Imported hand-built plists that are still loaded by launchd. Until the
    /// operator retires them, each fires twice: once from launchd, once from
    /// the tick. Managed plists never appear here — the first launch removed them.
    static func stillLoaded(installed: [Schedule], storeLabels: Set<String>) -> [Candidate] {
        installed.compactMap { s in
            guard let label = s.launchAgentLabel, storeLabels.contains(label),
                  !ManagedAutomation.owns(label) else { return nil }
            return Candidate(label: label, displayName: s.name, mode: s.mode,
                             coveredBy: "the JamfReports background item")
        }
    }
```

- [ ] **Step 3: SchedulesView on the store**

```swift
    private func runSchedule(_ schedule: Schedule) async {
        guard !workspace.demoMode, let label = LaunchAgentWriter.label(for: schedule) else { return }
        isRunning = true
        runLogLines = []
        let buf = LineBuffer()
        let exit = await TickRunner.spawnNow(label: label, wait: true) { line in
            buf.append(line)
            Task { @MainActor in runLogLines = buf.lines }
        }
        runLogLines = buf.lines
        isRunning = false
        lastRunMessage = "\(schedule.name) · exit \(exit)"
        workspace.reloadFromDisk()
    }

    private func toggleSchedule(_ schedule: Schedule) async {
        guard var record = ScheduleRecord(schedule: schedule) else {
            writeError = "This schedule cannot be edited here."; showWriteError = true; return
        }
        record.enabled.toggle()
        do { try ScheduleStore().upsert(record) } catch {
            writeError = error.localizedDescription; showWriteError = true; return
        }
        workspace.reloadFromDisk()
    }

    private func deleteSchedule(_ schedule: Schedule) {
        guard !workspace.demoMode, let label = LaunchAgentWriter.label(for: schedule) else { return }
        guard !ManagedAutomation.owns(label) else {
            writeError = "\(schedule.name) is a managed automation agent — "
                + "turn off Manage automation to remove it."
            showWriteError = true
            return
        }
        do { try ScheduleStore().remove(label: label) } catch {
            writeError = error.localizedDescription; showWriteError = true; return
        }
        Task { await workspace.applyAutomationPolicy() }
    }

    private func saveSchedule(_ form: ScheduleFormState) async {
        guard let record = ScheduleRecord(schedule: form.toSchedule()) else {
            writeError = "Schedule name or profile produces an invalid label."
            showWriteError = true
            return
        }
        do { try ScheduleStore().upsert(record) } catch {
            writeError = "Could not save schedule · \(error.localizedDescription)"
            showWriteError = true
            return
        }
        await workspace.applyAutomationPolicy()
    }
```

Keep the existing `Run now` button, run-log sheet and `LineBuffer`; only the four functions change. `runSchedule`'s name here is the view's private method (it predates this plan); it does not collide with the global `runSchedule(_:verbose:)` because it is a member.

- [ ] **Step 4: AutomationView: ticker banner and import card**

Directly after the existing `bundleLocationWarning` banner (item 2) and before `masterCard`:

```swift
                if workspace.tickerStatus == .requiresApproval
                    || workspace.tickerStatus == .notRegistered {
                    InlineBanner(
                        icon: "exclamationmark.triangle", tone: .danger,
                        action: .init(label: "Open Login Items") {
                            workspace.tickerRegistrar.openLoginItems()
                        }
                    ) {
                        Text("Automation is off: JamfReports is not allowed to run in the "
                            + "background. Turn it on under Login Items › Allow in the Background.")
                            .font(.callout)
                    }
                } else if workspace.tickerStatus == .unavailable {
                    InlineBanner(icon: "hammer", tone: .info) {
                        Text("Ticker unavailable in this build — schedules run only via "
                            + "`JamfReports --tick` until the app is installed.")
                            .font(.callout)
                    }
                }
```

`refreshConsolidationCandidates` becomes:

```swift
    private func refreshConsolidationCandidates() {
        guard !workspace.demoMode else { consolidationCandidates = []; selectedForRemoval = []; return }
        let installed = LaunchAgentService.installedLegacy().schedules
        let storeLabels = Set(ScheduleStore().load().map(\.label))
        consolidationCandidates = ScheduleConsolidation.stillLoaded(
            installed: installed, storeLabels: storeLabels)
        selectedForRemoval = selectedForRemoval.intersection(Set(consolidationCandidates.map(\.label)))
    }
```

and its guard no longer depends on `policy.isManaged`; the card shows in both modes (it is about legacy plists, not the policy). `removeSelectedAgents` is unchanged. `ConsolidationCard` copy: title `"Schedules now run by JamfReports"`; body text `"These schedules were imported and now run from the JamfReports background item, but their old LaunchAgent files are still loaded — each runs twice per fire until retired. Retiring archives the file to _archived-launchagents first."`; the per-row subtitle `"\(candidate.mode.displayTitle) · now run by \(candidate.coveredBy)"`; the dialog message keeps its restore sentence and drops "Managed agents are never affected."

- [ ] **Step 5: Build, run, and mark DRAFT**

Run: `cd app && swift build --build-tests 2>&1 | grep -E "error:|Build complete" | tail -3`
Expected: `Build complete!`.

Run: `cd app && swift test --filter "ScheduleConsolidationTests|ScheduleFormStateTests|SchedulesViewExitCodeTests" 2>&1 | grep -E "Executed [0-9]+ tests|error: -" | tail -3`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/JamfReports/Views/SchedulesView.swift app/Sources/JamfReports/Views/AutomationView.swift \
        app/Sources/JamfReports/Services/ScheduleConsolidation.swift \
        app/Tests/JamfReportsTests/ScheduleConsolidationTests.swift
git commit -F - <<'EOF'
feat(ui): Schedules screen edits the store; Automation shows ticker state and imported plists

DRAFT — needs visual verification at PageScaffold.minSupportedWidth
(two new banners above the master card; consolidation card copy).
EOF
```

---

### Task 10: `jamf-reports schedules` subcommand

**Files:**
- Create: `app/Sources/JamfReports/CLI/ScheduleCommands.swift`
- Modify: `app/Sources/JamfReports/CLI/JamfReportsCLI.swift` (`subcommands:` list, line ~18)
- Test: `app/Tests/JamfReportsTests/ScheduleCommandsTests.swift`

**Interfaces:**
- Consumes: `ScheduleStore`, `ScheduleRecord`, `Schedule`, `TickRunner.spawnNow`, `LaunchAgentWriter.calendarIntervals`, `CLIRun.fail`, `CLIRun.parseTiers`, `CLIRun.printLogLine`.
- Produces: `Schedules` (`AsyncParsableCommand`) with `List`, `Add`, `Remove`, `Run`; `Schedules.Add.record(name:profile:allProfiles:exclude:mode:cadence:tiers:disabled:) throws -> ScheduleRecord` (pure, tested).

- [ ] **Step 1: Write the failing tests**

```swift
// app/Tests/JamfReportsTests/ScheduleCommandsTests.swift
import XCTest
@testable import JamfReports

final class ScheduleCommandsTests: XCTestCase {

    func testAddBuildsARecordFromFlags() throws {
        let r = try Schedules.Add.record(
            name: "Nightly Snapshot", profile: "alpha", allProfiles: false, exclude: nil,
            mode: "snapshot-only", cadence: "Daily 06:20", tiers: "refresh,scan", disabled: false)
        XCTAssertEqual(r.label, "com.github.tonyyo11.jamf-reports-community.alpha.nightly-snapshot")
        XCTAssertEqual(r.mode, "snapshot-only")
        XCTAssertEqual(r.tiers, ["refresh", "scan"])
        XCTAssertTrue(r.enabled)
    }

    func testAddAllProfilesWithExclusions() throws {
        let r = try Schedules.Add.record(
            name: "fleet", profile: "alpha", allProfiles: true, exclude: "dummy, sandbox",
            mode: "jamf-cli-full", cadence: "Mon 07:00", tiers: nil, disabled: true)
        XCTAssertTrue(r.allProfiles)
        XCTAssertEqual(r.excludedProfiles, ["dummy", "sandbox"])
        XCTAssertFalse(r.enabled)
        XCTAssertNil(r.tiers)
    }

    func testAddRejectsBadModeCadenceProfileOrManagedName() {
        XCTAssertThrowsError(try Schedules.Add.record(
            name: "x", profile: "alpha", allProfiles: false, exclude: nil,
            mode: "nope", cadence: "Daily 06:20", tiers: nil, disabled: false))
        XCTAssertThrowsError(try Schedules.Add.record(
            name: "x", profile: "alpha", allProfiles: false, exclude: nil,
            mode: "backup", cadence: "whenever", tiers: nil, disabled: false))
        XCTAssertThrowsError(try Schedules.Add.record(
            name: "x", profile: "Bad Profile", allProfiles: false, exclude: nil,
            mode: "backup", cadence: "Mon 07:00", tiers: nil, disabled: false))
        XCTAssertThrowsError(try Schedules.Add.record(
            name: "managed-scan", profile: "alpha", allProfiles: true, exclude: nil,
            mode: "backup", cadence: "Mon 07:00", tiers: nil, disabled: false))
    }

    func testSchedulesIsAKnownSubcommand() {
        XCTAssertTrue(JamfReportsCLI.isKnownSubcommand("schedules"))
    }
}
```

- [ ] **Step 2: Run to verify compile failure**

Run: `cd app && swift build --build-tests 2>&1 | grep -E "error:" | head -3`
Expected: error naming `Schedules`.

- [ ] **Step 3: Implement**

```swift
// app/Sources/JamfReports/CLI/ScheduleCommands.swift
import ArgumentParser
import Foundation

struct Schedules: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, add, remove, or run hand-built schedules (managed ones come from Automation).",
        subcommands: [List.self, Add.self, Remove.self, Run.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List stored schedules.")
        func run() async throws {
            let records = ScheduleStore().load()
            if records.isEmpty { print("no hand-built schedules"); return }
            for r in records {
                let target = r.allProfiles ? "all-profiles" : r.profile
                let flag = r.enabled ? "" : " (disabled)"
                print("\(r.label)\t\(target)\t\(r.mode)\t\(r.schedule)\(flag)")
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add or replace a schedule.")
        @Option(help: "Display name; the label slug derives from it.") var name: String
        @Option(help: "Workspace profile slug (the base profile when --all-profiles).") var profile: String
        @Flag(help: "Run for every local profile.") var allProfiles = false
        @Option(help: "Comma-separated profiles to skip (with --all-profiles).") var exclude: String?
        @Option(help: "snapshot-only | jamf-cli-only | jamf-cli-full | csv-assisted | backup") var mode: String
        @Option(help: "Cadence: 'Daily 06:20', 'Mon 07:00', 'Weekdays 09:00', 'Day 15 06:20'.") var cadence: String
        @Option(help: "Comma-separated collect tiers (refresh,inventory,scan).") var tiers: String?
        @Flag(help: "Store disabled.") var disabled = false

        struct Invalid: Error, CustomStringConvertible { let description: String }

        static func record(
            name: String, profile: String, allProfiles: Bool, exclude: String?,
            mode: String, cadence: String, tiers: String?, disabled: Bool
        ) throws -> ScheduleRecord {
            guard ProfileService.isValid(profile) else { throw Invalid(description: "invalid profile '\(profile)'") }
            guard let runMode = Schedule.RunMode(rawValue: mode) else { throw Invalid(description: "unknown mode '\(mode)'") }
            _ = try LaunchAgentWriter.calendarIntervals(for: cadence)
            let tierSet: Set<CollectionTier>? = tiers.map(CLIRun.parseTiers)
            let excluded = exclude?.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let schedule = Schedule(
                name: name, profile: profile, schedule: cadence, cadence: "custom", mode: runMode,
                next: "—", last: "—", lastStatus: .ok, artifacts: [], enabled: !disabled,
                multiTarget: allProfiles ? MultiTarget(scope: .all, sequential: true) : nil,
                tiers: tierSet, excludedProfiles: allProfiles ? excluded : nil)
            guard let record = ScheduleRecord(schedule: schedule) else {
                throw Invalid(description: "'\(name)' does not make a valid, non-managed label")
            }
            return record
        }

        func run() async throws {
            let record: ScheduleRecord
            do {
                record = try Self.record(
                    name: name, profile: profile, allProfiles: allProfiles, exclude: exclude,
                    mode: mode, cadence: cadence, tiers: tiers, disabled: disabled)
            } catch { CLIRun.fail("\(error)") }
            try ScheduleStore().upsert(record)
            try? SMAppServiceRegistrar().register()
            print("saved \(record.label)")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a schedule by label.")
        @Argument(help: "Full label as printed by `schedules list`.") var label: String
        func run() async throws {
            guard ScheduleStore().load().contains(where: { $0.label == label }) else {
                CLIRun.fail("no schedule with label '\(label)'")
            }
            try ScheduleStore().remove(label: label)
            print("removed \(label)")
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a schedule now and wait.")
        @Argument(help: "Full label (hand-built or managed).") var label: String
        func run() async throws {
            let code = await TickRunner.spawnNow(label: label, wait: true, onLine: CLIRun.printLogLine)
            if code != 0 { CLIRun.fail("schedule exited \(code)", code: code) }
        }
    }
}
```

Register `Schedules.self` in `JamfReportsCLI.configuration.subcommands`. `CLIRun.parseTiers(_:)` takes `String?` today (check its signature at `JamfReportsCLI.swift:42`); pass `tiers` directly if so.

- [ ] **Step 4: Run**

Run: `cd app && swift test --filter "ScheduleCommandsTests|JamfReportsCLITests" 2>&1 | grep -E "Executed [0-9]+ tests|error: -" | tail -3`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/JamfReports/CLI/ScheduleCommands.swift app/Sources/JamfReports/CLI/JamfReportsCLI.swift \
        app/Tests/JamfReportsTests/ScheduleCommandsTests.swift
git commit -m "feat(cli): jamf-reports schedules list|add|remove|run over the schedule store"
```

---

### Task 11: Delete the plist mechanism

**Files:**
- Modify: `app/Sources/JamfReports/Services/ManagedAutomation.swift`, `LaunchAgentWriter.swift`, `LaunchAgentService.swift`, `CLIBridge.swift`, `ConfigDoctorService.swift`, `WorkspaceRootStore.swift`
- Modify tests: `ManagedAutomationTests.swift`, `LaunchAgentWriterTests.swift`, `LaunchAgentServiceTests.swift`, `ConfigDoctorAssemblerTests.swift` (if it asserts the bundle-location row)

**Interfaces:**
- Consumes: nothing new. This task only removes.

- [ ] **Step 1: Delete from ManagedAutomation**

Remove `Action`, `plan(for:installed:baseProfile:force:executablePath:)`, `ActionOutcome`, both `reconcile` overloads, `reconcileWithMigration`, `invalidateManagedPlists`, `migrationShouldComplete`, `defaultInstall`, `defaultInstallFileOnly`, `defaultRemove`, `defaultRemoveFileOnly`, `signature`, `actionSort`, and the `executablePath` parameters on `desiredSchedules`/`makeSchedule` (the 2.8.0 item-2 signature). Keep `ManagedKind`, `reservedLabels`, `label(for:)`, `owns`, `desiredSchedules`, `makeSchedule`, `mode`, `tiers`, `staggerMinutes`, `cadenceWord`, `scheduleString`, `staggeredTime`, `weekdayAbbrev`, `bundleLocationWarning`. Remove `Schedule.executablePath` from `Models.swift` and the `executablePath: args.first` line in `parse`.

In `ManagedAutomationTests.swift` delete every `testPlan*`, `testReconcile*`, `testMigration*` test and `testMonthlyReportsScheduleRoundTripsWithoutReinstallLoop`; keep the ownership, desired-specs, cadence-string and `bundleLocationWarning` tests. Delete `writeFakeMultiPlist`/`removeFakeMultiPlist` helpers.

- [ ] **Step 2: Delete from LaunchAgentWriter**

Remove `nativeSingleWrite`, `nativeMultiWrite`, `unload`, `runNow`, `runMultiNow`, `loadPlist`, `delete`, `launchctl`, `manualRunPlan`, `nativeManualRunPlan`, `nativeManualRunPlanFieldsForTesting`, `runManualPlan`, `scheduledRunEnvironment`, `tierArguments`, `excludeArguments`, `multiProgramArgumentsAreTrusted`, `legacyJamfCLIMultiArgumentsAreSafe`, `isTrustedNativeExecutable`, `SetupPlan`, `ManualRunPlan`, and the `expected*URL`/`isExpected*URL` helpers whose only callers were the deleted code (check each with `rg` before removing; `expectedStatusURL`/`isExpectedStatusURL` may still serve `LaunchAgentService`'s readers). Keep `labelPrefix`, `legacyLabelPrefix`, `WriterError`, `isValidLabel`, `isValidComponent`, `sanitizedSlug`, `label(for:)`, `isMultiLabel`, `calendarIntervals(for:)`, `CadenceOptions`, `setupCadence`, `parseHHMM`, `parseOrdinal`, `normalizedWeekday`, `isTrustedJamfCLIExecutable` (used by `CLIBridge`'s codesign gate — verify with `rg`).

In `LaunchAgentWriterTests.swift` delete the `testNativeSingleWrite*`, `testNativeMultiWrite*`, `testNativeManualRunPlan*`, `testLaunchEnvironment*`, `testIsExpectedMultiWorkingDirectory*` tests; keep label, slug, trusted-executable and `testExpectedMultiLogURLRejectsSymlinkedLogFile` if its subject survived.

- [ ] **Step 3: Delete from LaunchAgentService**

Remove `list`, `staleExecutableLabels`, `dottedLegacyAgents`, `cleanupLegacyAgents`, `LegacyCleanupResult`, `removeAgents`, `kickstartNow`, `KickstartOutcome`, `defaultRunLaunchctl`, `bootout`. In `LaunchAgentServiceTests.swift` delete `testStaleExecutableLabels*` and `testKickstartNow*`; rewrite `testTiersRoundTripThroughWriteAndParse` and `testExcludeProfilesRoundTripThroughWriteAndParse` to write the plist dictionary with the existing `writePlist` helper instead of calling `nativeMultiWrite` (the parse side is what import relies on). `MigrationBanner` takes `legacySchedules: [String]`; its caller in `ContentView` passed `LaunchAgentService.dottedLegacyAgents()` — pass `[]` and leave the banner's workspace half intact.

- [ ] **Step 4: Delete from CLIBridge, ConfigDoctorService, WorkspaceRootStore**

`CLIBridge`: remove `setupLaunchAgent` and `setupMultiLaunchAgent`. `ConfigDoctorService`: remove `evaluateBundleLocation` and its `rows +=` line; drop its assertions from `ManagedAutomationTests.testBundleLocationWarningOnlyOutsideApplicationsFolders`. `WorkspaceRootStore.set(_:)`: remove the `ManagedAutomation.invalidateManagedPlists(defaults:)` call (the tick reads the preference directly). `WorkspaceStore`: remove the `JRC_WORKSPACES_ROOT` doc mention in `WorkspaceRootStore` only where it says LaunchAgents set it; the env var itself stays for the included CLI.

- [ ] **Step 5: Build, then run the FULL suite**

Run: `cd app && swift build --build-tests 2>&1 | grep -E "error:|Build complete" | tail -5`
Expected: `Build complete!`. Every remaining `error:` names a caller of deleted code; fix it by deleting the caller, never by re-adding the callee.

Run: `cd app && swift test 2>/private/tmp/full.log >/private/tmp/full.out; echo EXIT=$?; grep -oE "Executed [0-9]+ tests, with [0-9]+ failures" /private/tmp/full.out | tail -1`
Expected: `EXIT=0`, `with 0 failures`.

Run: `cd app && rg -n "launchctl|bootstrap gui|bootout gui|nativeMultiWrite|kickstart" Sources | grep -v "^.*//"`
Expected: no output. Anything left is a missed caller.

- [ ] **Step 6: Commit**

```bash
git add -A app
git commit -m "refactor(automation): delete LaunchAgent plist generation, launchctl, and the reconcile machinery"
```

---

### Task 12: Docs and version

**Files:**
- Modify: `CLAUDE.md`, `AGENTS.md` (mirror via `cp CLAUDE.md AGENTS.md` after editing), `CHANGELOG.md`, `README.md`, `docs/wiki/05-Scheduling-and-Automation.md`, `docs/wiki/05b-Automation-Trust.md`, `docs/wiki/07-Command-Line.md`, `docs/wiki/10-Security-and-Operational-Considerations.md`, `docs/wiki/Glossary.md`, `docs/wiki/Home.md`, `app/build-app.sh` (`MARKETING_VERSION`), `app/Sources/JamfReports/Models/AppVersionState.swift` (`fallbackVersion`)

- [ ] **Step 1: Version pair**

Version pair is already 2.8.0 on this branch — nothing to change; run the drift test as a sanity check.

Run: `cd app && swift test --filter AppVersionDriftTests 2>&1 | grep -E "Executed [0-9]+ tests|error: -" | tail -2`
Expected: 0 failures.

- [ ] **Step 2: CHANGELOG under `## [2.8.0]`** (merge into its existing Changed/Added sections; add a Removed section)

```markdown
### Changed

- Scheduling no longer writes files into `~/Library/LaunchAgents`. One
  app-owned background item ("JamfReports" under Login Items › Allow in the
  Background) wakes every five minutes and runs whatever schedule is due, so
  a schedule set for 06:20 starts by 06:25. Managed automation and hand-built
  schedules both run this way; hand-built schedules now live in
  `~/Library/Application Support/JamfReports/schedules.json` and survive
  moving or updating the app.
- On first launch, existing JamfReports LaunchAgents are imported. Managed
  ones are archived and removed at once; hand-built ones stay loaded until
  you retire them from the Automation screen, and run twice per fire until
  you do — the screen says so.
- A missed run (Mac asleep, logged out) catches up once on the next wake for
  collect schedules; generate-from-cache and backup schedules only run when
  the missed time is within the last 15 minutes, as before.
- If macOS shows the background item as off, the Automation screen and the
  Overview banner say so with an "Open Login Items" button, instead of every
  schedule reading as overdue.

### Added

- `jamf-reports schedules list|add|remove|run` — hand-built schedules are
  scriptable for the first time.

### Removed

- The "Software from … can run in the background" notification on every app
  update, which came from each LaunchAgent being re-registered when its
  binary changed. The 2.8.0 executable-path check and the Config Doctor
  "not in an Applications folder" row are gone with the plists; the banner
  on the Automation screen stays.
```

- [ ] **Step 3: CLAUDE.md**

Replace the `ManagedAutomation` row's description with: derives the four managed schedules from `AutomationPolicy` (`desiredSchedules`), owns the reserved labels (`owns` exact membership), no install/remove — nothing is on disk to reconcile since 2.9.0. Replace the `LaunchAgentWriter` row: labels and cadence strings only (`label(for:)`, `isValidLabel`, `calendarIntervals(for:)`); writes nothing. Replace the `LaunchAgentService` row: `parse`/`installedLegacy` for import, `lastScheduledFireDate`, status readers, `healthInputs(schedules:statusProfile:now:)`, `archiveAndRemove`. Add rows for `ScheduleStore`, `TickScheduler`/`TickState`/`TickLock`, `TickerRegistrar`, `ScheduleImport`, `TickRunner`, `AppSupport`. Rewrite the "Managed automation model" paragraph and the "Schedule mode contract" intro so the LaunchAgent path reads: "the bundled agent's `--tick` and an external scheduler's `--scheduled-run` share `runSchedule`". In "Security model" replace the UserAgents-only bullet with: one `SMAppService` agent inside the signed bundle; the app never writes to `~/Library/LaunchAgents`; no `sudo`, no daemons. Update the Files tree with `app/LaunchAgents/`. Then `cp CLAUDE.md AGENTS.md`.

- [ ] **Step 4: Wiki and README**

`05-Scheduling-and-Automation.md`: replace every "LaunchAgent"/"launchctl" instruction with the Login Items item, the 5-minute wake, the catch-up rules, and the import/retire flow. `05b-Automation-Trust.md`: the dead-man switch's "background item disabled" state and its button. `07-Command-Line.md`: the `schedules` subcommand with the four cadence forms; keep the `--scheduled-run` caveat paragraph, reworded: "an external scheduler calling `--scheduled-run` gets Run History and webhooks but not the tick's catch-up." `10-Security-and-Operational-Considerations.md`: the LaunchAgents-never-sync paragraph becomes "the background item is registered per machine from the app bundle; `schedules.json` under Application Support is per machine and must not be synced." `Glossary.md`: add "Background item (ticker)"; retire "LaunchAgent" to a historical note. `Home.md` and `README.md`: one sentence each where LaunchAgents are named.

Run: `rg -n "LaunchAgent|launchctl" README.md docs/wiki CLAUDE.md | grep -viE "historical|legacy|imported|_archived-launchagents|Contents/Library/LaunchAgents"`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md AGENTS.md CHANGELOG.md README.md docs/wiki app/build-app.sh \
        app/Sources/JamfReports/Models/AppVersionState.swift
git commit -m "docs(2.8.0): one background item replaces LaunchAgents"
```

---

## Acceptance on a real Mac (after the plan, before the PR)

Build a beta with `build-app.sh` + `build-pkg.sh`, install to `/Applications`, launch once:

1. `sfltool dumpbtm | grep -A12 JamfReports` shows ONE item of type `app`/agent with `Contents/Library/LaunchAgents/…tick.plist`, and Login Items lists one "JamfReports" row.
2. `~/Library/LaunchAgents` holds no `com.github.tonyyo11.jamf-reports-community.multi.managed-*` file; any hand-built plist appears on the Automation screen's import card.
3. Set a managed run time two minutes ahead; the run appears in Run History within five minutes of it.
4. Install a second beta over the first: no "Software from Anthony Young can run in the background" notification.
5. Toggle the item off in Login Items: the Automation screen shows the disabled banner; toggling it back on clears it after the next foreground.
6. `jamf-reports schedules add --name test --profile <p> --mode snapshot-only --cadence "Daily 06:20"` then `schedules list` shows it and the Schedules screen shows the same row.

## Self-review

**Spec coverage.** §1 store → Task 1; due rule, catch-up, 15-minute rule → Task 2; lock → Task 3; deletions of env/log paths/flag → Tasks 6, 11. §2 registration on every launch → Task 7 (`applyAutomationPolicy` from `ContentView`'s launch task); `.requiresApproval` surfacing + button → Tasks 8, 9; import → Task 7; ask-before-removing card → Task 9; managed plists removed without asking → Task 7; unregister when nothing scheduled → Task 7. §3 dead-man → Task 8; Run History unchanged (no task; `runSchedule` keeps the recorder); Run now markers and spawn → Tasks 6, 8, 9; CLI → Task 10. §4 plist + build → Task 5; dev-build banner → Task 9; tests → per task; deletions → Task 11; rollout/docs/version → Task 12.

**Spec deviations, restated.** Last-started stamps live in `tick-state.json` (spec said the status file, which has no start time). Run-now markers live under Application Support (spec said a workspace `automation/` dir). Both recorded in Global Constraints.

**Type consistency.** `ScheduleRecord.mode`/`tiers` are strings (Task 1) and every later task converts through `toSchedule()`; `TickScheduler.due` takes `runNowLabels: Set<String>` and `TickRunner.consumeRunNowMarkers` returns `Set<String>` (Task 6); `healthInputs(schedules:statusProfile:now:)` is the one builder used by Task 8's `refreshAutomationHealth` and `main.swift`; `AutomationHealth.evaluate(inputs:tickerStatus:now:)` defaults `tickerStatus` to `.enabled` so existing `AutomationHealthTests` compile unchanged; `WorkspaceStore.loadSchedules(policy:store:baseProfile:)` is `nonisolated static` and is what Tasks 7, 8 and the tick's own derivation mirror (the tick calls `desiredSchedules` + the store directly; keep them equivalent — if the ordering rule changes, change both).

**Known open edges.** `ProfileService.parseExclusions` return type (Task 6, adapt the `Array(...)`); `statusFileURL(from: [], …)` default (Task 8, confirm); `CLIRun.parseTiers` parameter type (Task 10); `LogLineTextCollector` may be test-only (Task 6, drop it). Each is a one-line check the implementer makes before the step.
