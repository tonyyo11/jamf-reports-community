import XCTest
@testable import JamfReports

/// Tests for `CadenceResolver.cadence(forReport:)` (fixed cloud table)
/// and `CadenceResolver.isDue(lastRun:cadence:now:)`.
final class CadenceResolverTests: XCTestCase {

    // MARK: - cadence(forReport:)

    func testKnownRefreshKindReturnsRefreshInterval() {
        // overview is .refresh → 43_200s
        XCTAssertEqual(CadenceResolver.cadence(forReport: "overview"), .seconds(43_200))
    }

    func testKnownInventoryKindReturnsInventoryInterval() {
        // computers is .inventory → 172_800s
        XCTAssertEqual(CadenceResolver.cadence(forReport: "computers"), .seconds(172_800))
    }

    func testKnownScanKindReturnsScanInterval() {
        // patch-device-failures is .scan → 604_800s
        XCTAssertEqual(CadenceResolver.cadence(forReport: "patch-device-failures"), .seconds(604_800))
    }

    func testUnknownKindReturnsNever() {
        XCTAssertEqual(CadenceResolver.cadence(forReport: "made-up-report"), .never)
        XCTAssertEqual(CadenceResolver.cadence(forReport: ""), .never)
    }

    func testUpdateStatusIsInventoryTier() {
        // update-status was moved from scan to inventory (.never on on-prem is gone)
        XCTAssertEqual(CadenceResolver.cadence(forReport: "update-status"), .seconds(172_800))
    }

    func testCadenceLabelRendersHumanReadable() {
        XCTAssertEqual(Cadence.seconds(43_200).label, "43200s")
        XCTAssertEqual(Cadence.never.label, "never")
    }

    // MARK: - isDue

    func testNilLastRunIsAlwaysDue() {
        XCTAssertTrue(CadenceResolver.isDue(lastRun: nil, cadence: .seconds(86_400)))
    }

    func testNeverCadenceIsNeverDue() {
        XCTAssertFalse(CadenceResolver.isDue(lastRun: nil, cadence: .never))
    }

    func testRecentLastRunIsNotDue() {
        let now = Date()
        let lastRun = now.addingTimeInterval(-3_600) // 1h ago
        XCTAssertFalse(
            CadenceResolver.isDue(lastRun: lastRun, cadence: .seconds(43_200), now: now)
        )
    }

    func testStaleLastRunIsDue() {
        let now = Date()
        let lastRun = now.addingTimeInterval(-50_000) // beyond 43_200s
        XCTAssertTrue(
            CadenceResolver.isDue(lastRun: lastRun, cadence: .seconds(43_200), now: now)
        )
    }

    func testExactlyAtBoundaryIsDue() {
        let now = Date()
        let lastRun = now.addingTimeInterval(-43_200) // exactly at the boundary
        XCTAssertTrue(
            CadenceResolver.isDue(lastRun: lastRun, cadence: .seconds(43_200), now: now)
        )
    }
}
