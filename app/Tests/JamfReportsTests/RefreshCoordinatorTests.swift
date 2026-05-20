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
            policy.stalenessThreshold(for: .refresh),
            TimeInterval(CollectionTier.refresh.intervalSeconds) * 1.5
        )
    }

    func testUnpopulatedTierFallsBackToInterval() {
        let policy = RefreshPolicy.default
        // .inventory/.scan are not in the default map — the coordinator never
        // drives them. stalenessThreshold falls back to the tier's own
        // intervalSeconds rather than carrying a ghost map entry.
        XCTAssertEqual(
            policy.stalenessThreshold(for: .inventory),
            TimeInterval(CollectionTier.inventory.intervalSeconds)
        )
        XCTAssertEqual(
            policy.stalenessThreshold(for: .scan),
            TimeInterval(CollectionTier.scan.intervalSeconds)
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
            stalenessThresholds: [.refresh: 60],
            maxConsecutiveFailures: [.refresh: 1],
            backoffBase: 3.0,
            maxBackoffMultiplier: 4.0
        )
        XCTAssertEqual(policy.stalenessThreshold(for: .refresh), 60)
        XCTAssertEqual(policy.maxFailures(for: .refresh), 1)
        // Backoff multiplies the tier's natural cadence interval (not staleness threshold).
        XCTAssertEqual(
            policy.backoffInterval(tier: .refresh, failureCount: 1),
            TimeInterval(CollectionTier.refresh.intervalSeconds) * 3.0
        )
    }

    func testFallbackThresholdUsedWhenTierNotInMap() {
        let policy = RefreshPolicy(
            stalenessThresholds: [:],
            maxConsecutiveFailures: [:],
            backoffBase: 2.0,
            maxBackoffMultiplier: 8.0
        )
        // Falls back to the tier's own intervalSeconds.
        XCTAssertEqual(
            policy.stalenessThreshold(for: .inventory),
            TimeInterval(CollectionTier.inventory.intervalSeconds)
        )
        XCTAssertEqual(policy.maxFailures(for: .inventory), 2)
    }

    // MARK: - CollectionTier interval reference

    func testRefreshIntervalIsOnPremDailyCadence() {
        // intervalSeconds is the on-prem default cadence — the fixed
        // denominator for backoff math. Pinned so a preset-table change
        // doesn't silently shift backoff timing.
        XCTAssertEqual(CollectionTier.refresh.intervalSeconds, 86_400)
        XCTAssertEqual(CollectionTier.inventory.intervalSeconds, 604_800)
        XCTAssertEqual(CollectionTier.scan.intervalSeconds, 604_800)
    }

    func testStalenessProbeKindsAreRealCollectKinds() {
        // The probe kind must be a directory ReportEngine.collect writes,
        // or the mtime probe finds nothing and reports everything stale.
        for tier in CollectionTier.allCases {
            XCTAssertTrue(
                ReportEngine.knownCollectKinds.contains(tier.stalenessProbeKind),
                "\(tier.rawValue) probe kind '\(tier.stalenessProbeKind)' must be a real collect kind"
            )
        }
    }

    // MARK: - Coordinator entry points (PR-24 — now wired)
    //
    // PR-24 connects observeProfileSwitch (profile switch) and
    // refreshIfStale (foreground/launch) to real callers, so these public
    // entry points are now load-bearing. The guard paths below resolve
    // synchronously — no waiting on the 500 ms debounce.

    @MainActor
    func testRefreshIfStaleNoOpsForNonRefreshTier() {
        let coordinator = RefreshCoordinator(bridge: CLIBridge())
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
        let coordinator = RefreshCoordinator(bridge: CLIBridge())
        // Spaces + punctuation fail ProfileService.isValid — the guard must
        // catch it before any task is queued.
        coordinator.refreshIfStale(profile: "Bad Profile!", tier: .refresh)
        XCTAssertFalse(coordinator.isRefreshing(profile: "Bad Profile!", tier: .refresh))
    }

    @MainActor
    func testObserveProfileSwitchCoalescesRapidCalls() {
        // Cycling the sidebar chip fires observeProfileSwitch repeatedly.
        // The debounce means none of them have started a refresh yet — the
        // coordinator must stay quiet (and not crash) through the burst.
        let coordinator = RefreshCoordinator(bridge: CLIBridge())
        coordinator.observeProfileSwitch("alpha")
        coordinator.observeProfileSwitch("beta")
        coordinator.observeProfileSwitch("gamma")
        XCTAssertEqual(coordinator.failureCount(profile: "gamma", tier: .refresh), 0)
        XCTAssertFalse(coordinator.isRefreshing(profile: "gamma", tier: .refresh))
    }
}
