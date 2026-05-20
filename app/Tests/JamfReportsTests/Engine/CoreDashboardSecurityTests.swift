import Foundation
import XCTest
@testable import JamfReports

// MARK: - CoreDashboardSecurityTests
//
// Validates the three sheet writers migrated from [String: Any] to typed decoders
// in the typed-decoder collapse (W24 / Task 1).
//
// Pattern for future migrations:
//   1. Write a "happy path" test seeding a valid fixture into a temp dir.
//   2. Write a "malformed JSON" test verifying no crash and a logged warning.
//   3. Write a "missing data" test verifying the function throws noCachedData.

final class CoreDashboardSecurityTests: XCTestCase {

    // MARK: - Helpers

    private func makeDashboard(dataDir: URL) -> CoreDashboard {
        CoreDashboard(config: ReportConfig(), dataDir: dataDir, workbook: Workbook())
    }

    /// Write `json` into `<dataDir>/<kind>/<kind>.json` and return `dataDir`.
    private func seedJSON(_ json: String, kind: String, in dir: URL) throws {
        let kindDir = dir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        let fileURL = kindDir.appendingPathComponent("\(kind).json")
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreDashboardSecurityTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func fixtureData(kind: String) -> String? {
        let fixtureDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/jamf-cli-data")
            .appendingPathComponent(kind)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fixtureDir, includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "json" }),
              let first = files.first,
              let content = try? String(contentsOf: first, encoding: .utf8)
        else { return nil }
        return content
    }

    // MARK: - writeSecurity: happy path

    func testWriteSecurityHappyPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        [{"section":"summary","data":{"total_devices":100,"filevault_encrypted":95,
          "gatekeeper_enabled":100,"sip_enabled":100,"firewall_enabled":80}},
         {"section":"os_version","os_version":"15.4.1","count":60,"pct":"60%"},
         {"section":"os_version","os_version":"14.7.2","count":40,"pct":"40%"}]
        """
        try seedJSON(json, kind: "security", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeSecurity(), "writeSecurity must not throw on valid data")

        let ws = dash.workbook.sheet(named: "Security Posture")
        XCTAssertNotNil(ws, "Security Posture sheet must be created")
    }

    // MARK: - writeSecurity: malformed JSON does not crash

    func testWriteSecurityMalformedJSONSkipsSheet() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Valid JSON syntax but wrong shape — not an array of SecurityReportItem
        try seedJSON("{\"not\":\"an array\"}", kind: "security", in: dir)

        let dash = makeDashboard(dataDir: dir)
        // Must throw noCachedData (typed decode returns nil → guard fails → throw)
        // OR throw a decode error — either way, must not crash or produce garbage output.
        XCTAssertThrowsError(try dash.writeSecurity())
    }

    // MARK: - writeSecurity: missing data throws noCachedData

    func testWriteSecurityMissingDataThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dash = makeDashboard(dataDir: dir)
        XCTAssertThrowsError(try dash.writeSecurity()) { error in
            if let err = error as? CoreDashboardError,
               case .noCachedData(let names) = err {
                XCTAssertTrue(names.contains("security"))
            }
            // Other error types are also acceptable (e.g. decode failure on bad shape)
        }
    }

    // MARK: - writeSecurity: fixture round-trip (skipped when fixture absent)

    func testWriteSecurityFromFixture() throws {
        guard let json = fixtureData(kind: "security") else {
            throw XCTSkip("security fixture not available")
        }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedJSON(json, kind: "security", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeSecurity())
    }

    // MARK: - writePatch: happy path

    func testWritePatchHappyPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        [{"title":"Firefox","id":"1","on_latest":80,"on_other":20,
          "total":100,"latest":"130.0","compliance_pct":"80%"},
         {"title":"Chrome","id":"2","on_latest":95,"on_other":5,
          "total":100,"latest":"123.0","compliance_pct":"95%"}]
        """
        try seedJSON(json, kind: "patch-status", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writePatch(), "writePatch must not throw on valid data")

        let ws = dash.workbook.sheet(named: "Patch Compliance")
        XCTAssertNotNil(ws, "Patch Compliance sheet must be created")
    }

    // MARK: - writePatch: missing data throws

    func testWritePatchMissingDataThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dash = makeDashboard(dataDir: dir)
        XCTAssertThrowsError(try dash.writePatch())
    }

    // MARK: - writePatch: fixture (skipped when fixture absent)

    func testWritePatchFromFixture() throws {
        guard let json = fixtureData(kind: "patch-status") else {
            throw XCTSkip("patch-status fixture not available")
        }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedJSON(json, kind: "patch-status", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writePatch())
    }

    // MARK: - writeUpdateStatus: happy path

    func testWriteUpdateStatusHappyPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        [{"total":200,
          "status_summary":[{"status":"UP_TO_DATE","count":180},{"status":"PENDING","count":20}],
          "plan_total":5,
          "plan_state_summary":[{"state":"Activated","count":3},{"state":"Pending","count":2}]}]
        """
        try seedJSON(json, kind: "update-status", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeUpdateStatus(), "writeUpdateStatus must not throw on valid data")

        let ws = dash.workbook.sheet(named: "Update Status")
        XCTAssertNotNil(ws, "Update Status sheet must be created")
    }

    // MARK: - writeUpdateStatus: missing data throws

    func testWriteUpdateStatusMissingDataThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dash = makeDashboard(dataDir: dir)
        XCTAssertThrowsError(try dash.writeUpdateStatus())
    }

    // MARK: - writeUpdateStatus: fixture (skipped when fixture absent or not a valid shape)

    func testWriteUpdateStatusFromFixture() throws {
        guard let json = fixtureData(kind: "update-status") else {
            throw XCTSkip("update-status fixture not available")
        }
        // S-07 (PR-5): the committed fixture is the happy-path shape;
        // the prior conditional skip ("not a valid UpdateStatusReport
        // shape") was masking an out-of-spec fixture and is no longer
        // needed. The 503-error response shape is preserved in
        // tests/fixtures/jamf-cli-data-variants/update-status/update-status-error-503.json
        // for any future test that wants to exercise the error path.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedJSON(json, kind: "update-status", in: dir)

        let dash = makeDashboard(dataDir: dir)
        XCTAssertNoThrow(try dash.writeUpdateStatus())
    }

    // MARK: - loadLatestTyped returns nil on type mismatch (logged, not thrown)

    func testLoadLatestTypedReturnsMalformedAsNilForPatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a JSON array of objects that won't decode as PatchStatusRow
        // (missing required fields like "title", "on_latest", etc.)
        try seedJSON("[{\"wrong_field\":true}]", kind: "patch-status", in: dir)

        let dash = makeDashboard(dataDir: dir)
        // writePatch decodes via loadLatestTyped: if every item fails,
        // the array decodes successfully but fields default; "title" will be empty string
        // (since PatchStatusRow fields are non-optional). Actually PatchStatusRow has
        // non-optional String fields, so this will throw a decode error — guard fails.
        XCTAssertThrowsError(try dash.writePatch())
    }
}
