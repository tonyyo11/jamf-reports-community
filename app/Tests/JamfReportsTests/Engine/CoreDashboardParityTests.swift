import Foundation
import XCTest
@testable import JamfReports

// MARK: - CoreDashboardParityTests
//
// Tests for the 5 parity sheet writers added in the HTML/trends branch:
//   - writePatchSummaryDashboard
//   - writeDeviceSecurityState
//   - writeMobileSupervisionStatus
//   - writeProtectPlans
//   - writeProtectThreatOverview
//
// Each test: happy path (fixture data), empty/missing snapshot, sheet registered
// in sheetPlan.

final class CoreDashboardParityTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreDashboardParityTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeDashboard(dataDir: URL) -> CoreDashboard {
        CoreDashboard(config: ReportConfig(), dataDir: dataDir, workbook: Workbook())
    }

    /// Seed a JSON string into `<dir>/<kind>/<kind>.json`.
    private func seedJSON(_ json: String, kind: String, in dir: URL) throws {
        let kindDir = dir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        let fileURL = kindDir.appendingPathComponent("\(kind).json")
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private var fixturesDir: URL { TestFixtures.dir("jamf-cli-data") }

    /// Copy a named fixture subdirectory into a temp dir.
    private func copyFixture(_ name: String, into dir: URL) {
        let src = fixturesDir.appendingPathComponent(name)
        let dst = dir.appendingPathComponent(name)
        try? TestFixtures.copyDir(src, to: dst)
    }

    // MARK: - sheetPlan registration

    func testAllParitySheetsRegisteredInPlan() {
        let dashboard = makeDashboard(dataDir: FileManager.default.temporaryDirectory)
        let names = Set(dashboard.sheetPlan.map { $0.name })
        let expected = [
            "Patch Summary Dashboard",
            "Device Security State",
            "Mobile Supervision Status",
            "Protect Plans",
            "Protect Threat Overview",
        ]
        for name in expected {
            XCTAssertTrue(names.contains(name),
                          "sheetPlan must include '\(name)'")
        }
    }

    // MARK: - writePatchSummaryDashboard

    func testWritePatchSummaryDashboardHappyPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let patchJSON = """
        [
          {"title":"Firefox","id":"1","on_latest":80,"on_other":10,"total":90,
           "latest":"130.0","compliance_pct":"89%"},
          {"title":"Zoom","id":"2","on_latest":45,"on_other":55,"total":100,
           "latest":"6.0","compliance_pct":"45%"},
          {"title":"Chrome","id":"3","on_latest":95,"on_other":0,"total":95,
           "latest":"124","compliance_pct":"100%"}
        ]
        """
        let dcJSON = """
        [
          {"name":"Mac-01","serial":"ABC001","managed":true,"stale":false},
          {"name":"Mac-02","serial":"ABC002","managed":true,"stale":true},
          {"name":"Mac-03","serial":"ABC003","managed":true,"stale":false}
        ]
        """
        try seedJSON(patchJSON, kind: "patch-status", in: dir)
        try seedJSON(dcJSON, kind: "device-compliance", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writePatchSummaryDashboard(),
                         "writePatchSummaryDashboard must not throw on valid data")

        let ws = dash.workbook.sheet(named: "Patch Summary Dashboard")
        XCTAssertNotNil(ws, "Patch Summary Dashboard sheet must be created")
    }

    func testWritePatchSummaryDashboardMissingPatchThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // No patch-status fixture seeded.
        let dash = makeDashboard(dataDir: dir)
        XCTAssertThrowsError(try dash.writePatchSummaryDashboard()) { error in
            guard case CoreDashboardError.noCachedData = error else {
                XCTFail("Expected CoreDashboardError.noCachedData, got \(error)")
                return
            }
        }
    }

    func testWritePatchSummaryDashboardMissingDeviceComplianceThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let patchJSON = """
        [{"title":"Firefox","id":"1","on_latest":80,"on_other":10,"total":90,
          "latest":"130.0","compliance_pct":"89%"}]
        """
        try seedJSON(patchJSON, kind: "patch-status", in: dir)
        // No device-compliance seeded.
        let dash = makeDashboard(dataDir: dir)
        XCTAssertThrowsError(try dash.writePatchSummaryDashboard()) { error in
            guard case CoreDashboardError.noCachedData = error else {
                XCTFail("Expected CoreDashboardError.noCachedData, got \(error)")
                return
            }
        }
    }

    func testWritePatchSummaryDashboardCorruptDeviceComplianceFails() throws {
        // A corrupt (non-JSON) device-compliance snapshot must surface as a failure
        // ("[fail]"), not a skip ("[skip] no cached data"). Regression for Item 3.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let patchJSON = """
        [{"title":"Firefox","id":"1","on_latest":80,"on_other":10,"total":90,
          "latest":"130.0","compliance_pct":"89%"}]
        """
        try seedJSON(patchJSON, kind: "patch-status", in: dir)
        // Seed a corrupt (non-JSON) bytes file for device-compliance.
        let dcDir = dir.appendingPathComponent("device-compliance", isDirectory: true)
        try FileManager.default.createDirectory(at: dcDir, withIntermediateDirectories: true)
        try "NOT VALID JSON {{{".write(
            to: dcDir.appendingPathComponent("device-compliance.json"),
            atomically: true, encoding: .utf8
        )

        let dash = makeDashboard(dataDir: dir)
        XCTAssertThrowsError(try dash.writePatchSummaryDashboard()) { error in
            XCTAssertFalse(error is SheetSkippable,
                           "Corrupt cache must route to [fail], not [skip]; got: \(error)")
        }
    }

    func testWritePatchSummaryDashboardWithFixture() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        copyFixture("patch-status", into: dir)
        copyFixture("device-compliance", into: dir)
        guard FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("patch-status").path),
              FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("device-compliance").path)
        else { throw XCTSkip("fixtures not available") }

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writePatchSummaryDashboard())
    }

    // MARK: - writeDeviceSecurityState

    func testWriteDeviceSecurityStateHappyPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        [
          {"general":{"id":"101","name":"Lab-Mac-01"},
           "hardware":{"serialNumber":"ABC1010001"},
           "diskEncryption":{"fileVault2Enabled":true,
             "bootPartitionEncryptionDetails":{"partitionFileVault2State":"ENCRYPTED"}},
           "security":{"sipStatus":"ENABLED","firewallEnabled":true,
             "gatekeeperStatus":"APP_STORE_AND_IDENTIFIED_DEVELOPERS",
             "bootstrapTokenEscrowed":true}},
          {"general":{"id":"102","name":"Lab-Mac-02"},
           "hardware":{"serialNumber":"ABC1020002"},
           "diskEncryption":{"fileVault2Enabled":false,
             "bootPartitionEncryptionDetails":{"partitionFileVault2State":"UNENCRYPTED"}},
           "security":{"sipStatus":"DISABLED","firewallEnabled":false,
             "gatekeeperStatus":"DISABLED","bootstrapTokenEscrowed":false}}
        ]
        """
        try seedJSON(json, kind: "computers", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeDeviceSecurityState(),
                         "writeDeviceSecurityState must not throw on valid data")

        let ws = dash.workbook.sheet(named: "Device Security State")
        XCTAssertNotNil(ws, "Device Security State sheet must be created")
    }

    func testWriteDeviceSecurityStateMissingDataThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dash = makeDashboard(dataDir: dir)
        XCTAssertThrowsError(try dash.writeDeviceSecurityState()) { error in
            guard case CoreDashboardError.noCachedData = error else {
                XCTFail("Expected CoreDashboardError.noCachedData, got \(error)")
                return
            }
        }
    }

    func testWriteDeviceSecurityStateCorruptSnapshotFails() throws {
        // A corrupt (non-JSON) computers snapshot must surface as a failure
        // ("[fail]"), not a skip ("[skip] no cached data"). Regression for Item 3.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let computersDir = dir.appendingPathComponent("computers", isDirectory: true)
        try FileManager.default.createDirectory(at: computersDir, withIntermediateDirectories: true)
        try "NOT VALID JSON {{{".write(
            to: computersDir.appendingPathComponent("computers.json"),
            atomically: true, encoding: .utf8
        )

        let dash = makeDashboard(dataDir: dir)
        XCTAssertThrowsError(try dash.writeDeviceSecurityState()) { error in
            XCTAssertFalse(error is SheetSkippable,
                           "Corrupt cache must route to [fail], not [skip]; got: \(error)")
        }
    }

    func testWriteDeviceSecurityStateSkipsRowsWithNoSecurityData() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Items with no security section should be filtered out.
        let json = """
        [{"general":{"id":"1","name":"Bare-Mac"},"hardware":{"serialNumber":"XYZ"}}]
        """
        try seedJSON(json, kind: "computers", in: dir)
        let dash = makeDashboard(dataDir: dir)
        // All items lack security fields → throws noCachedData (empty filtered set)
        XCTAssertThrowsError(try dash.writeDeviceSecurityState())
    }

    func testWriteDeviceSecurityStateWithFixture() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // "computers-list" is the on-disk fixture name; it is in the fallback list
        // ["computers", "computers-list", "computers_list"] so the reader finds it.
        copyFixture("computers-list", into: dir)
        guard FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("computers-list").path)
        else { throw XCTSkip("computers-list fixture not available") }
        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeDeviceSecurityState())
    }

    // MARK: - writeMobileSupervisionStatus

    func testWriteMobileSupervisionStatusHappyPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        [
          {"mobileDeviceId":"1","general":{"displayName":"iPad-01","model":"iPad Pro",
            "managed":true,"supervised":true}},
          {"mobileDeviceId":"2","general":{"displayName":"iPhone-01","model":"iPhone 15",
            "managed":true,"supervised":false}},
          {"mobileDeviceId":"3","general":{"displayName":"iPad-02","model":"iPad Air",
            "managed":true,"supervised":true}}
        ]
        """
        try seedJSON(json, kind: "mobile-device-inventory-details", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeMobileSupervisionStatus(),
                         "writeMobileSupervisionStatus must not throw on valid data")

        let ws = dash.workbook.sheet(named: "Mobile Supervision Status")
        XCTAssertNotNil(ws, "Mobile Supervision Status sheet must be created")
    }

    func testWriteMobileSupervisionStatusMissingDataThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dash = makeDashboard(dataDir: dir)
        XCTAssertThrowsError(try dash.writeMobileSupervisionStatus()) { error in
            guard case CoreDashboardError.noCachedData = error else {
                XCTFail("Expected CoreDashboardError.noCachedData, got \(error)")
                return
            }
        }
    }

    func testWriteMobileSupervisionStatusWithFixture() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        copyFixture("mobile-device-inventory-details", into: dir)
        guard FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("mobile-device-inventory-details").path)
        else { throw XCTSkip("mobile-device-inventory-details fixture not available") }
        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeMobileSupervisionStatus())
    }

    // MARK: - writeProtectPlans

    func testWriteProtectPlansHappyPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // flattenPlan rows: reference columns are names and absent when nothing is assigned.
        let json = """
        [
          {"actionConfig":"Default Actions","autoUpdate":true,"logLevel":"INFO",
           "name":"Production Default","telemetry":"Standard Telemetry",
           "unifiedLoggingFilterSets":"Authentication, Screen Sharing",
           "usbControlSet":"Block External Storage"},
          {"actionConfig":"Default Actions","autoUpdate":false,"logLevel":"DEBUG",
           "name":"Engineering Lab","unifiedLoggingFilterSets":""}
        ]
        """
        try seedJSON(json, kind: "protect-plans", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeProtectPlans(),
                         "writeProtectPlans must not throw on valid data")

        let ws = try XCTUnwrap(dash.workbook.sheet(named: "Protect Plans"),
                               "Protect Plans sheet must be created")
        XCTAssertEqual(rowText(ws, row: 3, columns: 7), [
            "Plan Name", "Log Level", "Auto Update", "Action Configuration", "Telemetry",
            "USB Control Set", "Unified Logging Filter Sets",
        ])
        // Rows sort by name, so Engineering Lab comes first.
        XCTAssertEqual(rowText(ws, row: 4, columns: 7),
                       ["Engineering Lab", "DEBUG", "No", "Default Actions", "", "", ""])
        XCTAssertEqual(rowText(ws, row: 5, columns: 7), [
            "Production Default", "INFO", "Yes", "Default Actions", "Standard Telemetry",
            "Block External Storage", "Authentication, Screen Sharing",
        ])
    }

    func testWriteProtectPlansEmptyArrayThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedJSON("[]", kind: "protect-plans", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertThrowsError(try dash.writeProtectPlans()) { error in
            guard case CoreDashboardError.noCachedData = error else {
                XCTFail("Expected CoreDashboardError.noCachedData for empty protect-plans, got \(error)")
                return
            }
        }
        XCTAssertNil(dash.workbook.sheet(named: "Protect Plans"),
                     "Empty protect-plans must not create a sheet")
    }

    func testWriteProtectPlansMissingSnapshotThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dash = makeDashboard(dataDir: dir)
        XCTAssertThrowsError(try dash.writeProtectPlans())
    }

    func testWriteProtectPlansWithFixture() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Use the happy fixture (seed by name so only it is present)
        let src = fixturesDir.appendingPathComponent("protect-plans/plans_happy.json")
        guard FileManager.default.fileExists(atPath: src.path)
        else { throw XCTSkip("plans_happy.json fixture not available") }
        let subdirURL = dir.appendingPathComponent("protect-plans", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
        try TestFixtures.copyFile(src, to: subdirURL.appendingPathComponent("plans.json"))

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeProtectPlans())
        let ws = try XCTUnwrap(dash.workbook.sheet(named: "Protect Plans"))
        XCTAssertEqual(rowText(ws, row: 4, columns: 7),
                       ["Engineering Lab", "DEBUG", "No", "Default Actions", "", "", ""])
    }

    // MARK: - writeProtectThreatOverview

    func testWriteProtectThreatOverviewHappyPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // flattenAlert rows: `computer` is the host name, `analytics` the analytics' names.
        let json = """
        [
          {"analytics":"Suspicious Process","computer":"lab-mac-01.example",
           "created":"2026-05-01T08:00:00.000Z","eventType":"GPProcessEvent",
           "received":"2026-05-01T08:00:01.000Z","severity":"High","status":"New","uuid":"a1"},
          {"analytics":"Document Drop","computer":"exec-mbp-09.example",
           "created":"2026-05-02T11:30:00.000Z","eventType":"GPFSEvent",
           "received":"2026-05-02T11:30:02.000Z","severity":"Medium","status":"InProgress",
           "uuid":"a2"},
          {"computer":"build-mini-02.example","created":"2026-05-03T02:14:00.000Z",
           "eventType":"GPUSBEvent","received":"2026-05-03T02:14:05.000Z","severity":"Low",
           "status":"Resolved","uuid":"a3"}
        ]
        """
        try seedJSON(json, kind: "protect-alerts", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeProtectThreatOverview(),
                         "writeProtectThreatOverview must not throw on valid data")

        let ws = try XCTUnwrap(dash.workbook.sheet(named: "Protect Threat Overview"),
                               "Protect Threat Overview sheet must be created")
        XCTAssertEqual(rowText(ws, row: 3, columns: 6),
                       ["Device", "Type", "Severity", "Date", "Status", "Analytics"])
        XCTAssertEqual(rowText(ws, row: 4, columns: 6), [
            "lab-mac-01.example", "GPProcessEvent", "High", "2026-05-01T08:00:00.000Z", "New",
            "Suspicious Process",
        ])
        XCTAssertEqual(rowText(ws, row: 6, columns: 6)[5], "", "the Low alert has no analytics")
    }

    func testWriteProtectThreatOverviewEmptyArrayThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedJSON("[]", kind: "protect-alerts", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertThrowsError(try dash.writeProtectThreatOverview()) { error in
            guard case CoreDashboardError.noCachedData = error else {
                XCTFail("Expected CoreDashboardError.noCachedData for empty protect-alerts, got \(error)")
                return
            }
        }
        XCTAssertNil(dash.workbook.sheet(named: "Protect Threat Overview"),
                     "Empty protect-alerts must not create a sheet")
    }

    func testWriteProtectThreatOverviewMissingSnapshotThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dash = makeDashboard(dataDir: dir)
        XCTAssertThrowsError(try dash.writeProtectThreatOverview())
    }

    func testWriteProtectThreatOverviewWithFixture() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = fixturesDir.appendingPathComponent("protect-alerts/alerts_happy.json")
        guard FileManager.default.fileExists(atPath: src.path)
        else { throw XCTSkip("alerts_happy.json fixture not available") }
        let subdirURL = dir.appendingPathComponent("protect-alerts", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
        try TestFixtures.copyFile(src, to: subdirURL.appendingPathComponent("alerts.json"))

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeProtectThreatOverview())
        let ws = try XCTUnwrap(dash.workbook.sheet(named: "Protect Threat Overview"))
        // The fixture's Informational alert has no computer, so its Device cell is empty.
        XCTAssertEqual(rowText(ws, row: 7, columns: 6), [
            "", "GPGatekeeperEvent", "Informational", "2026-05-04T09:45:00.000Z",
            "AutoResolved", "Gatekeeper Override",
        ])
    }

    // MARK: - Severity sorting (Threat Overview)

    func testWriteProtectThreatOverviewSortsBySeverity() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        [
          {"computer":"mac-low.example","created":"2026-01-01T00:00:00.000Z",
           "eventType":"GPFSEvent","received":"2026-01-01T00:00:01.000Z","severity":"Low",
           "status":"New","uuid":"low"},
          {"computer":"mac-high.example","created":"2026-01-02T00:00:00.000Z",
           "eventType":"GPProcessEvent","received":"2026-01-02T00:00:01.000Z",
           "severity":"High","status":"New","uuid":"high"},
          {"computer":"mac-medium.example","created":"2026-01-03T00:00:00.000Z",
           "eventType":"GPUSBEvent","received":"2026-01-03T00:00:01.000Z",
           "severity":"Medium","status":"New","uuid":"medium"}
        ]
        """
        try seedJSON(json, kind: "protect-alerts", in: dir)
        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeProtectThreatOverview())
        let ws = try XCTUnwrap(dash.workbook.sheet(named: "Protect Threat Overview"))
        let devices = (4...6).map { rowText(ws, row: $0, columns: 1)[0] }
        XCTAssertEqual(devices, ["mac-high.example", "mac-medium.example", "mac-low.example"])
    }

    // MARK: - Cell text

    /// Text of one sheet row: strings as written, integers in decimal, "" for anything else.
    private func rowText(_ ws: Worksheet, row: Int, columns: Int) -> [String] {
        var text = Array(repeating: "", count: columns)
        for cell in ws.dedupedCells where cell.row == row && cell.col < columns {
            switch cell.value {
            case .string(let value): text[cell.col] = value
            case .int(let value): text[cell.col] = String(value)
            default: break
            }
        }
        return text
    }
}
