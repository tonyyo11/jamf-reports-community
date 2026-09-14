import XCTest
@testable import JamfReports

/// The automatic collects — hourly self-remediation and catch-up-on-wake — must
/// never start while another collect is running: not one this process started
/// (Initialize on a 662-Mac tenant was still collecting when remediation began
/// a second fan-out) and not a `--tick` process holding the tick lock. Standing
/// down must also leave the hour/day marker unclaimed, so the next pass retries
/// instead of waiting out the window.
@MainActor
final class GroupCAutomaticCollectOverlapTests: XCTestCase {

    private let profile = "alpha"

    /// A throwaway workspaces root (which in DEBUG also relocates Application
    /// Support under it), one initialized workspace, and a store pointed at it.
    private func makeStore() throws -> (store: WorkspaceStore, workspace: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("jrc-overlap-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        // discoverLocal only counts a directory that holds a config.yaml.
        try "".write(to: workspace.appendingPathComponent("config.yaml"),
                     atomically: true, encoding: .utf8)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let store = WorkspaceStore(demoMode: false, tickerRegistrar: StubTickerRegistrar())
        store.profile = profile
        store.tickLockHeldElsewhere = { false }
        return (store, workspace)
    }

    private var remediationMarker: DayMarker { DayMarker(name: "freshness-remediation") }

    private func staleIssue() -> DataFreshnessIssue {
        DataFreshnessIssue(
            snapshotKind: "security", tier: .refresh, kind: .stale,
            lastSuccess: Date(timeIntervalSince1970: 1_700_000_000),
            consecutiveFailures: 0, lastFailure: nil
        )
    }

    // MARK: - Self-remediation

    func testRemediationStandsDownWhileACollectIsInFlightAndKeepsTheHour() async throws {
        let (store, workspace) = try makeStore()
        AutomationHealthModel.shared.freshnessIssues = [staleIssue()]
        defer { AutomationHealthModel.shared.freshnessIssues = [] }
        let spy = CollectSpy()

        store.beginCollect(for: profile)
        let deferred = await store.remediateStaleDataIfNeeded(collect: spy.remediation)
        XCTAssertFalse(deferred)
        XCTAssertTrue(spy.profiles.isEmpty, "no collect while one is in flight")
        XCTAssertNil(remediationMarker.lastStampedDay(in: workspace),
                     "standing down must not claim the hour")

        store.endCollect(for: profile)
        let attempted = await store.remediateStaleDataIfNeeded(collect: spy.remediation)
        XCTAssertTrue(attempted, "the same hour is still available once the collect finishes")
        XCTAssertEqual(spy.profiles, [profile])
        XCTAssertNotNil(remediationMarker.lastStampedDay(in: workspace))
    }

    func testRemediationStandsDownWhileTheTickHoldsItsLock() async throws {
        let (store, workspace) = try makeStore()
        AutomationHealthModel.shared.freshnessIssues = [staleIssue()]
        defer { AutomationHealthModel.shared.freshnessIssues = [] }
        let spy = CollectSpy()

        store.tickLockHeldElsewhere = { true }
        let deferred = await store.remediateStaleDataIfNeeded(collect: spy.remediation)
        XCTAssertFalse(deferred)
        XCTAssertTrue(spy.profiles.isEmpty)
        XCTAssertNil(remediationMarker.lastStampedDay(in: workspace))

        store.tickLockHeldElsewhere = { false }
        let attempted = await store.remediateStaleDataIfNeeded(collect: spy.remediation)
        XCTAssertTrue(attempted)
        XCTAssertEqual(spy.profiles, [profile])
    }

    /// A generate run holds the older run flag rather than the collect count;
    /// it may collect first, so it counts as in flight too.
    func testAGenerateRunInProgressAlsoDefersRemediation() async throws {
        let (store, workspace) = try makeStore()
        AutomationHealthModel.shared.freshnessIssues = [staleIssue()]
        defer { AutomationHealthModel.shared.freshnessIssues = [] }
        let spy = CollectSpy()

        XCTAssertTrue(store.setRunInProgress(for: profile))
        defer { store.clearRunInProgress(for: profile) }
        let deferred = await store.remediateStaleDataIfNeeded(collect: spy.remediation)
        XCTAssertFalse(deferred)
        XCTAssertTrue(spy.profiles.isEmpty)
        XCTAssertNil(remediationMarker.lastStampedDay(in: workspace))
    }

    // MARK: - Catch-up-on-wake

    /// Each test uses its own far-future day: the day claim is a process-wide
    /// static, and a real "today" would collide with other tests in the run.
    private func day(_ dayOfMonth: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2100
        comps.month = 1
        comps.day = dayOfMonth
        comps.hour = 12
        return Calendar.current.date(from: comps) ?? Date()
    }

    private var managedFreshness: AutomationPolicy {
        var policy = AutomationPolicy()
        policy.isManaged = true
        policy.freshnessEnabled = true
        return policy
    }

    func testCatchUpStandsDownWhileACollectIsInFlightAndKeepsTheDay() async throws {
        let (store, _) = try makeStore()
        let spy = CollectSpy()
        let now = day(1)

        store.beginCollect(for: profile)
        let deferred = await store.catchUpCollectIfNeeded(
            policy: managedFreshness, now: now, collect: spy.catchUp)
        XCTAssertFalse(deferred)
        XCTAssertTrue(spy.profiles.isEmpty, "no collect while one is in flight")

        store.endCollect(for: profile)
        let attempted = await store.catchUpCollectIfNeeded(
            policy: managedFreshness, now: now, collect: spy.catchUp)
        XCTAssertTrue(attempted, "standing down must not have claimed the day")
        XCTAssertTrue(spy.profiles.contains(profile))

        let repeated = await store.catchUpCollectIfNeeded(
            policy: managedFreshness, now: now, collect: spy.catchUp)
        XCTAssertFalse(repeated, "an attempted catch-up claims its day")
    }

    func testCatchUpStandsDownWhileTheTickHoldsItsLock() async throws {
        let (store, _) = try makeStore()
        let spy = CollectSpy()
        let now = day(2)

        store.tickLockHeldElsewhere = { true }
        let deferred = await store.catchUpCollectIfNeeded(
            policy: managedFreshness, now: now, collect: spy.catchUp)
        XCTAssertFalse(deferred)
        XCTAssertTrue(spy.profiles.isEmpty)

        store.tickLockHeldElsewhere = { false }
        let attempted = await store.catchUpCollectIfNeeded(
            policy: managedFreshness, now: now, collect: spy.catchUp)
        XCTAssertTrue(attempted)
        XCTAssertTrue(spy.profiles.contains(profile))
    }

    // MARK: - In-flight bookkeeping

    /// Manual actions overlap (Collect now during Initialize); the mark must
    /// outlive the first one to finish, and never go negative.
    func testInFlightMarkIsCountedNotFlagged() throws {
        let (store, _) = try makeStore()
        store.beginCollect(for: profile)
        store.beginCollect(for: profile)
        store.endCollect(for: profile)
        XCTAssertTrue(store.isCollectInFlight(for: profile))
        store.endCollect(for: profile)
        XCTAssertFalse(store.isCollectInFlight(for: profile))
        store.endCollect(for: profile)
        XCTAssertFalse(store.isCollectInFlight(for: profile))
        store.beginCollect(for: profile)
        XCTAssertTrue(store.isCollectInFlight(for: profile), "an extra end must not offset a begin")
        store.endCollect(for: profile)
    }
}

/// Records which profiles an automatic collect was asked for. Adapts to both
/// collector shapes so one spy serves remediation and catch-up.
private final class CollectSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _profiles: [String] = []
    var profiles: [String] { lock.withLock { _profiles } }

    var remediation: WorkspaceStore.RemediationCollector {
        { profile, _, _ in self.record(profile) }
    }

    var catchUp: WorkspaceStore.CatchUpCollector {
        { profile, _ in self.record(profile) }
    }

    private func record(_ profile: String) {
        lock.withLock { _profiles.append(profile) }
    }
}
