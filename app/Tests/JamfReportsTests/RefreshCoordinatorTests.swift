import Foundation
import XCTest
@testable import JamfReports

final class RefreshCoordinatorTests: XCTestCase {

    // MARK: - RefreshPolicy staleness threshold

    func testDefaultPolicyHotThreshold() {
        let policy = RefreshPolicy.default
        XCTAssertEqual(
            policy.stalenessThreshold(for: .hot),
            TimeInterval(ScheduleTier.hot.intervalSeconds)
        )
    }

    func testDefaultPolicyWarmThreshold() {
        let policy = RefreshPolicy.default
        XCTAssertEqual(
            policy.stalenessThreshold(for: .warm),
            TimeInterval(ScheduleTier.warm.intervalSeconds)
        )
    }

    func testDefaultPolicyColdThreshold() {
        let policy = RefreshPolicy.default
        XCTAssertEqual(
            policy.stalenessThreshold(for: .cold),
            TimeInterval(ScheduleTier.cold.intervalSeconds)
        )
    }

    // MARK: - Backoff curve

    func testNoBackoffOnZeroFailures() {
        let policy = RefreshPolicy.default
        let interval = policy.backoffInterval(tier: .hot, failureCount: 0)
        XCTAssertEqual(interval, TimeInterval(ScheduleTier.hot.intervalSeconds))
    }

    func testBackoffDoublesOnFirstFailure() {
        let policy = RefreshPolicy.default
        let base = TimeInterval(ScheduleTier.hot.intervalSeconds)
        XCTAssertEqual(policy.backoffInterval(tier: .hot, failureCount: 1), base * 2.0)
    }

    func testBackoffQuadruplesOnSecondFailure() {
        let policy = RefreshPolicy.default
        let base = TimeInterval(ScheduleTier.hot.intervalSeconds)
        XCTAssertEqual(policy.backoffInterval(tier: .hot, failureCount: 2), base * 4.0)
    }

    func testBackoffCappedAtMaxMultiplier() {
        let policy = RefreshPolicy.default
        let base = TimeInterval(ScheduleTier.cold.intervalSeconds)
        // 2^10 = 1024 >> maxBackoffMultiplier (8)
        let capped = policy.backoffInterval(tier: .cold, failureCount: 10)
        XCTAssertEqual(capped, base * policy.maxBackoffMultiplier)
    }

    func testBackoffCapIsEight() {
        XCTAssertEqual(RefreshPolicy.default.maxBackoffMultiplier, 8.0)
    }

    // MARK: - shouldBackOff

    func testNoBackoffBelowMaxFailures() {
        let policy = RefreshPolicy.default
        // maxFailures for .hot is 3; with 2 failures no backoff yet.
        let shouldSkip = policy.shouldBackOff(
            tier: .hot,
            failureCount: 2,
            lastAttempt: Date().addingTimeInterval(-1),
            now: Date()
        )
        XCTAssertFalse(shouldSkip)
    }

    func testBackoffActiveImmediatelyAfterMaxFailures() {
        let policy = RefreshPolicy.default
        // maxFailures for .hot is 3; after exactly 3 failures the next attempt
        // triggers backoff if the elapsed time is less than the backoff interval.
        let shouldSkip = policy.shouldBackOff(
            tier: .hot,
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
        // After 3 failures, backoff interval = 900 * 2^3 = 7200 s.
        // If last attempt was 7201 s ago, backoff has expired.
        let lastAttempt = Date().addingTimeInterval(-7_201)
        let shouldSkip = policy.shouldBackOff(
            tier: .hot,
            failureCount: 3,
            lastAttempt: lastAttempt,
            now: Date()
        )
        XCTAssertFalse(shouldSkip, "Backoff should have expired after 7201 s")
    }

    // MARK: - RefreshPolicy custom init

    func testCustomPolicyRespectsThresholds() {
        let policy = RefreshPolicy(
            stalenessThresholds: [.hot: 60],
            maxConsecutiveFailures: [.hot: 1],
            backoffBase: 3.0,
            maxBackoffMultiplier: 4.0
        )
        XCTAssertEqual(policy.stalenessThreshold(for: .hot), 60)
        XCTAssertEqual(policy.maxFailures(for: .hot), 1)
        // Backoff multiplies the tier's natural cadence interval (not staleness threshold).
        XCTAssertEqual(
            policy.backoffInterval(tier: .hot, failureCount: 1),
            TimeInterval(ScheduleTier.hot.intervalSeconds) * 3.0
        )
    }

    func testFallbackThresholdUsedWhenTierNotInMap() {
        let policy = RefreshPolicy(
            stalenessThresholds: [:],
            maxConsecutiveFailures: [:],
            backoffBase: 2.0,
            maxBackoffMultiplier: 8.0
        )
        // Falls back to tier's own intervalSeconds.
        XCTAssertEqual(
            policy.stalenessThreshold(for: .warm),
            TimeInterval(ScheduleTier.warm.intervalSeconds)
        )
        XCTAssertEqual(policy.maxFailures(for: .warm), 2)
    }

    // MARK: - Label format for tiered agents

    func testTieredLabelFormat() {
        let label = TieredLaunchAgentWriter.label(for: "acme", tier: .hot)
        XCTAssertEqual(label, "com.github.tonyyo11.jamf-reports-community.acme.hot")
    }

    func testTieredLabelWarmFormat() {
        let label = TieredLaunchAgentWriter.label(for: "cbp-prod", tier: .warm)
        XCTAssertEqual(label, "com.github.tonyyo11.jamf-reports-community.cbp-prod.warm")
    }

    func testTieredLabelColdFormat() {
        let label = TieredLaunchAgentWriter.label(for: "test01", tier: .cold)
        XCTAssertEqual(label, "com.github.tonyyo11.jamf-reports-community.test01.cold")
    }

    func testTieredLabelPrefixMatchesLaunchAgentWriter() {
        for tier in ScheduleTier.allCases {
            let label = TieredLaunchAgentWriter.label(for: "dummy", tier: tier)
            XCTAssertTrue(
                label.hasPrefix(LaunchAgentWriter.labelPrefix + "."),
                "Tier label must share the same prefix: \(label)"
            )
        }
    }
}
