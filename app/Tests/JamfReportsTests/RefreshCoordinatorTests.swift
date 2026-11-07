import Foundation
import XCTest
@testable import JamfReports

/// `RefreshPolicy` + `RefreshCoordinator` are keyed on `CollectionTier`
/// (`refresh`/`inventory`/`scan`). Only `.refresh` is populated in the
/// default policy — it's the sole tier the coordinator drives.
final class RefreshCoordinatorTests: XCTestCase {

    // MARK: - RefreshPolicy staleness threshold

    func testDefaultPolicyRefreshThreshold() {
        let policy = RefreshPolicy.default
        // Default fallback is the on-prem Refresh cadence × 1.5 — matches the
        // preset-aware formula so a config-read failure degrades to the same
        // number rather than a surprise.
        XCTAssertEqual(
            policy.stalenessThreshold,
            TimeInterval(CollectionTier.refresh.intervalSeconds) * 1.5
        )
    }

    // MARK: - Backoff curve

    func testNoBackoffOnZeroFailures() {
        let policy = RefreshPolicy.default
        let interval = policy.backoffInterval(tier: .refresh, failureCount: 0)
        XCTAssertEqual(interval, TimeInterval(CollectionTier.refresh.intervalSeconds))
    }

    func testBackoffDoublesOnFirstFailure() {
        let policy = RefreshPolicy.default
        let base = TimeInterval(CollectionTier.refresh.intervalSeconds)
        XCTAssertEqual(policy.backoffInterval(tier: .refresh, failureCount: 1), base * 2.0)
    }

    func testBackoffQuadruplesOnSecondFailure() {
        let policy = RefreshPolicy.default
        let base = TimeInterval(CollectionTier.refresh.intervalSeconds)
        XCTAssertEqual(policy.backoffInterval(tier: .refresh, failureCount: 2), base * 4.0)
    }

    func testBackoffCappedAtMaxMultiplier() {
        let policy = RefreshPolicy.default
        let base = TimeInterval(CollectionTier.scan.intervalSeconds)
        // 2^10 = 1024 >> maxBackoffMultiplier (8)
        let capped = policy.backoffInterval(tier: .scan, failureCount: 10)
        XCTAssertEqual(capped, base * policy.maxBackoffMultiplier)
    }

    func testBackoffCapIsEight() {
        XCTAssertEqual(RefreshPolicy.default.maxBackoffMultiplier, 8.0)
    }

    // MARK: - shouldBackOff

    func testNoBackoffBelowMaxFailures() {
        let policy = RefreshPolicy.default
        // maxFailures for .refresh is 3; with 2 failures no backoff yet.
        let shouldSkip = policy.shouldBackOff(
            tier: .refresh,
            failureCount: 2,
            lastAttempt: Date().addingTimeInterval(-1),
            now: Date()
        )
        XCTAssertFalse(shouldSkip)
    }

    func testBackoffActiveImmediatelyAfterMaxFailures() {
        let policy = RefreshPolicy.default
        // maxFailures for .refresh is 3; after exactly 3 failures the next
        // attempt triggers backoff if the elapsed time is less than the
        // backoff interval.
        let shouldSkip = policy.shouldBackOff(
            tier: .refresh,
            failureCount: 3,
            lastAttempt: Date().addingTimeInterval(-1),  // 1 second ago
            now: Date()
        )
        XCTAssertTrue(
            shouldSkip,
            "Should back off when failureCount == maxFailures and not enough time has elapsed"
        )
    }

    func testBackoffExpiredAllowsRetry() {
        let policy = RefreshPolicy.default
        // After 3 failures, backoff interval = intervalSeconds × 2^3.
        // With the Refresh tier's 86 400 s base that's 691 200 s; a last
        // attempt older than that means backoff has expired.
        let backoff = TimeInterval(CollectionTier.refresh.intervalSeconds) * 8.0
        let lastAttempt = Date().addingTimeInterval(-(backoff + 1))
        let shouldSkip = policy.shouldBackOff(
            tier: .refresh,
            failureCount: 3,
            lastAttempt: lastAttempt,
            now: Date()
        )
        XCTAssertFalse(shouldSkip, "Backoff should have expired past the 8× interval")
    }

    // MARK: - RefreshPolicy custom init

    func testCustomPolicyRespectsThresholds() {
        let policy = RefreshPolicy(
            stalenessThreshold: 60,
            maxFailures: 1,
            backoffBase: 3.0,
            maxBackoffMultiplier: 4.0
        )
        XCTAssertEqual(policy.stalenessThreshold, 60)
        XCTAssertEqual(policy.maxFailures, 1)
        // Backoff multiplies the tier's natural cadence interval (not staleness threshold).
        XCTAssertEqual(
            policy.backoffInterval(tier: .refresh, failureCount: 1),
            TimeInterval(CollectionTier.refresh.intervalSeconds) * 3.0
        )
    }

    // MARK: - CollectionTier interval reference

    func testTierIntervalsAreFixedCloudCadence() {
        // intervalSeconds is the fixed cloud collection cadence — the fixed
        // denominator for backoff math. Pinned so a preset-table change
        // doesn't silently shift backoff timing.
        XCTAssertEqual(CollectionTier.refresh.intervalSeconds, 43_200)
        XCTAssertEqual(CollectionTier.inventory.intervalSeconds, 172_800)
        XCTAssertEqual(CollectionTier.scan.intervalSeconds, 604_800)
    }

    func testTheRefreshProbeKindIsARealCollectKind() throws {
        // The probe kind must be a directory ReportEngine.collect writes,
        // or the mtime probe finds nothing and reports everything stale.
        let probe = try XCTUnwrap(CollectionTier.refresh.stalenessProbeKind)
        XCTAssertTrue(ReportEngine.knownCollectKinds.contains(probe))
        XCTAssertEqual(CollectionTier.tier(forReport: probe), .refresh)
    }

    func testAProtectOnlyEnvironmentProbesProtectOverviewAndProStillProbesOverview() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        for (name, yaml) in [("po", "profiles:\n  protect: po\n"),
                             ("prod", "jamf_cli:\n  profile: prod\n")] {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(yaml.utf8).write(to: dir.appendingPathComponent("config.yaml"))
        }
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertEqual(RefreshCoordinator.probeKind(for: .refresh, profile: "po"),
                       "protect-overview")
        XCTAssertEqual(RefreshCoordinator.probeKind(for: .refresh, profile: "prod"), "overview")
    }

    // MARK: - Coordinator entry points (PR-24 — now wired)
    //
    // PR-24 connects observeProfileSwitch (profile switch) and
    // refreshIfStale (foreground/launch) to real callers, so these public
    // entry points are now load-bearing. The guard paths below resolve
    // synchronously — no waiting on the 500 ms debounce.

    @MainActor
    func testRefreshIfStaleNoOpsForNonRefreshTier() {
        let coordinator = RefreshCoordinator { profile, tier in
            try await CLIBridge().collect(
                profile: profile, tiers: [tier], force: true, onLine: CLIBridge.noOpOnLine)
        }
        coordinator.refreshIfStale(profile: "validprofile", tier: .inventory)
        XCTAssertFalse(
            coordinator.isRefreshing(profile: "validprofile", tier: .inventory),
            "Only the .refresh tier is wired; .inventory must no-op"
        )
        coordinator.refreshIfStale(profile: "validprofile", tier: .scan)
        XCTAssertFalse(coordinator.isRefreshing(profile: "validprofile", tier: .scan))
    }

    @MainActor
    func testRefreshIfStaleNoOpsForInvalidProfile() {
        let coordinator = RefreshCoordinator { profile, tier in
            try await CLIBridge().collect(
                profile: profile, tiers: [tier], force: true, onLine: CLIBridge.noOpOnLine)
        }
        // A line break fails ProfileService.isValid — the guard must
        // catch it before any task is queued.
        coordinator.refreshIfStale(profile: "Bad\nProfile", tier: .refresh)
        XCTAssertFalse(coordinator.isRefreshing(profile: "Bad\nProfile", tier: .refresh))
    }

    @MainActor
    func testObserveProfileSwitchCoalescesRapidCalls() {
        // Cycling the sidebar chip fires observeProfileSwitch repeatedly.
        // The debounce means none of them have started a refresh yet — the
        // coordinator must stay quiet (and not crash) through the burst.
        let coordinator = RefreshCoordinator { profile, tier in
            try await CLIBridge().collect(
                profile: profile, tiers: [tier], force: true, onLine: CLIBridge.noOpOnLine)
        }
        coordinator.observeProfileSwitch("alpha")
        coordinator.observeProfileSwitch("beta")
        coordinator.observeProfileSwitch("gamma")
        XCTAssertEqual(coordinator.failureCount(profile: "gamma", tier: .refresh), 0)
        XCTAssertFalse(coordinator.isRefreshing(profile: "gamma", tier: .refresh))
    }
}

/// #368: the coordinator's collect, and what a run that leaves the data stale counts as.
@MainActor
final class RefreshCoordinatorOutcomeTests: XCTestCase {
    private func run(
        exit: Int32 = 0, stale: [Bool], thrown: Error? = nil
    ) async -> (coordinator: RefreshCoordinator, collects: Int) {
        var answers = stale
        var collects = 0
        let coordinator = RefreshCoordinator(
            isStale: { _, _ in answers.isEmpty ? false : answers.removeFirst() },
            collect: { _, _ in
                collects += 1
                if let thrown { throw thrown }
                return exit
            })
        await coordinator.refreshIfStale(profile: "alpha", tier: .refresh)?.value
        return (coordinator, collects)
    }

    func testExitZeroWithFreshDataIsASuccess() async {
        let (coordinator, collects) = await run(stale: [true, false])
        XCTAssertEqual(collects, 1)
        XCTAssertEqual(coordinator.failureCount(profile: "alpha", tier: .refresh), 0)
        XCTAssertNotNil(coordinator.lastSuccessfulRefresh["alpha"])
    }

    func testExitZeroThatLeavesDataStaleCountsAsAFailure() async {
        let (coordinator, _) = await run(stale: [true, true])
        XCTAssertEqual(coordinator.failureCount(profile: "alpha", tier: .refresh), 1)
        XCTAssertNil(coordinator.lastSuccessfulRefresh["alpha"])
    }

    func testBackoffStopsRepeatedCollectsThatLeaveDataStale() async {
        var collects = 0
        let coordinator = RefreshCoordinator(
            isStale: { _, _ in true },
            collect: { _, _ in
                collects += 1
                return 0
            })
        for _ in 0..<6 {
            await coordinator.refreshIfStale(profile: "alpha", tier: .refresh)?.value
        }
        XCTAssertEqual(collects, RefreshPolicy.default.maxFailures)
    }

    func testFreshDataRunsNoCollect() async {
        let (_, collects) = await run(stale: [false])
        XCTAssertEqual(collects, 0)
    }

    func testARefusedCollectCountsAsNothingAttempted() async {
        let (coordinator, _) = await run(stale: [true], thrown: CLIBridgeError.collectInProgress)
        XCTAssertEqual(coordinator.failureCount(profile: "alpha", tier: .refresh), 0)
    }

    func testGenerateSheetNamesTheCollectItWaitsFor() {
        func message(_ refusal: CLIBridgeError?, status: String? = nil) -> String? {
            GenerateSheetState.waitingMessage(isRunning: false, refusal: refusal, status: status)
        }
        XCTAssertEqual(message(.collectInProgress, status: "refreshing data"),
                       "Waiting for: refreshing data")
        XCTAssertEqual(message(.collectInProgress), "Waiting for: a refresh to finish")
        XCTAssertEqual(message(.generateInProgress), "Waiting for: a report to finish")
        XCTAssertEqual(message(.toolUpdateInProgress),
                       "Waiting for: the jamf-cli update to finish")
        XCTAssertEqual(message(.tickLockHeld), "Waiting for: a scheduled run to finish")
        XCTAssertNil(message(nil))
        XCTAssertNil(GenerateSheetState.waitingMessage(
            isRunning: true, refusal: .collectInProgress, status: "x"))
    }

    /// A refused background refresh must leave the running collect's status line alone (#368).
    func testARefusedBackgroundRefreshKeepsTheRunningCollectsStatus() async throws {
        let store = WorkspaceStore(
            demoMode: false, tickerRegistrar: StubTickerRegistrar(),
            jamfCLIProfileNames: { [] }, discoverProfiles: { [] }, jamfCLIInstallation: { nil })
        store.beginCollect(for: "alpha", status: "refreshing Inventory data")
        do {
            _ = try await store.runBackgroundRefresh(profile: "alpha", tier: .refresh)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? CLIBridgeError, .collectInProgress)
        }
        XCTAssertEqual(store.collectStatus, "refreshing Inventory data")
        store.endCollect(for: "alpha")
    }

    /// A School collect writes no `overview`: its devices snapshot says whether it is stale.
    func testASchoolWorkspaceIsJudgedByItsDevicesSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("refresh-\(UUID().uuidString)", isDirectory: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let workspace = root.appendingPathComponent("district", isDirectory: true)
        let devices = workspace.appendingPathComponent("jamf-cli-data/school-devices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try "school_cli:\n  enabled: true\n".write(
            to: workspace.appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)
        var isStale = await RefreshCoordinator.dataIsStale(profile: "district", tier: .refresh)
        XCTAssertTrue(isStale, "no devices snapshot yet")
        try Data("[]".utf8).write(to: devices.appendingPathComponent(
            "school-devices_2026-11-01_090000.json"))
        isStale = await RefreshCoordinator.dataIsStale(profile: "district", tier: .refresh)
        XCTAssertFalse(isStale, "a fresh devices snapshot with no overview folder")
    }

    func testBackgroundRefreshHasItsOwnRunHistoryName() {
        XCTAssertEqual(
            RunHistoryService.humanName(from: WorkspaceStore.appRefreshRunLabel),
            "Background refresh")
    }
}
