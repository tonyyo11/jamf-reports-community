import XCTest
@testable import JamfReports

/// `signaturesVersion` and `lastDisconnectionReason` on Protect computers. Identifiers are
/// placeholders; the key names and value shapes are jamf-cli's flattened rows.
final class ProtectSignaturesTests: XCTestCase {

    private func decode(_ json: String) throws -> [ProtectComputerRow] {
        try JSONDecoder().decode([ProtectComputerRow].self, from: Data(json.utf8))
    }

    func testReadsBothFields() throws {
        let rows = try decode("""
        [{"hostname":"mac-a","signaturesVersion":21999,
          "lastDisconnectionReason":"MQTT_KEEP_ALIVE_TIMEOUT"},
         {"hostname":"mac-b","signaturesVersion":22003.0}]
        """)
        XCTAssertEqual(rows[0].signaturesVersion, 21_999)
        XCTAssertEqual(rows[0].signaturesVersionText, "21999")
        XCTAssertEqual(rows[0].lastDisconnectionReason, "MQTT_KEEP_ALIVE_TIMEOUT")
        XCTAssertEqual(rows[1].signaturesVersion, 22_003)
        XCTAssertNil(rows[1].lastDisconnectionReason)
    }

    func testWrongTypesCostTheFieldNotTheRow() throws {
        let rows = try decode("""
        [{"hostname":"mac-a","signaturesVersion":"22003","lastDisconnectionReason":7,
          "plan":"Lab"},{"hostname":"mac-b","signaturesVersion":null}]
        """)
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(rows[0].signaturesVersion)
        XCTAssertNil(rows[0].signaturesVersionText)
        XCTAssertNil(rows[0].lastDisconnectionReason)
        XCTAssertEqual(rows[0].planName, "Lab")
        XCTAssertEqual(rows[0].hostName, "mac-a")
        XCTAssertNil(rows[1].signaturesVersion)
    }

    func testLagCountsMacsBelowTheNewestOverTheMacsThatReport() throws {
        let rows = try decode("""
        [{"signaturesVersion":22003},{"signaturesVersion":21999},{"signaturesVersion":21999},
         {"hostname":"reports-none"}]
        """)
        let lag = try XCTUnwrap(ProtectComputerRow.signatureLag(rows))
        XCTAssertEqual(lag.behind, 2)
        XCTAssertEqual(lag.reporting, 3)
    }

    func testNoLagLineWithFewerThanTwoDistinctVersionsOrNone() throws {
        XCTAssertNil(ProtectComputerRow.signatureLag([]))
        XCTAssertNil(ProtectComputerRow.signatureLag(
            try decode(#"[{"hostname":"a"},{"hostname":"b"}]"#)))
        XCTAssertNil(ProtectComputerRow.signatureLag(
            try decode(#"[{"signaturesVersion":5},{"signaturesVersion":5}]"#)))
    }

    func testTheWorkbookTabEndsWithBothColumns() throws {
        let root = GoldenFleetWorkspace.freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "protect-computers", dataDir: dataDir, at: GoldenFleetClock.anchorNoon(),
            rows: [["hostname": "mac-a", "serial": "SER1", "signaturesVersion": 21_999,
                    "lastDisconnectionReason": "MQTT_KEEP_ALIVE_TIMEOUT"],
                   ["hostname": "mac-b", "serial": "SER2"]])
        let dash = CoreDashboard(
            config: ReportConfig(), dataDir: dataDir, workbook: Workbook())
        try dash.writeProtectComputers()
        let cells = try XCTUnwrap(dash.workbook.sheet(named: "Protect Computers")?.dedupedCells)
        func value(_ row: Int, _ col: Int) -> String {
            switch cells.first(where: { $0.row == row && $0.col == col })?.value {
            case .string(let text): text
            case .int(let number): String(number)
            default: ""
            }
        }
        XCTAssertEqual(value(3, 7), "Full Disk Access")
        XCTAssertEqual(value(3, 8), "Signatures Version")
        XCTAssertEqual(value(3, 9), "Last Disconnection Reason")
        XCTAssertEqual(value(4, 8), "21999")
        XCTAssertEqual(value(4, 9), "MQTT_KEEP_ALIVE_TIMEOUT")
        XCTAssertEqual(value(5, 8), "")
    }
}
