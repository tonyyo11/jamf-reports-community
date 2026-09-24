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

    // MARK: - OS Updates

    private func updateCount(
        _ label: String, in slices: [UpdateStatusService.Snapshot.Slice]
    ) -> Int {
        slices.first { $0.label == label }?.count ?? 0
    }

    /// Every Mac has a status; the completed ones are the Macs on a current
    /// release, and ERROR is the three error devices.
    func testDemoUpdateStatusesCoverTheFleet() {
        let snapshot = DemoData.updateStatus
        let onCurrent = DemoData.osDistribution.filter(\.current).reduce(0) { $0 + $1.count }

        XCTAssertEqual(snapshot.total, DemoData.totalDevices)
        XCTAssertEqual(snapshot.statusBreakdown.reduce(0) { $0 + $1.count }, snapshot.total)
        XCTAssertEqual(updateCount("COMPLETED", in: snapshot.statusBreakdown), onCurrent)
        XCTAssertEqual(updateCount("ERROR", in: snapshot.statusBreakdown), 3)
        XCTAssertEqual(snapshot.errorDevices.count, 3)
        XCTAssertTrue(snapshot.errorDevices.allSatisfy { $0.status == "ERROR" })
    }

    /// The plan-state donut, the Failing Plans tile and the failed-plans
    /// table count the same plans.
    func testDemoUpdatePlansAgreeWithTheFailedPlansTable() {
        let snapshot = DemoData.updateStatus
        let states = snapshot.planStateBreakdown

        XCTAssertEqual(states.reduce(0) { $0 + $1.count }, snapshot.planTotal)
        XCTAssertEqual(snapshot.plansFailedFromStates, 6)
        for state in ["PlanFailed", "PlanException", "PlanCanceled"] {
            XCTAssertEqual(snapshot.failedPlans.filter { $0.state == state }.count,
                           updateCount(state, in: states), state)
        }
        XCTAssertEqual(snapshot.failedPlans.count, 7)
    }

    /// Update rows name Meridian Macs on the demo's older releases, dated
    /// Apr 21–25; a Mac the Devices screen lists keeps its serial, OS and user.
    func testDemoUpdateRowsDescribeTheDemoMacs() {
        let snapshot = DemoData.updateStatus
        let behind = Set(DemoData.osDistribution.filter { !$0.current }.compactMap { dist in
            dist.version.split(separator: " ").first { $0.first?.isNumber == true }
                .map(String.init)
        })
        let inventory = Dictionary(
            DemoData.deviceInventory.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(behind, ["14.7.4", "13.7.6", "12.7.6"])
        for device in snapshot.errorDevices {
            assertDemoMac(device.name, device.serial, device.osVersion, device.username,
                          dated: device.updated, behind: behind, inventory: inventory)
        }
        for plan in snapshot.failedPlans {
            assertDemoMac(plan.name, plan.serial, plan.osVersion, plan.username,
                          dated: plan.lastEvent, behind: behind, inventory: inventory)
        }
        XCTAssertTrue(snapshot.errorDevices.allSatisfy { $0.productKey.hasSuffix("15.4") })
        XCTAssertTrue(snapshot.failedPlans.allSatisfy { $0.version == "15.4" })
        XCTAssertEqual(snapshot.snapshotDate, DemoData.referenceDate)
    }

    private func assertDemoMac(
        _ name: String, _ serial: String, _ os: String, _ user: String, dated date: String,
        behind: Set<String>, inventory: [String: DeviceInventoryRecord]
    ) {
        XCTAssertTrue(name.hasPrefix("MERIDIAN-"), name)
        XCTAssertEqual(serial.count, 12, name)
        XCTAssertTrue(behind.contains(os), name)
        XCTAssertTrue(("2026-04-21"..."2026-04-25").contains(String(date.prefix(10))), name)
        guard let device = inventory[name] else { return }
        XCTAssertEqual(serial, device.serial, name)
        XCTAssertEqual(os, device.osVersion, name)
        XCTAssertEqual(user, device.user, name)
    }
}
