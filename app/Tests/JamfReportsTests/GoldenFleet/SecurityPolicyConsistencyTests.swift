import Foundation
import XCTest
@testable import JamfReports

/// One fleet, every surface, three policies (Task 9 of
/// docs/superpowers/plans/2026-10-01-security-policy.md). The summary writer, both posture
/// services, the risk scorer, the workbook sheets and the HTML report read the same `security`
/// and `computers` snapshots, so under one policy they agree with each other and with the
/// plan's table. Expected values are the table's hand arithmetic, never re-derived.
final class SecurityPolicyConsistencyTests: XCTestCase {

    nonisolated(unsafe) private var testRoot: URL!
    nonisolated(unsafe) private var savedOverride: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        testRoot = GoldenFleetWorkspace.freshRoot()
        // No surface here is profile-keyed; the override keeps one that becomes so off the
        // real ~/Jamf-Reports.
        let workspacesRoot = testRoot.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot, withIntermediateDirectories: true)
        savedOverride = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
    }

    override func tearDownWithError() throws {
        if let saved = savedOverride {
            setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1)
        } else {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
        }
        if let dir = testRoot { try? FileManager.default.removeItem(at: dir) }
        testRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - The fleet

    private struct FleetMac: Sendable {
        let serial: String
        /// Nil: the Mac has no computers record.
        let appleSilicon: Bool?
        let model: String
        let fileVault: String
        let sip: String
        let firewall: Bool
        let gatekeeper: String
        var name: String { "Lab-Mac-" + serial.dropFirst(4).prefix(4) }
    }

    private static let fleet: [FleetMac] = [
        FleetMac(serial: "FXTR0101AA", appleSilicon: true, model: "Mac14,2",
                 fileVault: "ENCRYPTED", sip: "ENABLED", firewall: true,
                 gatekeeper: "APP_STORE_AND_IDENTIFIED_DEVELOPERS"),
        FleetMac(serial: "FXTR0102AA", appleSilicon: true, model: "Mac14,5",
                 fileVault: "UNENCRYPTED", sip: "ENABLED", firewall: true,
                 gatekeeper: "APP_STORE"),
        FleetMac(serial: "FXTR0103AA", appleSilicon: false, model: "MacBookPro16,2",
                 fileVault: "UNENCRYPTED", sip: "ENABLED", firewall: false,
                 gatekeeper: "APP_STORE"),
        FleetMac(serial: "FXTR0104AA", appleSilicon: false, model: "MacBookPro14,1",
                 fileVault: "UNENCRYPTED", sip: "DISABLED", firewall: true,
                 gatekeeper: "DISABLED"),
        FleetMac(serial: "FXTR0105AA", appleSilicon: nil, model: "",
                 fileVault: "UNENCRYPTED", sip: "ENABLED", firewall: false,
                 gatekeeper: "APP_STORE"),
        FleetMac(serial: "FXTR0106AA", appleSilicon: true, model: "Mac15,3",
                 fileVault: "ENCRYPTED", sip: "ENABLED", firewall: true,
                 gatekeeper: "APP_STORE"),
    ]

    private static let policyA = ""
    private static let policyB = "security_policy:\n  filevault_off_hardware_encrypted: warning\n"
    private static let policyC = "security_policy:\n  controls:\n    firewall: ignore\n"

    /// One security report (summary: FileVault 2, SIP 5, Firewall 4, Gatekeeper 5 of 6, and a
    /// device row per Mac) and a computers snapshot for every Mac but FXTR0105AA.
    private func writeFleet() throws -> URL {
        let dataDir = testRoot.appendingPathComponent("fleet", isDirectory: true)
            .appendingPathComponent("jamf-cli-data", isDirectory: true)
        let now = Date()
        var report = GoldenFleetWorkspace.securitySummaryPayload(
            total: 6, filevault: 2, sip: 5, firewall: 4, gatekeeper: 5)
        report += Self.fleet.map {
            GoldenFleetWorkspace.securityDeviceRow(
                name: $0.name, serial: $0.serial, osVersion: "15.4.1", fileVault: $0.fileVault,
                sip: $0.sip, firewall: $0.firewall, gatekeeper: $0.gatekeeper)
        }
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "security", dataDir: dataDir, at: now, rows: report)
        let computers = Self.fleet.compactMap { mac -> [String: Any]? in
            guard let appleSilicon = mac.appleSilicon else { return nil }
            return GoldenFleetWorkspace.computerRow(
                name: mac.name, serial: mac.serial, appleSilicon: appleSilicon,
                modelIdentifier: mac.model, fileVault: mac.fileVault, sip: mac.sip,
                firewall: mac.firewall, gatekeeper: mac.gatekeeper)
        }
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "computers", dataDir: dataDir, at: now, rows: computers)
        return dataDir
    }

    // MARK: - Reading every surface

    private typealias SheetCell = (text: String, format: CellFormat?)

    private struct RenderedTile {
        let cssClass: String
        /// The tile's label, then any note under it.
        let labels: [String]
    }

    private struct Surfaces {
        let summary: DailySummary
        let posture: SecurityPostureService.Snapshot
        let compliance: CompliancePostureService.Snapshot
        let executive: CoreDashboard.ExecutiveSummaryMetrics
        /// Risk factors each computers record triggers, by serial.
        let risk: [String: Set<DeviceRisk.Factor>]
        let workbook: Workbook
        let tiles: [RenderedTile]
    }

    private func measure(_ yaml: String, dataDir: URL) async throws -> Surfaces {
        let config = try ConfigLoader.loadFromString(yaml)
        let policy = config.resolvedSecurityPolicy
        let hardware = HardwareEncryption.index(dataDir: dataDir, for: policy)

        let summariesDir = testRoot.appendingPathComponent(
            "summaries-\(UUID().uuidString)", isDirectory: true)
        ReportEngine(config: config, dataDir: dataDir).emitSummaryJSON(summariesDir: summariesDir)
        let summary = try XCTUnwrap(
            SummaryJSONParser.parseDirectory(summariesDir).first, "no summary.json written")

        let securityURL = try XCTUnwrap(FileManager.newestJSONFile(
            in: dataDir.appendingPathComponent("security", isDirectory: true)))
        let posture = try SecurityPostureService.load(
            from: securityURL, policy: policy, hardware: hardware)
            .scored(config: config, dataDir: dataDir)
        let compliance = try XCTUnwrap(CompliancePostureService.load(
            from: securityURL, policy: policy, hardware: hardware))

        let dashboard = CoreDashboard(config: config, dataDir: dataDir, workbook: Workbook())
        try dashboard.writeDeviceSecurityState()
        try dashboard.writeCompliancePosture()

        return Surfaces(
            summary: summary, posture: posture, compliance: compliance,
            executive: CoreDashboard.executiveMetrics(config: config, dataDir: dataDir),
            risk: try riskFactors(policy: policy, dataDir: dataDir),
            workbook: dashboard.workbook,
            tiles: try await htmlTiles(config: config, dataDir: dataDir))
    }

    /// Scores each record of the computers snapshot the way the Devices screen does.
    private func riskFactors(
        policy: SecurityControlPolicy, dataDir: URL
    ) throws -> [String: Set<DeviceRisk.Factor>] {
        let url = try XCTUnwrap(FileManager.newestJSONFile(
            in: dataDir.appendingPathComponent("computers", isDirectory: true)))
        let items = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        var factors: [String: Set<DeviceRisk.Factor>] = [:]
        for item in items {
            let record = DeviceInventoryService.recordFromComputer(item, source: "jamf-cli")
            let risk = RiskScoringService.score(input: .from(record: record, policy: policy))
            factors[record.serial] = Set(risk.triggered.map(\.factor))
        }
        return factors
    }

    /// The summary tiles of the full HTML report.
    private func htmlTiles(config: ReportConfig, dataDir: URL) async throws -> [RenderedTile] {
        let outputURL = testRoot.appendingPathComponent("report-\(UUID().uuidString).html")
        try await HtmlReport(config: config, dataDir: dataDir).generate(outputURL: outputURL)
        let html = try String(contentsOf: outputURL, encoding: .utf8)
        let start = try XCTUnwrap(html.range(of: "<section class=\"tiles-row\">"))
        let end = try XCTUnwrap(html.range(
            of: "</section>", range: start.upperBound..<html.endIndex))
        return html[start.upperBound..<end.lowerBound]
            .components(separatedBy: "<div class=\"tile ").dropFirst().map { block in
                RenderedTile(
                    cssClass: String(block.prefix { $0 != "\"" }),
                    labels: block.components(separatedBy: "<div class=\"tile-label\">")
                        .dropFirst().map { String($0.prefix { $0 != "<" }) })
            }
    }

    private func tile(_ surfaces: Surfaces, _ label: String) throws -> RenderedTile {
        try XCTUnwrap(
            surfaces.tiles.first { $0.labels.first?.hasPrefix(label) == true },
            "no \(label) tile")
    }

    private static func text(_ value: CellValue) -> String {
        switch value {
        case .string(let s): s
        case .int(let i): "\(i)"
        case .double(let d): "\(d)"
        case .bool(let b): "\(b)"
        case .blank: ""
        }
    }

    /// The cells of the row whose first cell reads `label`, by column.
    private func row(
        _ surfaces: Surfaces, _ sheet: String, _ label: String
    ) throws -> [Int: SheetCell] {
        let ws = try XCTUnwrap(surfaces.workbook.sheet(named: sheet), "no \(sheet) sheet")
        let cells = ws.dedupedCells
        let first = try XCTUnwrap(
            cells.first { $0.col == 0 && Self.text($0.value) == label },
            "\(sheet) has no row \(label)")
        var result: [Int: SheetCell] = [:]
        for cell in cells where cell.row == first.row {
            result[cell.col] = (Self.text(cell.value), cell.format)
        }
        return result
    }

    private static func round1(_ value: Double?) -> Double? {
        value.map { ($0 * 10).rounded() / 10 }
    }

    // MARK: - The table, one column per policy

    /// One column of the plan's table. P0, P1 and the score are one cell per surface in the
    /// table; they hold the same value across the summary, posture and Executive Summary rows.
    private struct Column {
        let p0: Int
        let p1: Int
        let score: Double
        let compliancePct: Double
        let moved: Int
        let passBand: Int
        let noFileVault0102: Bool
        let noFileVault0103: Bool
        let firewallDisabled0103: Bool
        let securityStateFileVault: String
        let securityStateFormat: CellFormat
        let postureSheetFirewall: String
        let fileVaultTileClass: String
        let fileVaultNote: String?
        let firewallTileClass: String
        let firewallLabel: String
    }

    // Scores under the default score factors, by hand. The security report scores FileVault 2 of
    // 6, SIP 5 of 6, Firewall 4 of 6 and Gatekeeper 5 of 6 at weights 15, 10, 10 and 5, and
    // the five computers records (all ESCROWED) score the bootstrap token 5 of 5 at 5; nothing
    // else is collected. A: (500 + 833.3 + 666.7 + 416.7 + 500) / 45 = 64.8. B moves the two
    // hardware-encrypted Macs to warning, so FileVault is 4 of 6: (1000 + 833.3 + 666.7
    // + 416.7 + 500) / 45 = 75.9. C leaves Firewall out: (500 + 833.3 + 416.7 + 500) / 35 = 64.3.

    func testPolicyANoBlock() async throws {
        let surfaces = try await measure(Self.policyA, dataDir: try writeFleet())
        try assertColumn(surfaces, Column(
            p0: 7, p1: 1, score: 64.8, compliancePct: 33.3, moved: 0, passBand: 2,
            noFileVault0102: true, noFileVault0103: true, firewallDisabled0103: true,
            securityStateFileVault: "UNENCRYPTED", securityStateFormat: .red,
            postureSheetFirewall: "RED",
            fileVaultTileClass: "bad", fileVaultNote: nil,
            firewallTileClass: "bad", firewallLabel: "Firewall"), policy: "A")
    }

    /// Ruling (nonFailingPct): at `warning` the two hardware-encrypted Macs stay in the
    /// FileVault share as not failing, so the HTML tile grades 4 of 6 (66.7%), which is still
    /// "bad" (below 80%), the class the table names.
    func testPolicyBHardwareEncryptedAtWarning() async throws {
        let surfaces = try await measure(Self.policyB, dataDir: try writeFleet())
        try assertColumn(surfaces, Column(
            p0: 5, p1: 1, score: 75.9, compliancePct: 50.0, moved: 2, passBand: 3,
            noFileVault0102: false, noFileVault0103: false, firewallDisabled0103: true,
            securityStateFileVault: "FileVault off (hardware-encrypted)",
            securityStateFormat: .yellow,
            postureSheetFirewall: "RED",
            fileVaultTileClass: "bad", fileVaultNote: "2 more hardware-encrypted, FileVault off",
            firewallTileClass: "bad", firewallLabel: "Firewall"), policy: "B")
        XCTAssertEqual(
            surfaces.posture.fleetCounts.nonFailingPct(.fileVault) ?? -1, 400.0 / 6,
            accuracy: 0.001, "B: the FileVault share the HTML tile grades")
    }

    func testPolicyCFirewallIgnored() async throws {
        let surfaces = try await measure(Self.policyC, dataDir: try writeFleet())
        try assertColumn(surfaces, Column(
            p0: 5, p1: 1, score: 64.3, compliancePct: 33.3, moved: 0, passBand: 2,
            noFileVault0102: true, noFileVault0103: true, firewallDisabled0103: false,
            securityStateFileVault: "UNENCRYPTED", securityStateFormat: .red,
            postureSheetFirewall: "Not counted",
            fileVaultTileClass: "bad", fileVaultNote: nil,
            firewallTileClass: "", firewallLabel: "Firewall (not counted)"), policy: "C")
    }

    private func assertColumn(_ s: Surfaces, _ e: Column, policy: String) throws {
        // summary.json
        XCTAssertEqual(s.summary.actionItemsP0, e.p0, "\(policy): summary.json P0")
        XCTAssertEqual(s.summary.actionItemsP1, e.p1, "\(policy): summary.json P1")
        XCTAssertEqual(s.summary.securityScore, e.score, "\(policy): summary.json score")
        XCTAssertEqual(s.summary.fileVaultPct, 33.3, "\(policy): summary.json fileVaultPct")
        XCTAssertEqual(s.summary.compliancePct, e.compliancePct, "\(policy): proxy compliancePct")
        XCTAssertEqual(s.summary.complianceIsProxy, true, "\(policy): compliancePct is the proxy")
        // Security Posture and Compliance Posture services
        XCTAssertEqual(s.posture.fleetCounts.p0, e.p0, "\(policy): posture P0")
        XCTAssertEqual(s.posture.fleetCounts.p1, e.p1, "\(policy): posture P1")
        XCTAssertEqual(s.posture.fleetCounts.fileVaultOffHardwareEncrypted, e.moved,
                       "\(policy): posture moved")
        XCTAssertEqual(s.compliance.bands.first { $0.label == "Pass" }?.count, e.passBand,
                       "\(policy): Compliance Posture Pass band")
        // Executive Summary
        XCTAssertEqual(s.executive.actionItemsP0, e.p0, "\(policy): Executive Summary P0")
        XCTAssertEqual(s.executive.actionItemsP1, e.p1, "\(policy): Executive Summary P1")
        XCTAssertEqual(Self.round1(s.executive.securityScore), e.score,
                       "\(policy): Executive Summary score")
        // Risk
        XCTAssertEqual(s.risk["FXTR0102AA"]?.contains(.noFileVault), e.noFileVault0102,
                       "\(policy): risk noFileVault on 0102")
        XCTAssertEqual(s.risk["FXTR0103AA"]?.contains(.noFileVault), e.noFileVault0103,
                       "\(policy): risk noFileVault on 0103")
        XCTAssertEqual(s.risk["FXTR0103AA"]?.contains(.firewallDisabled), e.firewallDisabled0103,
                       "\(policy): risk firewallDisabled on 0103")
        // Workbook
        let state = try row(s, "Device Security State", "Lab-Mac-0102")
        XCTAssertEqual(state[2]?.text, e.securityStateFileVault,
                       "\(policy): Device Security State FileVault text")
        XCTAssertEqual(state[2]?.format, e.securityStateFormat,
                       "\(policy): Device Security State FileVault format")
        XCTAssertEqual(try row(s, "Compliance Posture", "Firewall Enabled")[2]?.text,
                       e.postureSheetFirewall, "\(policy): Compliance Posture Firewall status")
        // HTML
        let fileVault = try tile(s, "FileVault")
        XCTAssertEqual(fileVault.cssClass, e.fileVaultTileClass, "\(policy): FileVault tile")
        XCTAssertEqual(fileVault.labels.dropFirst().first, e.fileVaultNote,
                       "\(policy): FileVault tile note")
        let firewall = try tile(s, "Firewall")
        XCTAssertEqual(firewall.cssClass, e.firewallTileClass, "\(policy): Firewall tile")
        XCTAssertEqual(firewall.labels.first, e.firewallLabel, "\(policy): Firewall label")
    }

    // MARK: - Surfaces agree with each other

    /// Independent of the table: every surface that shows a number another surface shows
    /// reports the same one, under each policy.
    func testSurfacesAgreeUnderEveryPolicy() async throws {
        let dataDir = try writeFleet()
        for (name, yaml) in [("A", Self.policyA), ("B", Self.policyB), ("C", Self.policyC)] {
            let surfaces = try await measure(yaml, dataDir: dataDir)
            assertCountsAgree(surfaces, policy: name)
            try assertDevicesAgree(surfaces, policy: name)
            try assertGradesAgree(surfaces, policy: name)
        }
    }

    /// P0, P1, the score, the moved Macs and the proxy across summary.json, the posture
    /// services and the Executive Summary; the device rows' gaps against the summary counts.
    private func assertCountsAgree(_ s: Surfaces, policy: String) {
        let fleet = s.posture.fleetCounts
        XCTAssertEqual(s.summary.actionItemsP0, fleet.p0, "\(policy): summary vs posture P0")
        XCTAssertEqual(s.executive.actionItemsP0, fleet.p0, "\(policy): executive vs posture P0")
        XCTAssertEqual(s.summary.actionItemsP1, fleet.p1, "\(policy): summary vs posture P1")
        XCTAssertEqual(s.executive.actionItemsP1, fleet.p1, "\(policy): executive vs posture P1")
        XCTAssertEqual(s.executive.fileVaultOffHardwareEncrypted,
                       fleet.fileVaultOffHardwareEncrypted, "\(policy): executive vs posture moved")

        let postureScore = SecurityScoreCalculator.score(
            factors: s.posture.scoreFactors, measures: s.posture.scoreMeasures).value
        XCTAssertEqual(s.summary.securityScore, Self.round1(postureScore),
                       "\(policy): summary vs posture score")
        XCTAssertEqual(Self.round1(s.executive.securityScore), Self.round1(postureScore),
                       "\(policy): executive vs posture score")

        let pass = s.compliance.bands.first { $0.label == "Pass" }?.count ?? -1
        XCTAssertEqual(s.summary.compliancePct,
                       Self.round1(Double(pass) / Double(s.compliance.totalDevices) * 100),
                       "\(policy): summary proxy vs Compliance Posture Pass band")

        // The device rows agree with the summary counts here, so their gaps do too.
        for control in SecurityControl.allCases {
            let counts = fleet.controls[control]
            let gap = s.compliance.controlGaps.first { $0.control == Self.gapLabel(control) }
            if counts?.level == .ignore {
                XCTAssertNil(gap, "\(policy): \(control) is not counted")
                continue
            }
            XCTAssertEqual(gap?.failingDevices, counts?.fail, "\(policy): \(control) failing")
            XCTAssertEqual(gap?.warningDevices, counts?.warning, "\(policy): \(control) warnings")
        }
    }

    private static func gapLabel(_ control: SecurityControl) -> String {
        switch control {
        case .fileVault: "FileVault"
        case .sip: "SIP"
        case .firewall: "Firewall"
        case .gatekeeper: "Gatekeeper"
        }
    }

    /// Every computers record: a red Device Security State cell is a risk factor, an amber
    /// one is not, and the risk scorer finds no factor the sheet does not colour red.
    private func assertDevicesAgree(_ s: Surfaces, policy: String) throws {
        let columns: [(col: Int, factor: DeviceRisk.Factor)] = [
            (2, .noFileVault), (3, .sipDisabled), (4, .firewallDisabled),
            (5, .gatekeeperDisabled),
        ]
        for mac in Self.fleet where mac.appleSilicon != nil {
            let cells = try row(s, "Device Security State", mac.name)
            let factors = try XCTUnwrap(s.risk[mac.serial], "\(policy): no risk for \(mac.name)")
            for (col, factor) in columns {
                XCTAssertEqual(cells[col]?.format == .red, factors.contains(factor),
                               "\(policy): \(mac.name) \(factor) vs sheet column \(col)")
            }
            XCTAssertFalse(factors.contains(.bootstrapMissing), "\(policy): bootstrap escrowed")
        }
        XCTAssertNil(s.risk["FXTR0105AA"], "FXTR0105AA has no computers record")
    }

    /// The HTML tiles and the Compliance Posture sheet grade FileVault and Firewall alike, and
    /// the FileVault tile's note counts the Macs the posture services moved.
    private func assertGradesAgree(_ s: Surfaces, policy: String) throws {
        let sheetStatus = ["ok": "GREEN", "warn": "AMBER", "bad": "RED", "": "Not counted"]
        for (tileLabel, rowLabel) in [("FileVault", "FileVault Encrypted"),
                                       ("Firewall", "Firewall Enabled")] {
            let htmlClass = try tile(s, tileLabel).cssClass
            let status = try row(s, "Compliance Posture", rowLabel)[2]?.text
            XCTAssertEqual(sheetStatus[htmlClass], status,
                           "\(policy): \(tileLabel) tile vs Compliance Posture sheet")
        }
        let moved = s.posture.fleetCounts.fileVaultOffHardwareEncrypted
        let note = try tile(s, "FileVault").labels.dropFirst().first
        XCTAssertEqual(note, moved > 0 ? "\(moved) more hardware-encrypted, FileVault off" : nil,
                       "\(policy): FileVault tile note vs posture moved")
    }
}
