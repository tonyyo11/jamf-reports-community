import XCTest
@testable import JamfReports

/// Demo screens must agree with the shared demo facts (`DemoData.swift`,
/// `DemoData+Config.swift`): the 524-Mac fleet, its security controls, macOS
/// versions and compliance bands. A demo number that contradicts another screen
/// reads as a bug in the product, not in the demo.
@MainActor
final class DemoDataSecurityTests: XCTestCase {

    // MARK: - Fleet

    func testFleetIs524DistinctMeridianMacs() {
        let fleet = DemoData.fleetMacs
        XCTAssertEqual(fleet.count, DemoData.totalDevices)
        XCTAssertEqual(Set(fleet.map(\.name)).count, fleet.count)
        XCTAssertEqual(Set(fleet.map(\.serial)).count, fleet.count)
        XCTAssertEqual(Set(fleet.map(\.user)).count, fleet.count)
        XCTAssertEqual(Set(fleet.map(\.jamfID)).count, fleet.count)
        let departments = Set(DemoData.deviceInventory.map(\.department))
        for mac in fleet {
            XCTAssertTrue(mac.name.hasPrefix("MERIDIAN-"), mac.name)
            XCTAssertTrue(mac.email.hasSuffix("@meridian.health"), mac.email)
            XCTAssertEqual(mac.serial.count, 12, mac.serial)
            XCTAssertTrue(departments.contains(mac.department), mac.department)
        }
    }

    func testFleetStartsWithTheInventoryMacs() {
        let inventory = DemoData.deviceInventory
        let head = DemoData.fleetMacs.prefix(inventory.count)
        XCTAssertEqual(head.map(\.name), inventory.map(\.name))
        XCTAssertEqual(head.map(\.serial), inventory.map(\.serial))
        XCTAssertEqual(head.map(\.email), inventory.map(\.email))
    }

    func testFleetRunsTheOverviewsMacOSVersions() {
        var counts: [String: Int] = [:]
        for mac in DemoData.fleetMacs { counts[mac.osVersion, default: 0] += 1 }
        for entry in DemoData.osDistribution {
            XCTAssertEqual(counts[DemoData.osVersionNumber(entry.version)], entry.count,
                           entry.version)
        }
    }

    // MARK: - Offline Outreach

    /// 26 stale Macs (the Overview's Stale card) split 13 / 9 / 4, and the 498
    /// active Macs `activeDevicesTrend` ends on.
    func testOutreachTiersSplitTheFleet() {
        let snapshot = StaleDeviceService.snapshot(from: DemoData.outreachRecords, staleDays: 30)
        XCTAssertEqual(snapshot.totalDevices, DemoData.totalDevices)
        XCTAssertEqual(snapshot.tierCounts[.recent], 498)
        XCTAssertEqual(snapshot.tierCounts[.offline], 13)
        XCTAssertEqual(snapshot.tierCounts[.inactive], 9)
        XCTAssertEqual(snapshot.tierCounts[.dormant], 4)
        XCTAssertEqual(Double(snapshot.tierCounts[.recent] ?? 0),
                       DemoData.activeDevicesTrend.last)
    }

    func testOutreachContactDatesAreOnOrBeforeTheReferenceDate() {
        let parser = ISO8601DateFormatter()
        for record in DemoData.outreachRecords {
            let date = parser.date(from: record.lastContact)
            XCTAssertNotNil(date, record.lastContact)
            XCTAssertLessThanOrEqual(date ?? .distantFuture, DemoData.referenceDate)
        }
    }

    func testOutreachRecordsAreDeterministic() {
        let names = DemoData.outreachRecords.map(\.name)
        XCTAssertEqual(names, DemoData.fleetMacs.map(\.name))
        XCTAssertEqual(DemoData.fleetMacs[8].name, "MERIDIAN-OA-MBP")
        XCTAssertEqual(DemoData.fleetMacs[8].user, "o.adeyemi")
    }

    // MARK: - Security Posture

    func testSecurityPostureCountsTheFleetsControls() {
        let snapshot = DemoData.securityPostureSnapshot
        let controls = DemoData.securityControls
        XCTAssertEqual(snapshot.totalDevices, DemoData.totalDevices)
        XCTAssertEqual(snapshot.fileVaultEncrypted, controls.fileVault)
        XCTAssertEqual(snapshot.sipEnabled, controls.sip)
        XCTAssertEqual(snapshot.firewallEnabled, controls.firewall)
        XCTAssertEqual(snapshot.gatekeeperEnabled, controls.gatekeeper)
        XCTAssertLessThanOrEqual(snapshot.snapshotDate ?? .distantFuture, DemoData.referenceDate)
    }

    func testSecurityPostureDonutIsTheOverviewDistribution() {
        let versions = DemoData.securityPostureSnapshot.osVersions
        XCTAssertEqual(versions.map(\.osVersion), ["15.4", "15.3.2", "14.7.4", "13.7.6", "12.7.6"])
        XCTAssertEqual(versions.map(\.count), DemoData.osDistribution.map(\.count))
        XCTAssertEqual(versions.reduce(0) { $0 + $1.count }, DemoData.totalDevices)
    }

    /// P0 is the FileVault, SIP and Firewall gaps, P1 the Gatekeeper gaps.
    func testSecurityPostureActionItems() {
        let controls = DemoData.securityControls
        let p0 = (controls.total - controls.fileVault) + (controls.total - controls.sip)
            + (controls.total - controls.firewall)
        XCTAssertEqual(p0, 53)
        XCTAssertEqual(controls.total - controls.gatekeeper, 12)
    }

    /// The ring's value with the default weights. The Overview's Security Score
    /// card ends on `DemoData.trends[.securityScore]`, which should match it.
    func testSecurityScoreRingWithDefaultWeights() {
        let score = SecurityScoreCalculator.score(
            input: SecurityScoreCalculator.input(from: DemoData.securityPostureSnapshot),
            weights: .defaultWeights)
        XCTAssertEqual(score.value, 96.6, accuracy: 0.001)
        XCTAssertEqual(score.grade, .aPlus)
        XCTAssertEqual(score.available, [.fileVault, .sip, .firewall])
    }

    // MARK: - Compliance Posture

    /// The first donut is the configured benchmark, banded as the Overview's
    /// compliance bands with the 22 Macs that report no count as No Data.
    func testConfiguredBaselineIsTheOverviewsBands() throws {
        let baseline = try XCTUnwrap(DemoData.complianceBaselineResults.first)
        XCTAssertEqual(baseline.name, DemoData.complianceBaseline)
        XCTAssertEqual(baseline.totalDevices, DemoData.totalDevices)
        XCTAssertEqual(baseline.noDataCount, 22)
        XCTAssertEqual(baseline.devicesWithData, 502)
        XCTAssertEqual(Array(baseline.bands.prefix(5).map(\.count)),
                       DemoData.complianceBands.map(\.count))
        XCTAssertEqual(baseline.bands.last?.count, 22, "No Data is the last band")
        XCTAssertEqual(String(format: "%.1f", baseline.compliancePct ?? 0), "42.4")
    }

    func testSTIGBaselineCoversTheWholeFleet() throws {
        let stig = try XCTUnwrap(DemoData.complianceBaselineResults.last)
        XCTAssertEqual(stig.name, "DISA STIG")
        XCTAssertEqual(stig.totalDevices, DemoData.totalDevices)
        XCTAssertEqual(stig.noDataCount, 0)
        XCTAssertEqual(stig.bands.map(\.count), [304, 96, 64, 32, 28, 0])
        XCTAssertEqual(String(format: "%.1f", stig.compliancePct ?? 0), "58.0")
    }

    func testControlGapsAreTheComplementsOfTheSecurityControls() {
        let gaps = DemoData.compliancePostureSnapshot.controlGaps
        XCTAssertEqual(gaps.map(\.control), ["Firewall", "Gatekeeper", "FileVault", "SIP"])
        XCTAssertEqual(gaps.map(\.failingDevices), [42, 12, 11, 0])
        XCTAssertTrue(gaps.allSatisfy { $0.totalDevices == DemoData.totalDevices })
    }

    /// Each macOS major version holds the Macs the Overview's distribution gives
    /// it, and the per-Mac gaps add up to the control bars.
    func testPerOSBreakdownMatchesTheDistributionAndTheGaps() {
        let snapshot = DemoData.compliancePostureSnapshot
        var expected: [Int: Int] = [:]
        for entry in DemoData.osDistribution {
            let version = DemoData.osVersionNumber(entry.version)
            let major = ComplianceBandingService.parseOSMajor(version) ?? 0
            expected[major, default: 0] += entry.count
        }
        let perOS = Dictionary(uniqueKeysWithValues: snapshot.perOSMajor.map { row in
            (row.osMajor, row.bands.reduce(0) { $0 + $1.count })
        })
        XCTAssertEqual(perOS, expected)
        XCTAssertEqual(expected, [15: 385, 14: 84, 13: 38, 12: 17])

        let gapTotal = DemoData.controlGapsByOSMajor.reduce(0) { total, row in
            total + row.macsByGapCount.enumerated().reduce(0) { $0 + $1.offset * $1.element }
        }
        XCTAssertEqual(gapTotal, snapshot.controlGaps.reduce(0) { $0 + $1.failingDevices })
        XCTAssertEqual(snapshot.totalDevices, DemoData.totalDevices)
    }
}
