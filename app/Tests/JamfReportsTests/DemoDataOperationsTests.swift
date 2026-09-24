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

    // MARK: - Policy & Profile Health

    /// jamf-cli reports warnings and info only; the tiles count the table.
    func testDemoPolicyFindingsMatchTheSummaryTiles() {
        let snapshot = DemoData.policyHealth
        let summary = snapshot.summary
        let bySeverity = snapshot.findingsBySeverity
        let checks = ["no_scope": "No targets in scope", "no_category": "Uncategorised"]

        XCTAssertEqual(summary?.configFindings, snapshot.findings.count)
        XCTAssertEqual(summary?.warnings, bySeverity["warning"])
        XCTAssertEqual(summary?.info, bySeverity["info"])
        XCTAssertEqual(Set(bySeverity.keys), ["warning", "info"])
        XCTAssertEqual((summary?.enabled ?? 0) + (summary?.disabled ?? 0), summary?.totalPolicies)
        XCTAssertEqual(Set(snapshot.findings.map(\.id)).count, snapshot.findings.count)
        for finding in snapshot.findings {
            XCTAssertEqual(checks[finding.check], finding.detail, finding.policy)
        }
    }

    /// Profile errors fall in the 30-day window ending on the reference date.
    func testDemoProfileFailuresFallInTheLookbackWindow() {
        let snapshot = DemoData.policyHealth

        XCTAssertEqual(snapshot.profileTotalErrors, snapshot.profiles.reduce(0) { $0 + $1.errors })
        XCTAssertEqual(snapshot.profilesWithFailures, snapshot.profiles.count)
        XCTAssertEqual(snapshot.profileLookbackDays, 30)
        for profile in snapshot.profiles {
            XCTAssertTrue(("2026-03-26"..."2026-04-25").contains(profile.lastError), profile.name)
        }
        XCTAssertEqual(snapshot.snapshotDate, DemoData.referenceDate)
    }

    // MARK: - Mobile Fleet

    /// Supervised devices are the ADE ones, each with its prestage; the
    /// personal devices are user-enrolled and never supervised.
    func testDemoMobileEnrollmentAgreesWithSupervision() {
        let snapshot = MobileFleetView.makeDemoSnapshot()
        let counts = Dictionary(
            snapshot.supervisionBreakdown.map { ($0.role, $0.count) },
            uniquingKeysWith: { first, _ in first })
        let methods = Dictionary(
            snapshot.enrollmentMethodDistribution.map { ($0.method, $0.count) },
            uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(snapshot.totalDevices, DemoData.mobileDeviceCount)
        XCTAssertEqual(snapshot.iPadCount + snapshot.iPhoneCount, DemoData.mobileDeviceCount)
        XCTAssertEqual(counts[.supervised], 20)
        XCTAssertEqual(counts[.unsupervised], 3)
        XCTAssertEqual(counts[.unmanaged], 2)
        XCTAssertEqual(methods["ADE / Institutional"], counts[.supervised])
        XCTAssertEqual(methods["User Enrollment"], 3)
        XCTAssertEqual(methods["Account-Driven User Enrollment"], 2)
        for device in snapshot.richDevices {
            let general = device.general
            let isADE = general?.deviceOwnershipType == "Institutional"
            XCTAssertEqual(general?.supervised, isADE, general?.displayName ?? "")
            XCTAssertEqual(general?.enrollmentMethodPrestage != nil, isADE,
                           general?.displayName ?? "")
        }
    }

    /// Every device was inventoried in the week before the demo's "now", and
    /// carries Meridian names, serials and addresses.
    func testDemoMobileDevicesAreMeridianDevicesFromTheDemoWeek() {
        let snapshot = MobileFleetView.makeDemoSnapshot()
        let parser = ISO8601DateFormatter()
        let weekBefore = DemoData.referenceDate.addingTimeInterval(-7 * 86_400)

        XCTAssertEqual(snapshot.snapshotDate, DemoData.referenceDate)
        for device in snapshot.richDevices {
            let name = device.general?.displayName ?? ""
            let inventoried = parser.date(from: device.general?.lastInventoryUpdateDate ?? "")
            XCTAssertNotNil(inventoried, name)
            XCTAssertLessThan(inventoried ?? .distantFuture, DemoData.referenceDate, name)
            XCTAssertGreaterThan(inventoried ?? .distantPast, weekBefore, name)
            XCTAssertEqual(device.general?.serialNumber?.count, 12, name)
            XCTAssertTrue(device.userAndLocation?.emailAddress?.hasSuffix("@meridian.health")
                          ?? false, name)
            if device.general?.supervised == true {
                XCTAssertTrue(name.hasPrefix("MERIDIAN-"), name)
            }
            XCTAssertFalse(name.localizedCaseInsensitiveContains("demo"), name)
        }
    }

    // MARK: - Groups & Searches

    /// Demo mode has group data of its own instead of reading a workspace.
    func testDemoGroupInventoryIsDetectedWithItsCounts() {
        let snapshot = DemoData.groupInventory

        XCTAssertTrue(snapshot.isDetected)
        XCTAssertEqual(snapshot.classicComputerGroupCount, 14)
        XCTAssertEqual(snapshot.classicComputerSmartGroupCount, 9)
        XCTAssertEqual(snapshot.classicComputerStaticGroupCount, 5)
        XCTAssertEqual(snapshot.classicMobileGroupCount, 4)
        XCTAssertEqual(snapshot.advancedSearchCount, 2)
        for groups in [snapshot.classicComputerGroups, snapshot.classicMobileGroups] {
            XCTAssertEqual(Set(groups.compactMap(\.id)).count, groups.count)
            XCTAssertTrue(groups.allSatisfy { !($0.name ?? "").isEmpty })
        }
        XCTAssertTrue(snapshot.advancedMobileSearches.allSatisfy { !($0.criteria ?? []).isEmpty })
        XCTAssertEqual(snapshot.snapshotDate, DemoData.referenceDate)
    }
}
