import Foundation
import XCTest
@testable import JamfReports

/// An organization's own on and off words (`security_policy.on_values` / `off_values`) reach
/// every surface that reads a device's value for a control: the Devices gap count and risk,
/// the CSV workbook's Security Controls sheet, Compliance Posture and the Device Security
/// State sheet. Without the words the same Macs read as not measured.
final class SecurityValueVocabularySurfacesTests: XCTestCase {

    nonisolated(unsafe) private var testRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testRoot = GoldenFleetWorkspace.freshRoot()
    }

    override func tearDownWithError() throws {
        if let dir = testRoot { try? FileManager.default.removeItem(at: dir) }
        testRoot = nil
        try super.tearDownWithError()
    }

    private let orgWords = ["Pass", "Fail", "Non-Compliant", "Compliant"]

    private func vocabulary(for control: SecurityControl) -> SecurityControlPolicy {
        SecurityControlPolicy(
            onValues: [control: ["Pass", "Compliant"]],
            offValues: [control: ["Fail", "Non-Compliant"]])
    }

    // MARK: - A CSV export with an organization's firewall column

    /// Checked in today, so no Mac is stale or ages into a risk of its own.
    private static let csv: String = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let seen = formatter.string(from: Date())
        let header = "Computer Name,Serial Number,Last Check-in,FileVault Status,"
            + "System Integrity Protection,Firewall,Gatekeeper"
        let macs = [("01", "Pass"), ("02", "Fail"), ("03", "Non-Compliant"), ("04", "Compliant")]
        return ([header] + macs.map {
            "Lab-Mac-\($0.0),FXTR02\($0.0)AA,\(seen),Encrypted,Enabled,\($0.1),APP_STORE"
        }).joined(separator: "\n")
    }()

    private func csvRecords() throws -> [DeviceInventoryRecord] {
        let (_, rows) = try CSVParser.parse(Data(Self.csv.utf8))
        return rows.map { DeviceInventoryService.recordFromCSV($0, source: "fleet.csv") }
    }

    /// The Security Controls sheet's Firewall row: compliant, non-compliant, unknown.
    private func firewallRow(_ policy: SecurityControlPolicy) throws -> [String] {
        var columns = ColumnConfig()
        columns.computerName = "Computer Name"
        columns.lastCheckin = "Last Check-in"
        columns.filevault = "FileVault Status"
        columns.sip = "System Integrity Protection"
        columns.firewall = "Firewall"
        columns.gatekeeper = "Gatekeeper"
        var config = ReportConfig()
        config.columns = columns
        config.securityPolicy = policy
        var thresholds = ThresholdsConfig()
        thresholds.staleDeviceDays = 36500
        config.thresholds = thresholds
        let workbook = Workbook()
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: Data(Self.csv.utf8), workbook: workbook))
        dashboard.writeSecurityControls()
        let cells = try XCTUnwrap(workbook.sheet(named: "Security Controls")).dedupedCells
        let label = try XCTUnwrap(cells.first { $0.col == 0 && Self.text($0.value) == "Firewall" })
        return (1...3).map { col in
            cells.first { $0.row == label.row && $0.col == col }.map { Self.text($0.value) } ?? "?"
        }
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

    func testTheOrganizationsFirewallWordsCountOnDevicesAndTheCSVWorkbook() throws {
        let policy = vocabulary(for: .firewall)
        let records = try csvRecords()
        XCTAssertEqual(records.map(\.firewall), ["Pass", "Fail", "Non-Compliant", "Compliant"])

        XCTAssertEqual(records.map { $0.securityGapCount(policy: policy) }, [0, 1, 1, 0])
        XCTAssertEqual(records.map { $0.risk(policy: policy) },
                       [.ok, .attention, .attention, .ok])
        let snapshot = DeviceInventorySnapshot(
            devices: records, patchTitles: [], sourceFiles: [], warnings: [],
            generatedAt: "", generatedDate: nil, isDemo: false, securityPolicy: policy)
        XCTAssertEqual(snapshot.securityGapCount, 2)
        XCTAssertEqual(try firewallRow(policy), ["2", "2", "0"])
    }

    func testWithoutTheWordsTheSameMacsReadAsNotMeasured() throws {
        let records = try csvRecords()
        XCTAssertEqual(records.map { $0.securityGapCount(policy: .default) }, [0, 0, 0, 0])
        XCTAssertEqual(try firewallRow(.default), ["0", "0", "4"])
    }

    /// The words belong to the control they are listed under.
    func testTheFirewallWordsDoNotReadAnotherControl() throws {
        let policy = vocabulary(for: .sip)
        XCTAssertEqual(try csvRecords().map { $0.securityGapCount(policy: policy) }, [0, 0, 0, 0])
        XCTAssertEqual(try firewallRow(policy), ["0", "0", "4"])
    }

    // MARK: - A jamf-cli fleet with an organization's Gatekeeper column

    private func gatekeeperFleet() throws -> (securityReport: URL, dataDir: URL) {
        let dataDir = testRoot.appendingPathComponent("jamf-cli-data", isDirectory: true)
        let now = Date()
        // jamf-cli's own summary says 3 of 4 Gatekeepers are on; its fixed vocabulary does
        // not know the organization's words, so the rows below disagree with it on purpose.
        var report = GoldenFleetWorkspace.securitySummaryPayload(
            total: 4, filevault: 4, sip: 4, firewall: 4, gatekeeper: 3)
        var computers: [[String: Any]] = []
        for (index, word) in orgWords.enumerated() {
            let serial = "FXTR030\(index)AA", name = "Lab-Mac-0\(index)"
            report.append(GoldenFleetWorkspace.securityDeviceRow(
                name: name, serial: serial, osVersion: "15.4.1", fileVault: "ENCRYPTED",
                sip: "ENABLED", firewall: true, gatekeeper: word))
            computers.append(GoldenFleetWorkspace.computerRow(
                name: name, serial: serial, appleSilicon: true, modelIdentifier: "Mac14,2",
                fileVault: "ENCRYPTED", sip: "ENABLED", firewall: true, gatekeeper: word))
        }
        let securityReport = try GoldenFleetWorkspace.writeSnapshot(
            kind: "security", dataDir: dataDir, at: now, rows: report)
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "computers", dataDir: dataDir, at: now, rows: computers)
        return (securityReport, dataDir)
    }

    func testTheOrganizationsGatekeeperWordsCountOnCompliancePosture() throws {
        let fleet = try gatekeeperFleet()
        let policy = vocabulary(for: .gatekeeper)

        let withWords = try XCTUnwrap(CompliancePostureService.load(
            from: fleet.securityReport, policy: policy, hardware: [:]))
        XCTAssertEqual(withWords.controlGaps.first { $0.control == "Gatekeeper" }?.failingDevices,
                       2)
        XCTAssertEqual(withWords.bands.first { $0.label == "Pass" }?.count, 2)

        let without = try XCTUnwrap(CompliancePostureService.load(
            from: fleet.securityReport, policy: .default, hardware: [:]))
        XCTAssertEqual(without.controlGaps.first { $0.control == "Gatekeeper" }?.failingDevices, 0)
        XCTAssertEqual(without.bands.first { $0.label == "Pass" }?.count, 4)
    }

    func testTheOrganizationsGatekeeperWordsCountOnDevicesAndTheSecurityStateSheet() throws {
        let fleet = try gatekeeperFleet()
        let policy = vocabulary(for: .gatekeeper)

        let computersURL = try XCTUnwrap(FileManager.newestJSONFile(
            in: fleet.dataDir.appendingPathComponent("computers", isDirectory: true)))
        let items = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: computersURL)) as? [[String: Any]])
        let records = items.map {
            DeviceInventoryService.recordFromComputer($0, source: "jamf-cli")
        }
        XCTAssertEqual(records.map { $0.securityGapCount(policy: policy) }, [0, 1, 1, 0])
        XCTAssertEqual(records.map { $0.securityGapCount(policy: .default) }, [0, 0, 0, 0])

        func gatekeeperFormats(_ policy: SecurityControlPolicy) throws -> [CellFormat?] {
            var config = ReportConfig()
            config.securityPolicy = policy
            let dashboard = CoreDashboard(
                config: config, dataDir: fleet.dataDir, workbook: Workbook())
            try dashboard.writeDeviceSecurityState()
            let cells = try XCTUnwrap(dashboard.workbook.sheet(named: "Device Security State"))
                .dedupedCells
            return (0..<4).map { index in
                let name = "Lab-Mac-0\(index)"
                let row = cells.first { $0.col == 0 && Self.text($0.value) == name }?.row
                return cells.first { $0.row == row && $0.col == 5 }?.format
            }
        }
        XCTAssertEqual(try gatekeeperFormats(policy), [.green, .red, .red, .green])
        XCTAssertEqual(try gatekeeperFormats(.default), [.cell, .cell, .cell, .cell])
    }

    /// The vocabulary reads each device's value. The counts jamf-cli's summary carries come
    /// from jamf-cli's own vocabulary, and the Security Posture screen starts from them.
    func testTheSummaryCountsStayJamfCLIs() throws {
        let fleet = try gatekeeperFleet()
        let snapshot = try SecurityPostureService.load(
            from: fleet.securityReport, policy: vocabulary(for: .gatekeeper), hardware: [:])
        XCTAssertEqual(snapshot.fleetCounts.controls[.gatekeeper]?.on, 3)
        XCTAssertEqual(snapshot.fleetCounts.p1, 1)
    }
}
