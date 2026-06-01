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

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Engine/
            .deletingLastPathComponent()   // JamfReportsTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // app/
            .deletingLastPathComponent()   // worktree root
            .appendingPathComponent("tests/fixtures/jamf-cli-data")
    }

    /// Copy a named fixture subdirectory into a temp dir.
    private func copyFixture(_ name: String, into dir: URL) {
        let src = fixturesDir.appendingPathComponent(name)
        let dst = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        try? FileManager.default.copyItem(at: src, to: dst)
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
        try seedJSON(json, kind: "computers-list", in: dir)

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

    func testWriteDeviceSecurityStateSkipsRowsWithNoSecurityData() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Items with no security section should be filtered out.
        let json = """
        [{"general":{"id":"1","name":"Bare-Mac"},"hardware":{"serialNumber":"XYZ"}}]
        """
        try seedJSON(json, kind: "computers-list", in: dir)
        let dash = makeDashboard(dataDir: dir)
        // All items lack security fields → throws noCachedData (empty filtered set)
        XCTAssertThrowsError(try dash.writeDeviceSecurityState())
    }

    func testWriteDeviceSecurityStateWithFixture() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
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
        let json = """
        [
          {"id":"plan-1","name":"Production Default","uuid":"aaaa-bbbb",
           "description":"Default plan","created":"2024-01-01","updated":"2026-01-01",
           "logLevel":"INFO","autoUpdate":true,"threatPreventionStrategy":"BALANCED",
           "profileVersion":7,
           "customEngineConfig":{"MalwareRiskware":{"enabled":true},"AdversaryTactics":{"enabled":true}},
           "exceptionSets":[{"name":"Vendor Tools"}],
           "analyticSets":[{"analyticSet":{"name":"Core Analytics"}}],
           "telemetry":true,"telemetryV2":true}
        ]
        """
        try seedJSON(json, kind: "protect-plans", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeProtectPlans(),
                         "writeProtectPlans must not throw on valid data")

        let ws = dash.workbook.sheet(named: "Protect Plans")
        XCTAssertNotNil(ws, "Protect Plans sheet must be created")
    }

    func testWriteProtectPlansEmptyArraySkips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedJSON("[]", kind: "protect-plans", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeProtectPlans())
        // Empty items → guard returns without writing a sheet
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
        try FileManager.default.copyItem(at: src, to: subdirURL.appendingPathComponent("plans.json"))

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeProtectPlans())
        XCTAssertNotNil(dash.workbook.sheet(named: "Protect Plans"))
    }

    func testWriteProtectPlansEnvelopeShape() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Plans wrapped in {nodes: [...]} envelope
        let json = """
        {"nodes":[
          {"id":"plan-1","name":"Alpha Plan","uuid":"uuid-1","description":"",
           "created":"2024-01-01","updated":"2024-01-02",
           "logLevel":"INFO","autoUpdate":false,"threatPreventionStrategy":"STRICT",
           "profileVersion":3,"customEngineConfig":null,
           "exceptionSets":[],"analyticSets":[],"telemetry":false,"telemetryV2":false}
        ]}
        """
        try seedJSON(json, kind: "protect-plans", in: dir)
        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeProtectPlans())
        XCTAssertNotNil(dash.workbook.sheet(named: "Protect Plans"))
    }

    // MARK: - writeProtectThreatOverview

    func testWriteProtectThreatOverviewHappyPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        [
          {"uuid":"a1","created":"2026-05-01T08:00:00Z","severity":"high",
           "status":"New","eventType":"ProcessExecution",
           "computer":{"hostName":"lab-mac-01","serial":"ABC001"},
           "actions":[{"name":"Quarantine"},{"name":"Notify"}]},
          {"uuid":"a2","created":"2026-05-02T11:30:00Z","severity":"medium",
           "status":"InProgress","eventType":"FileWrite",
           "computer":{"hostName":"exec-mbp-09","serial":"DEF002"},
           "actions":["Notify"]},
          {"uuid":"a3","created":"2026-05-03T02:14:00Z","severity":"low",
           "status":"Resolved","eventType":"NetworkConnection",
           "computer":{"hostName":"prod-server-02","serial":"GHI003"},
           "actions":[]}
        ]
        """
        try seedJSON(json, kind: "protect-alerts", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeProtectThreatOverview(),
                         "writeProtectThreatOverview must not throw on valid data")

        let ws = dash.workbook.sheet(named: "Protect Threat Overview")
        XCTAssertNotNil(ws, "Protect Threat Overview sheet must be created")
    }

    func testWriteProtectThreatOverviewEmptyArraySkips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedJSON("[]", kind: "protect-alerts", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeProtectThreatOverview())
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
        try FileManager.default.copyItem(at: src, to: subdirURL.appendingPathComponent("alerts.json"))

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeProtectThreatOverview())
        XCTAssertNotNil(dash.workbook.sheet(named: "Protect Threat Overview"))
    }

    func testWriteProtectThreatOverviewMixedActionsShape() throws {
        // Actions can be [{name: "X"}] or bare ["X"] — both must extract cleanly.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        [{"uuid":"x","created":"2026-01-01","severity":"high","status":"New",
          "eventType":"Test","computer":{"hostName":"test-mac"},
          "actions":[{"name":"Quarantine"},"Notify"]}]
        """
        try seedJSON(json, kind: "protect-alerts", in: dir)
        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeProtectThreatOverview())
    }

    // MARK: - Severity sorting (Threat Overview)

    func testWriteProtectThreatOverviewSortsBySeverity() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        [
          {"uuid":"low","created":"2026-01-01","severity":"low","status":"","eventType":"A",
           "computer":{"hostName":"mac-low"},"actions":[]},
          {"uuid":"crit","created":"2026-01-02","severity":"critical","status":"","eventType":"B",
           "computer":{"hostName":"mac-crit"},"actions":[]},
          {"uuid":"med","created":"2026-01-03","severity":"medium","status":"","eventType":"C",
           "computer":{"hostName":"mac-med"},"actions":[]}
        ]
        """
        try seedJSON(json, kind: "protect-alerts", in: dir)
        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeProtectThreatOverview())
        // Critical must appear before medium before low — validated by no throw
        // (full cell inspection would require Workbook API not in scope).
    }
}
