import Foundation
import XCTest
@testable import JamfReports

/// The demo screens past the Overview must agree with the demo fleet they
/// describe: the same 524 Macs, the same Meridian devices and schedules, and
/// nothing dated after `DemoData.referenceDate`.
@MainActor
final class DemoDataOperationsTests: XCTestCase {

    // MARK: - Patch Compliance

    /// The Patch trend ends at 87.5%. Patch Compliance weights by device and a
    /// daily summary averages the titles' rates; both must land there.
    func testDemoPatchComplianceEndsOnThePatchTrend() {
        let snapshot = DemoData.patchStatus
        let trendEnd = DemoData.trends[.patch]?.last ?? 0
        let rates = snapshot.titles.map { PatchStatusService.parseCompliancePct($0.compliancePct) }
        let meanRate = rates.reduce(0, +) / Double(max(rates.count, 1))

        XCTAssertEqual(trendEnd, 87.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.fleetCompliancePct, trendEnd, accuracy: 0.001)
        XCTAssertEqual(meanRate, trendEnd, accuracy: 0.001)
    }

    /// Each title's label is its own on-latest share, and the Devices screen's
    /// titles keep their counts.
    func testDemoPatchTitlesKeepTheDevicesScreenCounts() {
        let rows = Dictionary(
            DemoData.patchStatus.titles.map { ($0.title, $0) },
            uniquingKeysWith: { first, _ in first })

        for summary in DemoData.patchTitleSummary {
            let row = rows[summary.title]
            XCTAssertEqual(row?.onLatest, summary.compliant, summary.title)
            XCTAssertEqual(row?.total, summary.total, summary.title)
        }
        for row in DemoData.patchStatus.titles {
            let share = Double(row.onLatest) / Double(row.total) * 100
            XCTAssertEqual(String(format: "%.1f%%", share), row.compliancePct, row.title)
            XCTAssertEqual(row.onLatest + row.onOther, row.total, row.title)
            XCTAssertLessThanOrEqual(row.total, DemoData.totalDevices, row.title)
        }
    }

    /// The failures are the Devices screen's: seven on four Macs, Apr 21–25,
    /// each against a title the table lists.
    func testDemoPatchFailuresComeFromTheDemoDevices() {
        let snapshot = DemoData.patchStatus
        let titles = Set(snapshot.titles.map(\.title))
        let inventoryFailures = DemoData.deviceInventory.flatMap(\.patchFailures)

        XCTAssertEqual(snapshot.failures.count, inventoryFailures.count)
        XCTAssertEqual(snapshot.failures.count, 7)
        XCTAssertEqual(snapshot.devicesWithFailures, 4)
        XCTAssertEqual(Set(snapshot.failures.map(\.id)).count, snapshot.failures.count)
        for failure in snapshot.failures {
            XCTAssertTrue(titles.contains(failure.policy), failure.policy)
            XCTAssertTrue(failure.device.hasPrefix("MERIDIAN-"), failure.device)
            XCTAssertTrue(("2026-04-21"..."2026-04-25").contains(failure.statusDate),
                          failure.statusDate)
        }
    }

    /// Released and Days Behind read from the demo's own "now", never today.
    func testDemoPatchReleaseDatesPrecedeTheReferenceDate() {
        XCTAssertEqual(DemoData.patchStatus.snapshotDate, DemoData.referenceDate)
        for row in DemoData.patchStatus.titles {
            let released = DemoData.patchReleaseLookup[row.id] ?? ""
            let parsed = SOFAFeedService.parseSOFADate(released)
            XCTAssertNotNil(parsed, row.title)
            XCTAssertLessThan(parsed ?? .distantFuture, DemoData.referenceDate, row.title)
            let days = PatchReleaseDateService.daysBehind(
                releaseDate: released, referenceDate: DemoData.referenceDate)
            XCTAssertNotNil(days, row.title)
            XCTAssertLessThan(days ?? .max, 60, row.title)
        }
    }
}
