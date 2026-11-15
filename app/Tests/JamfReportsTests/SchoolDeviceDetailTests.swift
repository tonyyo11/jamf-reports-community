import XCTest
@testable import JamfReports

/// The per-device scan's reader, the School device health figures built from it and the workbook
/// columns (design: 2026-11-15-school-device-scan-design.md, "Where it shows").
final class SchoolDeviceDetailTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-school-detail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    private func devices(_ count: Int) throws {
        try SchoolRows.write((1...count).map { SchoolRows.device($0) }, kind: "school-devices", into: dir)
    }

    private func detail(_ n: Int, _ fields: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = ["udid": "school-udid-\(String(format: "%03d", n))"]
        for (key, value) in fields { row[key] = value }
        return row
    }

    private func scan(_ rows: [[String: Any]]) throws {
        try SchoolRows.write(rows, kind: ReportEngine.schoolDeviceDetailKind, into: dir)
    }

    private func health() throws -> SchoolDeviceHealth {
        try XCTUnwrap(SchoolDeviceHealth(SchoolFleetService.load(dataDir: dir)))
    }

    /// The captured `school devices get` object, placeholder identifiers.
    func testACapturedObjectReducesToTheFiveAllowedKeys() throws {
        let body = """
        {"UDID":"SCHOOL-UDID-001","name":"School Device 001","serialNumber":"SCHOOL-SERIAL-001",
         "model":{"identifier":"iPad13,18","name":"iPad (10th generation)"},
         "os":{"prefix":"iPadOS","version":"27.0.1"},"isManaged":true,"isSupervised":true,
         "lastCheckin":"2026-11-14 09:00:00","batteryLevel":64,"deviceEnrollType":"dep",
         "totalCapacity":64}
        """
        let row = try XCTUnwrap(ReportEngine.reduceSchoolDeviceDetail(
            Data(body.utf8), target: .init(udid: "school-udid-001", serial: "SCHOOL-SERIAL-001")))
        XCTAssertEqual(row, .init(udid: "school-udid-001", serialNumber: "SCHOOL-SERIAL-001",
                                  batteryLevel: 64, deviceEnrollType: "dep", totalCapacity: 64))
    }

    /// Rows: no scan snapshot; last attempt failed; unreadable snapshot.
    func testNoScanFailedAttemptAndUnreadableSnapshotAreEachSaid() throws {
        try devices(2)
        XCTAssertEqual(try health().detail.state, .notCollected)
        XCTAssertEqual(try health().detailLines, [L("Per-device details not collected yet")])

        let state = StateFileStore(directory: dir.appendingPathComponent("state"))
        state.record(.failed(exitCode: 3), report: ReportEngine.schoolDeviceDetailKind, at: .testNoon)
        XCTAssertNotNil(try health().detail.failedAt)
        XCTAssertTrue(try health().detailLines.contains { $0.hasPrefix(L("Last attempt failed")) })

        let kind = ReportEngine.schoolDeviceDetailKind
        let folder = dir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("\(kind)_20261019T080000.json"))
        XCTAssertEqual(try health().detail.state, .unreadable)
        XCTAssertTrue(try health().detailLines.contains(L("Per-device details could not be read")))
    }

    /// Row: battery 0, 15 and 80. A reading of 0 is never "low".
    func testBatteryZeroFifteenAndEighty() throws {
        try devices(3)
        try scan([detail(1, ["batteryLevel": 0]), detail(2, ["batteryLevel": 15]),
                  detail(3, ["batteryLevel": 80])])
        let h = try health().detail
        XCTAssertEqual(h.batteryZero, .init(count: 1, of: 3))
        XCTAssertEqual(h.lowBattery, .init(count: 1, of: 3))
    }

    func testFiguresJoinByUDIDAndCountOnlyDevicesThatReportedTheField() throws {
        try devices(4)
        try scan([
            detail(1, ["deviceEnrollType": "dep", "totalCapacity": 64, "batteryLevel": 50]),
            detail(2, ["deviceEnrollType": "dep", "totalCapacity": 128]),
            detail(3, ["deviceEnrollType": 7, "totalCapacity": "64", "batteryLevel": true]),
            ["udid": "not-in-the-fleet", "deviceEnrollType": "manual"],
        ])
        let h = try health().detail
        XCTAssertEqual(h.state, .scanned)
        XCTAssertEqual(h.scanned, .init(count: 3, of: 4))
        XCTAssertEqual(h.enrollmentReporting, 2)
        XCTAssertEqual(h.enrollment.shown.map(\.value), ["dep"])
        XCTAssertEqual(h.storageReporting, 2)
        XCTAssertEqual(Set(h.storage.shown.map(\.value)), [L("64 GB"), L("128 GB")])
        XCTAssertEqual(h.lowBattery, .init(count: 0, of: 1))
        XCTAssertTrue(try health().detailLines.first?.contains("3") ?? false)
    }

    /// Row: wrong-type field; reader keeps the rest of the row.
    func testReaderDropsWrongTypesPerField() {
        let parsed = SchoolDeviceDetail(snapshotRows: [
            ["udid": "A", "batteryLevel": 101, "totalCapacity": "2", "deviceEnrollType": "  "],
            ["udid": "B", "batteryLevel": 40, "totalCapacity": 256, "deviceEnrollType": "dep"],
            ["batteryLevel": 40],
        ], date: .testNoon)
        XCTAssertEqual(parsed.rows.count, 2)
        XCTAssertEqual(parsed.row(forUDID: "A"), .init(enrollType: nil, capacityGB: nil, battery: nil))
        XCTAssertEqual(parsed.row(forUDID: "b"), .init(enrollType: "dep", capacityGB: 256, battery: 40))
    }

    func testWorkbookAppendsThreeColumnsAndSummaryRows() throws {
        try devices(2)
        try SchoolRows.write([SchoolRows.row("school-dep-devices", 1)],
                             kind: "school-dep-devices", into: dir)
        try scan([detail(1, ["deviceEnrollType": "dep", "totalCapacity": 64, "batteryLevel": 15])])
        let book = Workbook()
        let dash = SchoolDashboard(config: ReportConfig(), dataDir: dir, workbook: book, now: .testNoon)
        try dash.writeSchoolDeviceInventory()
        try dash.writeSchoolDeviceHealth()
        let inventory = try XCTUnwrap(book.sheet(named: "Device Inventory")).dedupedCells
        let headers = inventory.compactMap { cell -> String? in
            if case let .string(s) = cell.value { return s } else { return nil }
        }
        for header in ["Last Checkin", "Enrollment", "Storage (GB)", "Battery (%) when scanned"] {
            XCTAssertTrue(headers.contains(header), header)
        }
        let at = { (header: String) in inventory.first {
            if case let .string(s) = $0.value { return s == header } else { return false }
        }?.col }
        XCTAssertEqual(at("Last Checkin"), 5)
        XCTAssertEqual(at("Enrollment"), 6)
        XCTAssertEqual(at("Battery (%) when scanned"), 8)
        let healthCells = (try XCTUnwrap(book.sheet(named: "Device Health")).dedupedCells).compactMap {
            if case let .string(s) = $0.value { return s } else { return nil }
        }
        XCTAssertTrue(healthCells.contains("Enrollment type: dep"))
        XCTAssertTrue(healthCells.contains("Battery 1 to 20% when scanned"))
    }

    /// A fleet with the scan turned off by collect_skip says so, not "not collected yet"; the
    /// breakdown lines carry their denominator.
    func testTurnedOffWordingAndDenominators() throws {
        try devices(3)
        let off = try XCTUnwrap(SchoolDeviceHealth(
            SchoolFleetService.load(dataDir: dir), scanTurnedOff: true))
        XCTAssertEqual(off.detailLines,
                       [L("Per-device details are turned off (jamf_cli.collect_skip)")])
        try scan([detail(1, ["deviceEnrollType": "dep", "totalCapacity": 64]),
                  detail(2, ["deviceEnrollType": "dep"])])
        let lines = try health().detailLines
        XCTAssertTrue(lines.contains(L("Enrollment type: dep 2 (of 2 devices reporting)")))
        XCTAssertTrue(lines.contains { $0.contains("(") && $0.hasPrefix(L("Storage:")) })
    }
}
