import Foundation
import XCTest
@testable import JamfReports

final class CollectionTierTests: XCTestCase {

    // MARK: - Interval cadence

    func testHotInterval() {
        XCTAssertEqual(ScheduleTier.hot.intervalSeconds, 900)
    }

    func testWarmInterval() {
        XCTAssertEqual(ScheduleTier.warm.intervalSeconds, 14_400)
    }

    func testColdInterval() {
        XCTAssertEqual(ScheduleTier.cold.intervalSeconds, 86_400)
    }

    // MARK: - Display interval

    func testDisplayIntervalHot() {
        XCTAssertEqual(ScheduleTier.hot.displayInterval, "15 min")
    }

    func testDisplayIntervalWarm() {
        XCTAssertEqual(ScheduleTier.warm.displayInterval, "4 h")
    }

    func testDisplayIntervalCold() {
        XCTAssertEqual(ScheduleTier.cold.displayInterval, "24 h")
    }

    // MARK: - CaseIterable completeness

    func testAllCasesCount() {
        XCTAssertEqual(ScheduleTier.allCases.count, 3)
    }

    func testAllCasesContainExpected() {
        let cases = Set(ScheduleTier.allCases)
        XCTAssertTrue(cases.contains(.hot))
        XCTAssertTrue(cases.contains(.warm))
        XCTAssertTrue(cases.contains(.cold))
    }

    // MARK: - Tiers are strictly ordered by cost

    func testHotIntervalIsShorterThanWarm() {
        XCTAssertLessThan(ScheduleTier.hot.intervalSeconds,
                          ScheduleTier.warm.intervalSeconds)
    }

    func testWarmIntervalIsShorterThanCold() {
        XCTAssertLessThan(ScheduleTier.warm.intervalSeconds,
                          ScheduleTier.cold.intervalSeconds)
    }

    // MARK: - Staleness probe

    func testStalenessProbeKindHot() {
        XCTAssertEqual(ScheduleTier.hot.stalenessProbeKind, "overview")
    }

    func testStalenessProbeKindWarm() {
        XCTAssertEqual(ScheduleTier.warm.stalenessProbeKind, "policy-status")
    }

    func testStalenessProbeKindCold() {
        XCTAssertEqual(ScheduleTier.cold.stalenessProbeKind, "patch-device-failures")
    }
}
