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

    // MARK: - Compliance Benchmarks

    func testBenchmarkIsTheConfiguredBaselineOverTheFleet() {
        let snapshot = DemoData.complianceBenchmarksSnapshot
        XCTAssertEqual(snapshot.benchmarks, [DemoData.complianceBaseline])
        XCTAssertEqual(snapshot.totalRules, DemoData.benchmarkRules.count + 1)
        XCTAssertEqual(snapshot.totalDevices, DemoData.totalDevices)
        for rule in snapshot.rules {
            XCTAssertEqual(rule.passed + (rule.failed ?? 0) + rule.unknown,
                           DemoData.totalDevices, rule.rule)
            XCTAssertEqual(rule.devices, DemoData.totalDevices, rule.rule)
        }
    }

    func testBenchmarkRulesAreTheControlsAndTheTopFailingRules() throws {
        let rules = Dictionary(uniqueKeysWithValues:
            DemoData.complianceBenchmarksSnapshot.rules.map { ($0.rule, $0) })
        XCTAssertEqual(rules["system_settings_filevault_enforce"]?.failed, 11)
        XCTAssertEqual(rules["system_settings_firewall_enable"]?.failed, 42)
        XCTAssertEqual(rules["os_gatekeeper_enable"]?.failed, 12)
        XCTAssertEqual(rules["os_sip_enable"]?.failed, 0)
        let secureBoot = try XCTUnwrap(rules[DemoData.unknownBenchmarkRule])
        XCTAssertNil(secureBoot.failed)
        XCTAssertEqual(secureBoot.unknown, DemoData.totalDevices)
        for top in DemoData.topFailingRules {
            XCTAssertEqual(rules[top.ruleID]?.failed, top.fails, top.ruleID)
        }
    }

    /// Each rule fails on as many listed Macs as it counts, and the counters add
    /// up: 213 passing, the Pass band, and 311 failing.
    func testBenchmarkDevicesAgreeWithTheRules() {
        let snapshot = DemoData.complianceBenchmarksSnapshot
        for rule in DemoData.benchmarkRules {
            let failing = DemoData.benchmarkFailures.filter { $0.contains(rule.id) }.count
            XCTAssertEqual(failing, rule.failing, rule.id)
        }
        let devices = snapshot.deviceAggregate
        XCTAssertEqual(devices.passing, DemoData.complianceBands.first?.count)
        XCTAssertEqual(devices.failing, 311)
        XCTAssertEqual(devices.unknown, 0)
        let failedTotal = snapshot.devices.reduce(0) { $0 + ($1.rulesFailed ?? 0) }
        XCTAssertEqual(failedTotal, snapshot.ruleAggregate.failed)
    }

    /// No Mac passes more rules than report a result: the old demo host passed
    /// 5 of 5 while Secure Boot had no result on any Mac.
    func testNoMacPassesARuleWithoutAResult() {
        let evaluated = DemoData.benchmarkRules.count
        for device in DemoData.complianceBenchmarksSnapshot.devices {
            XCTAssertEqual(device.rulesPassed + (device.rulesFailed ?? 0), evaluated,
                           device.device)
            XCTAssertEqual(device.compliance == "100%", device.rulesFailed == 0, device.device)
        }
    }

    func testPercentLabelDropsATrailingZero() {
        XCTAssertEqual(DemoData.percentLabel(482, of: 524), "92%")
        XCTAssertEqual(DemoData.percentLabel(390, of: 524), "74.4%")
        XCTAssertEqual(DemoData.percentLabel(10, of: 11), "90.9%")
        XCTAssertEqual(DemoData.percentLabel(11, of: 11), "100%")
    }

    // MARK: - DDM

    func testDDMIsOnForEveryMacExceptMonterey() {
        let monterey = DemoData.osDistribution.filter { entry in
            ComplianceBandingService.parseOSMajor(DemoData.osVersionNumber(entry.version)) == 12
        }.reduce(0) { $0 + $1.count }
        XCTAssertEqual(monterey, 17)
        XCTAssertEqual(DemoData.ddmFleetMacs.count, DemoData.totalDevices - monterey)
        XCTAssertTrue(DemoData.ddmFleetMacs.allSatisfy { $0.osMajor >= 13 })
        let snapshot = DemoData.ddmDeviceStatusSnapshot
        XCTAssertTrue(snapshot.isDetected)
        XCTAssertEqual(snapshot.records.count, 507)
        XCTAssertEqual(snapshot.ddmReportedCount, 507)
    }

    /// The blueprint and declaration-source rows count the Macs the per-device
    /// sections list, and no blueprint succeeds on more Macs than have DDM.
    func testDDMBlueprintsAgreeWithThePerDeviceScan() throws {
        let platform = DemoData.ddmBlueprintSnapshot
        let devices = DemoData.ddmDeviceStatusSnapshot
        let baseline = try XCTUnwrap(platform.blueprints.first { $0.name == "Baseline Security" })
        let updates = try XCTUnwrap(
            platform.blueprints.first { $0.name == "Software Update Eligibility" })
        XCTAssertEqual(baseline.failed, 12)
        XCTAssertEqual(updates.failed, 42)
        for blueprint in [baseline, updates] {
            XCTAssertEqual(blueprint.succeeded + (blueprint.failed ?? 0), 507, blueprint.name)
            let source = try XCTUnwrap(
                platform.declarations.first { $0.source == blueprint.name })
            XCTAssertEqual(source.devices, 507)
            XCTAssertEqual(source.successful, blueprint.succeeded)
            XCTAssertEqual(source.unsuccessful, blueprint.failed)
        }
        let byIdentifier = Dictionary(uniqueKeysWithValues:
            devices.byIdentifier.map { ($0.identifier, $0) })
        XCTAssertEqual(byIdentifier["com.meridian.baseline.legacy-profile"]?.invalid, 12)
        XCTAssertEqual(byIdentifier["com.meridian.softwareupdate.enforcement"]?.inactive, 42)
        XCTAssertEqual(devices.failingDeclarationCount, 54)
    }

    func testDDMUpdatesArePendingOnTheOlderSequoiaRelease() {
        let snapshot = DemoData.ddmDeviceStatusSnapshot
        XCTAssertEqual(snapshot.pendingVersions.map { $0.version }, ["15.4"])
        XCTAssertEqual(snapshot.pendingVersions.first?.devices.count, 98)
        XCTAssertEqual(snapshot.failureReasons.map { $0.devices.count }, [28, 14])
    }

    // MARK: - Health Audit

    func testAuditFindingsCountTheControlGapsAndStaleMacs() {
        let findings = Dictionary(uniqueKeysWithValues:
            DemoData.auditFindings.map { ($0.name, $0) })
        let controls = DemoData.securityControls
        XCTAssertEqual(findings["Computers without FileVault"]?.affected,
                       controls.total - controls.fileVault)
        XCTAssertEqual(findings["Computers without FileVault"]?.severity, "CRITICAL")
        XCTAssertEqual(findings["Firewall disabled"]?.affected, 42)
        XCTAssertEqual(findings["Gatekeeper disabled"]?.affected, 12)
        let stale = findings["Stale computers (30+ days since check-in)"]
        XCTAssertEqual(stale?.affected, 26)
        XCTAssertEqual(Double(stale?.affected ?? 0),
                       Double(DemoData.totalDevices) - (DemoData.activeDevicesTrend.last ?? 0))
        XCTAssertEqual(DemoData.auditFindings.filter { $0.severity == "WARNING" }.count, 3)
    }

    func testAuditDemoRunsPrecedeTheReferenceDate() {
        XCTAssertLessThan(DemoData.auditRunDate, DemoData.referenceDate)
        XCTAssertLessThan(DemoData.groupAnalysisRunDate, DemoData.referenceDate)
        XCTAssertTrue(DemoData.duplicateSerialsSnapshot.isDetected)
        XCTAssertTrue(DemoData.duplicateSerialsSnapshot.groups.isEmpty)
        for group in DemoData.unusedGroups {
            XCTAssertNotNil(Int(group.id), group.id)
            XCTAssertLessThan(group.memberCount, DemoData.totalDevices)
        }
    }

    // MARK: - Extension Attributes

    func testExtensionAttributesCoverTheFleet() {
        let snapshot = ExtensionAttributesView.demoSnapshot
        XCTAssertEqual(snapshot.totalDevices, DemoData.totalDevices)
        XCTAssertTrue(snapshot.coverage.allSatisfy {
            $0.totalDevices == DemoData.totalDevices && $0.populatedDevices <= $0.totalDevices
        })
        let coverage = Dictionary(uniqueKeysWithValues:
            snapshot.coverage.map { ($0.eaName, $0.populatedDevices) })
        XCTAssertEqual(coverage["FileVault Status"], DemoData.totalDevices)
        XCTAssertEqual(coverage["CrowdStrike Status"], DemoData.securityAgents.first?.installed)
        XCTAssertEqual(coverage["CrowdStrike Status"], 506)
        let crowdStrike = snapshot.definitions.first { $0.name == "CrowdStrike Status" }
        XCTAssertEqual(crowdStrike?.enabled, true)
    }

    /// Each value distribution adds up to the Macs its attribute covers, and
    /// FileVault splits as the Security Posture screen counts it.
    func testExtensionAttributeDistributionsMatchTheirCoverage() {
        let snapshot = ExtensionAttributesView.demoSnapshot
        let coverage = Dictionary(uniqueKeysWithValues:
            snapshot.coverage.map { ($0.eaName, $0.populatedDevices) })
        for distribution in snapshot.valueDistributions {
            let total = distribution.top.reduce(distribution.otherCount) { $0 + $1.count }
            XCTAssertEqual(total, coverage[distribution.eaName], distribution.eaName)
        }
        let fileVault = snapshot.valueDistributions.first { $0.eaName == "FileVault Status" }
        XCTAssertEqual(fileVault?.top.map(\.count), [513, 11])
        XCTAssertLessThanOrEqual(snapshot.snapshotDate ?? .distantFuture, DemoData.referenceDate)
    }

    // MARK: - Jamf Protect

    /// Every tile, bar and deep-dive chart counts the rows the screen lists. The
    /// old demo left the arrays empty and drew rows separately, so the High Alerts
    /// tile vanished and the timeline found no devices beside 8 alerts.
    func testProtectCountsComeFromItsRows() {
        let snapshot = DemoData.protectSnapshot
        XCTAssertEqual(snapshot.computers.count, 12)
        XCTAssertEqual(snapshot.totalComputers, snapshot.computers.count)
        XCTAssertEqual(snapshot.alerts.count, 8)
        XCTAssertEqual(snapshot.highAlerts + snapshot.mediumAlerts + snapshot.lowAlerts
            + snapshot.informationalAlerts, snapshot.alerts.count)
        XCTAssertEqual(snapshot.highAlerts, 2)
        XCTAssertEqual(snapshot.webProtectionActiveCount, 10)
        XCTAssertEqual(snapshot.fullDiskAccessCount, 9)
        XCTAssertEqual(snapshot.connectedCount, 10)
        XCTAssertEqual(snapshot.failingInsights, 4)
        for insight in snapshot.insights {
            XCTAssertEqual((insight.totalPass ?? 0) + (insight.totalFail ?? 0),
                           snapshot.totalComputers, insight.label ?? "")
        }
        let stages = ProtectDashboardService.killChainBuckets(snapshot.alerts)
        XCTAssertEqual(stages.reduce(0) { $0 + $1.count }, snapshot.alerts.count)
        let versions = ProtectDashboardService.agentVersionDistribution(snapshot.computers)
        XCTAssertEqual(versions.map { $0.count }, [8, 3, 1])
    }

    /// The pilot's Macs are fleet Macs on the fleet's macOS versions; every alert
    /// is on one of them and precedes the reference date; the offline agents last
    /// connected after their own alerts.
    func testProtectRowsFitTheFleetAndTheDemoDate() throws {
        let snapshot = DemoData.protectSnapshot
        let parser = ISO8601DateFormatter()
        let hosts = Set(snapshot.computers.compactMap(\.hostName))
        XCTAssertTrue(hosts.isSubset(of: Set(DemoData.fleetMacs.map(\.name))))
        let versions = Set(DemoData.osDistribution.map {
            "macOS " + DemoData.osVersionNumber($0.version)
        })
        for alert in snapshot.alerts {
            let host = try XCTUnwrap(alert.hostName)
            XCTAssertTrue(hosts.contains(host), host)
            let created = try XCTUnwrap(parser.date(from: alert.created ?? ""))
            XCTAssertLessThan(created, DemoData.referenceDate)
            XCTAssertFalse(
                ProtectDashboardService.alertTimeline(for: host, in: snapshot.alerts).isEmpty)
        }
        for computer in snapshot.computers {
            XCTAssertTrue(versions.contains(computer.osString ?? ""), computer.osString ?? "")
            let seen = try XCTUnwrap(parser.date(from: computer.lastConnection ?? ""))
            XCTAssertLessThan(seen, DemoData.referenceDate)
            guard !ProtectDashboardService.isConnected(computer.connectionStatus) else { continue }
            let alertDates = snapshot.alerts
                .filter { $0.hostName == computer.hostName }
                .compactMap { parser.date(from: $0.created ?? "") }
            let lastAlert = try XCTUnwrap(alertDates.max())
            XCTAssertGreaterThan(seen, lastAlert, computer.hostName ?? "")
        }
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
