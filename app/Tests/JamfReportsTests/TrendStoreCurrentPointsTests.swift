import XCTest
@testable import JamfReports

/// A tile that states today's figure must not borrow an older day's value.
@MainActor
final class TrendStoreCurrentPointsTests: XCTestCase {
    private func day(_ date: String, fileVault: Double?) -> DailySummary {
        DailySummary(
            date: date, totalDevices: 10, fileVaultPct: fileVault, compliancePct: nil,
            staleCount: nil, osCurrentPct: 80, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli")
    }

    func testNewestSummaryWithoutTheFigureGivesNoCurrentPoints() {
        let store = TrendStore(summaries: [
            day("2026-11-10", fileVault: 0), day("2026-11-11", fileVault: 0),
            day("2026-11-12", fileVault: nil),
        ])
        XCTAssertEqual(store.points(metric: .fileVault).count, 2, "The series still skips the gap")
        XCTAssertTrue(store.currentPoints(metric: .fileVault).isEmpty)
        XCTAssertEqual(store.currentPoints(metric: .osCurrent).count, 3)
    }

    func testNewestSummaryWithTheFigureKeepsTheSeries() {
        let store = TrendStore(summaries: [
            day("2026-11-10", fileVault: nil), day("2026-11-11", fileVault: 90),
        ])
        XCTAssertEqual(store.currentPoints(metric: .fileVault).map(\.value), [90])
    }
}
