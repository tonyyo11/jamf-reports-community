import XCTest
@testable import JamfReports

/// A Mac enrolled in MDM that never sent inventory (no Jamf binary). Row shapes are jamf-cli
/// 1.36.0's against Jamf Pro 11.33.3 (keys and types only): jamf-cli reports its firewall as
/// `false`, its FileVault and OS version blank and its Gatekeeper as NOT_COLLECTED, and counts
/// it as Gatekeeper enabled in the summary.
final class NeverInventoriedTests: XCTestCase {

    private let summaryBothDead: [String: Any] = ["section": "summary", "data": [
        "total_devices": 2, "filevault_encrypted": 0, "filevault_encrypted_pct": "0.0%",
        "sip_enabled": 0, "firewall_enabled": 0, "gatekeeper_enabled": 2,
    ]]

    private func deadRow(_ serial: String) -> [String: Any] {
        ["section": "device", "name": "vm-\(serial)", "serial": serial, "os_version": "",
         "filevault": "", "sip": "NOT_COLLECTED", "firewall": false, "gatekeeper": "NOT_COLLECTED"]
    }

    private func liveRow(firewall: Bool) -> [String: Any] {
        ["section": "device", "name": "tahoe", "serial": "LIVE1", "os_version": "26.6.2",
         "filevault": "UNENCRYPTED", "sip": "ENABLED", "firewall": firewall,
         "gatekeeper": "APP_STORE_AND_IDENTIFIED_DEVELOPERS"]
    }

    private func items(_ rows: [[String: Any]]) throws -> [SecurityReportItem] {
        try JSONDecoder().decode(
            [SecurityReportItem].self, from: JSONSerialization.data(withJSONObject: rows))
    }

    private func fleet(_ rows: [[String: Any]]) throws -> SecurityFleetCounts {
        try XCTUnwrap(SecurityFleetCounts.build(
            items: items(rows), hardware: [:], policy: SecurityControlPolicy()))
    }

    func testTwoMacsWithNoInventoryReportNoControl() throws {
        let counts = try fleet([summaryBothDead, deadRow("A"), deadRow("B")])
        for control in SecurityControl.allCases {
            XCTAssertEqual(counts.controls[control]?.notReported, 2, "\(control)")
            XCTAssertEqual(counts.controls[control]?.fail, 0, "\(control)")
            XCTAssertNil(counts.onCount(control, reported: 0), "\(control)")
            XCTAssertNil(counts.scoreMeasure(for: control)?.share, "\(control)")
        }
        XCTAssertEqual(counts.controls[.gatekeeper]?.on, 0, "jamf-cli's Gatekeeper count capped")
        XCTAssertEqual(counts.p0, 0)
    }

    func testOneLiveOneDeadGradesOnlyTheLiveMac() throws {
        let summary: [String: Any] = ["section": "summary", "data": [
            "total_devices": 2, "filevault_encrypted": 0, "sip_enabled": 1,
            "firewall_enabled": 0, "gatekeeper_enabled": 2,
        ]]
        let counts = try fleet([summary, liveRow(firewall: false), deadRow("A")])
        let firewall = try XCTUnwrap(counts.controls[.firewall])
        XCTAssertEqual(firewall.fail, 1, "an inventoried Mac with the firewall off still fails")
        XCTAssertEqual(firewall.notReported, 1)
        XCTAssertEqual(counts.controls[.gatekeeper]?.on, 1)
        XCTAssertEqual(counts.onCount(.gatekeeper, reported: 2), 1)
        XCTAssertEqual(counts.summaryPct(.gatekeeper, reported: 100, reportedOn: 2), 50)
        XCTAssertEqual(counts.summaryPct(.sip, reported: 50.04, reportedOn: 1), 50.04,
                       "jamf-cli's own percentage where the cap changed nothing")
    }

    func testCapHoldsWhenALiveMacReadsOff() throws {
        var off = liveRow(firewall: true)
        off["serial"] = "LIVE2"
        off["gatekeeper"] = "DISABLED"
        let summary: [String: Any] = ["section": "summary", "data": [
            "total_devices": 3, "gatekeeper_enabled": 2,
        ]]
        let counts = try fleet([summary, liveRow(firewall: true), off, deadRow("A")])
        let gatekeeper = try XCTUnwrap(counts.controls[.gatekeeper])
        XCTAssertEqual(gatekeeper.on, 1, "the dead Mac jamf-cli counted on is removed")
        XCTAssertEqual(gatekeeper.fail, 1)
        XCTAssertEqual(gatekeeper.notReported, 1)
        XCTAssertEqual(try XCTUnwrap(counts.scoreMeasure(for: .gatekeeper)?.share), 50,
                       accuracy: 0.001)
    }

    func testAFleetWithNoDeadMacIsUnchanged() throws {
        let summary: [String: Any] = ["section": "summary", "data": [
            "total_devices": 1, "gatekeeper_enabled": 2, "firewall_enabled": 0,
        ]]
        let counts = try fleet([summary, liveRow(firewall: false)])
        XCTAssertEqual(counts.controls[.gatekeeper]?.on, 2, "the summary's count, as before")
        XCTAssertEqual(counts.summaryPct(.firewall, reported: 0, reportedOn: 0), 0)
    }

    func testAPercentageWithoutACountIsKept() {
        let counts = SecurityFleetCounts.build(
            totalDevices: 2, onCounts: [:], devices: [], hardware: [:],
            policy: SecurityControlPolicy())
        XCTAssertEqual(counts.summaryPct(.fileVault, reported: 41.2, reportedOn: nil), 41.2)
    }

    func testARowWithoutAnOSVersionKeyStillReadsTheFirewall() throws {
        var row = deadRow("A")
        row.removeValue(forKey: "os_version")
        let summary: [String: Any] = ["section": "summary", "data": [
            "total_devices": 1, "firewall_enabled": 0, "gatekeeper_enabled": 1,
        ]]
        let counts = try fleet([summary, row])
        XCTAssertEqual(counts.controls[.firewall]?.fail, 1)
        XCTAssertEqual(counts.controls[.gatekeeper]?.on, 1, "no cap without the evidence")
    }

    func testComplianceProxyHasNoMacToJudge() throws {
        guard case .device(let device) = try items([deadRow("A")]).first else {
            return XCTFail("not a device row")
        }
        XCTAssertNil(CompliancePostureService.deviceGapCount(
            device, policy: SecurityControlPolicy(), hardwareEncrypted: nil))
    }

    func testComplianceRowWithNoCheckInIsStale() throws {
        let rows: [[String: Any]] = [
            ["days_since_contact": "N/A", "last_contact": "", "managed": true, "os_version": "",
             "stale": false],
            ["days_since_contact": "3", "last_contact": "2026-11-10", "managed": true,
             "os_version": "26.6.2", "stale": false],
        ]
        let decoded = try JSONDecoder().decode(
            [DeviceComplianceRow].self, from: JSONSerialization.data(withJSONObject: rows))
        XCTAssertEqual(decoded.map(\.isNeverInventoried), [true, false])
        let rule = StaleRule(days: 30)
        XCTAssertEqual(decoded[0].staleAge(rule, computers: nil), .never)
        XCTAssertTrue(decoded[0].isStale(rule, computers: nil), "jamf-cli's stale: false is overruled")
        XCTAssertFalse(decoded[1].isStale(rule, computers: nil))
    }

    func testComputerRecordWithNoInventoryHasNoControlValues() {
        let item: [String: Any] = [
            "id": "1", "udid": "U1",
            "general": ["name": "vm-A", "reportDate": NSNull(), "lastCheckIn": NSNull(),
                        "remoteManagement": ["managed": true]],
            "hardware": ["serialNumber": "A", "modelIdentifier": "VirtualMac2,1"],
            "operatingSystem": ["version": NSNull()],
            "security": ["sipStatus": "NOT_COLLECTED", "firewallEnabled": false,
                         "gatekeeperStatus": "NOT_COLLECTED",
                         "bootstrapTokenEscrowedStatus": "NOT_SUPPORTED"],
            "diskEncryption": ["fileVault2Enabled": false],
        ]
        let record = DeviceInventoryService.recordFromComputer(item, source: "computers")
        XCTAssertEqual([record.fileVault, record.sip, record.firewall, record.gatekeeper,
                        record.bootstrapToken], ["", "", "", "", ""])
        XCTAssertEqual(record.securityGapCount(policy: SecurityControlPolicy()), 0)
    }

    func testSummaryOfTwoDeadMacsHasNoControlShareScoreOrStability() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-neverinv-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd'T'HHmmss"
        let name = stamp.string(from: Date().addingTimeInterval(-3600))
        let snapshots: [(String, Any)] = [
            ("security", [summaryBothDead, deadRow("A"), deadRow("B")]),
            ("device-compliance", [
                ["days_since_contact": "N/A", "last_contact": "", "managed": true,
                 "os_version": "", "stale": false],
                ["days_since_contact": "N/A", "last_contact": "", "managed": true,
                 "os_version": "", "stale": false],
            ]),
            ("computers", ["A", "B"].map { serial -> [String: Any] in
                ["id": serial, "udid": "U\(serial)",
                 "general": ["name": "vm-\(serial)", "reportDate": NSNull(),
                             "lastCheckIn": NSNull(), "remoteManagement": ["managed": true]],
                 "hardware": ["serialNumber": serial, "modelIdentifier": "VirtualMac2,1"],
                 "operatingSystem": ["version": NSNull()],
                 "security": ["sipStatus": "NOT_COLLECTED", "firewallEnabled": false,
                              "gatekeeperStatus": "NOT_COLLECTED", "secureBootLevel": NSNull(),
                              "bootstrapTokenEscrowedStatus": "NOT_SUPPORTED",
                              "xprotectVersion": NSNull()],
                 "diskEncryption": ["fileVault2Enabled": false]]
            }),
        ]
        for (kind, body) in snapshots {
            let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: body)
                .write(to: dir.appendingPathComponent("\(kind)_\(name).json"))
        }
        let summaries = root.appendingPathComponent("summaries", isDirectory: true)
        ReportEngine(config: ReportConfig(), dataDir: dataDir).emitSummaryJSON(
            summariesDir: summaries)
        let summary = try XCTUnwrap(SummaryJSONParser.parseDirectory(summaries).first)
        XCTAssertEqual(summary.totalDevices, 2, "they are still Macs")
        XCTAssertNil(summary.fileVaultPct)
        XCTAssertNil(summary.sipPct)
        XCTAssertNil(summary.firewallPct)
        XCTAssertNil(summary.gatekeeperPct)
        XCTAssertNil(summary.compliancePct)
        XCTAssertNil(summary.stabilityIndex)
        XCTAssertEqual(summary.staleCount, 2, "never checked in counts as stale")
        XCTAssertEqual(summary.securityScore, 0, "only checked in is scored, and neither did")
    }

    // MARK: - Every per-device reader (fix round 2)

    private func computersItem(name: String, inventoried: Bool, firewall: Bool) -> [String: Any] {
        let blank: Any = NSNull()
        let reportDate: Any = inventoried ? "2026-11-10T10:00:00Z" : blank
        let version: Any = inventoried ? "26.6.2" : blank
        let general: [String: Any] = [
            "name": name, "reportDate": reportDate, "remoteManagement": ["managed": true]]
        let security: [String: Any] = [
            "sipStatus": inventoried ? "ENABLED" : "NOT_COLLECTED", "firewallEnabled": firewall,
            "gatekeeperStatus": inventoried ? "APP_STORE" : "NOT_COLLECTED",
            "bootstrapTokenEscrowedStatus": "NOT_SUPPORTED"]
        var item: [String: Any] = ["id": name, "udid": "U-\(name)", "general": general]
        item["hardware"] = ["serialNumber": "S-\(name)", "modelIdentifier": "Mac15,3"]
        item["operatingSystem"] = ["version": version]
        item["security"] = security
        item["diskEncryption"] = ["fileVault2Enabled": false]
        return item
    }

    func testDeviceSecurityStateReadsNoDataForADeadMacAndOffForALiveOne() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-dss-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let kind = dir.appendingPathComponent("computers", isDirectory: true)
        try FileManager.default.createDirectory(at: kind, withIntermediateDirectories: true)
        let dead = computersItem(name: "dead", inventoried: false, firewall: false)
        let live = computersItem(name: "live", inventoried: true, firewall: false)
        let body: [[String: Any]] = [dead, live]
        try JSONSerialization.data(withJSONObject: body).write(to: kind.appendingPathComponent("computers_20261110T100000.json"))
        let dash = CoreDashboard(config: ReportConfig(), dataDir: dir, workbook: Workbook())
        try dash.writeDeviceSecurityState()
        let cells = try XCTUnwrap(dash.workbook.sheet(named: "Device Security State")).dedupedCells
        func text(_ name: String) -> [String] {
            var found: [String] = []
            var nameRow = -1
            for cell in cells where cell.col == 0 {
                if case .string(let value) = cell.value, value == name { nameRow = cell.row }
            }
            for cell in cells where cell.row == nameRow && cell.col >= 2 {
                found.append(String(describing: cell.value))
            }
            return found
        }
        XCTAssertFalse(text("dead").isEmpty)
        XCTAssertTrue(text("dead").allSatisfy { $0.contains("No Data") }, "\(text("dead"))")
        XCTAssertTrue(text("live").contains { $0.contains("DISABLED") }, "real false stays off")
    }

    func testComputersRecordWithFirewallFalseReadsOffOnlyWhenInventoried() {
        let policy = SecurityControlPolicy()
        let live = DeviceInventoryService.recordFromComputer(
            computersItem(name: "live", inventoried: true, firewall: false), source: "computers")
        let dead = DeviceInventoryService.recordFromComputer(
            computersItem(name: "dead", inventoried: false, firewall: false), source: "computers")
        XCTAssertEqual(policy.reading(live.firewall, for: .firewall), false)
        XCTAssertNil(policy.reading(dead.firewall, for: .firewall))
        XCTAssertEqual(dead.securityGapCount(policy: policy), 0)
        XCTAssertNotEqual(live.securityGapCount(policy: policy), 0)
    }

    func testP0TableLeavesADeadMacOutAndKeepsALiveOne() throws {
        let rows = [deadRow("A"), liveRow(firewall: false)]
        let gaps = HtmlReport.P0Gaps.build(
            items: try items(rows), hardware: [:], policy: SecurityControlPolicy())
        XCTAssertEqual(gaps.macs.map(\.serial), ["LIVE1"])
        XCTAssertTrue(gaps.macs.first?.controls.contains(.firewall) == true)
    }

    func testComplianceDeviceRowsOfADeadMacHaveNoReading() throws {
        let device = try XCTUnwrap(items([deadRow("A")]).compactMap { item -> SecurityDevice? in
            if case .device(let d) = item { return d } else { return nil }
        }.first)
        for control in SecurityControl.allCases {
            XCTAssertNil(device.reading(of: control, policy: SecurityControlPolicy()), "\(control)")
        }
    }
}
