import XCTest
@testable import JamfReports

/// Every key of the shape captured from jamf-cli 1.33.0 is either read by the app's decoder
/// (changing its value changes what the decoder produces) or named here as ignored. A captured
/// key nobody classified, a "read" key the capture lacks, or a key the decoder no longer reads
/// fails. Rows come from `SchoolRows`, so the decoder sees the captured types.
final class SchoolCapturedShapeTests: XCTestCase {
    private var created: [URL] = []

    override func tearDown() {
        created.forEach { try? FileManager.default.removeItem(at: $0) }
        created = []
        super.tearDown()
    }

    /// The same value with the same JSON type, different from the original.
    private func altered(_ value: Any) -> Any {
        switch value {
        case let s as String: return s + "-alt"
        case let n as Int: return n + 1
        case let b as Bool: return !b
        default: return value
        }
    }

    /// Checks one decoder against one kind. `render` turns a row into whatever the decoder
    /// produces, as text.
    private func assertReads(
        _ kind: String, read: Set<String>, ignored: Set<String> = [],
        file: StaticString = #filePath, line: UInt = #line, render: ([String: Any]) throws -> String
    ) throws {
        let captured = Set(try XCTUnwrap(SchoolRows.shapes[kind]).keys)
        XCTAssertEqual(read.union(ignored), captured, "\(kind): classify every captured key",
                       file: file, line: line)
        XCTAssertTrue(read.isDisjoint(with: ignored), kind, file: file, line: line)
        let row = SchoolRows.row(kind)
        let base = try render(row)
        for key in captured.sorted() {
            var changed = row
            changed[key] = altered(try XCTUnwrap(row[key]))
            let after = try render(changed)
            if read.contains(key) {
                XCTAssertNotEqual(base, after, "\(kind).\(key) is not read", file: file, line: line)
            } else {
                XCTAssertEqual(base, after, "\(kind).\(key) is read but listed as ignored",
                               file: file, line: line)
            }
        }
    }

    /// The text of `sheets` after `write` ran over a data folder holding only `row` as `kind`.
    private func sheetText(
        _ kind: String, _ row: [String: Any], sheets: [String],
        write: (SchoolDashboard) throws -> Void
    ) throws -> String {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-school-shape-\(UUID().uuidString)", isDirectory: true)
        created.append(dataDir)
        try SchoolRows.write([row], kind: kind, into: dataDir)
        let workbook = Workbook()
        try write(SchoolDashboard(
            config: ReportConfig(), dataDir: dataDir, workbook: workbook, now: .testNoon))
        return sheets.flatMap { sheet in
            (workbook.sheet(named: sheet)?.dedupedCells ?? []).map {
                "\(sheet)|\($0.row),\($0.col)|\($0.value)"
            }
        }.filter { !$0.contains("Generated:") }.joined(separator: "\n")
    }

    func testBuilderRowsCarryExactlyTheCapturedKeysAndTypes() throws {
        XCTAssertEqual(Set(SchoolRows.shapes.keys), [
            "school-overview", "school-devices", "school-device-groups", "school-users",
            "school-classes", "school-apps", "school-profiles", "school-locations",
            "school-dep-devices",
        ], "school-ibeacons captured no rows and school-blueprints exits 1: no shape")
        for (kind, shape) in SchoolRows.shapes {
            let row = SchoolRows.row(kind)
            XCTAssertEqual(Set(row.keys), Set(shape.keys), kind)
            for (key, type) in shape {
                XCTAssertTrue(SchoolRows.matches(try XCTUnwrap(row[key]), type), "\(kind).\(key)")
            }
        }
    }

    // MARK: - The fleet service (SchoolFleetService)

    func testDevicesFleetReaderReadsEveryCapturedKey() throws {
        try assertReads("school-devices", read: Set(SchoolRows.shapes["school-devices"]!.keys)) {
            String(describing: SchoolFleetService.device(from: $0, index: 0))
        }
    }

    func testDEPDevicesFleetReader() throws {
        try assertReads(
            "school-dep-devices",
            read: ["serialNumber", "deviceName", "model", "status", "profileName"],
            ignored: ["color", "id", "locationId"]
        ) { String(describing: SchoolFleetService.depDevice(from: $0, index: 0)) }
    }

    func testOverviewFleetReader() throws {
        try assertReads("school-overview", read: ["section", "resource", "value"]) {
            String(describing: SchoolFleetService.overviewRow(from: $0))
        }
    }

    // MARK: - The workbook tabs (SchoolDashboard)

    func testOverviewSheet() throws {
        try assertReads("school-overview", read: ["resource", "value"], ignored: ["section"]) {
            try sheetText("school-overview", $0, sheets: ["School Overview"]) {
                try $0.writeSchoolOverview()
            }
        }
    }

    /// `inTrash` is read: a trashed device leaves every device tab, as it leaves the screen.
    func testDeviceSheets() throws {
        try assertReads(
            "school-devices",
            read: ["name", "serialNumber", "model", "os", "isManaged", "isSupervised",
                   "lastCheckin", "inTrash"],
            ignored: ["udid"]
        ) {
            try sheetText("school-devices", $0, sheets: [
                "Device Inventory", "OS Versions", "Device Status", "Stale Devices",
            ]) { dash in
                try dash.writeSchoolDeviceInventory()
                try dash.writeSchoolOSVersions()
                try dash.writeSchoolDeviceStatus()
                try dash.writeSchoolStaleDevices()
            }
        }
    }

    func testDeviceGroupsSheet() throws {
        try assertReads(
            "school-device-groups", read: ["name", "members", "locationId"],
            ignored: ["description", "id", "isSmartGroup", "shared", "type"]
        ) {
            try sheetText("school-device-groups", $0, sheets: ["Device Groups"]) {
                try $0.writeSchoolDeviceGroups()
            }
        }
    }

    func testUsersSheet() throws {
        try assertReads(
            "school-users",
            read: ["username", "firstName", "lastName", "email", "locationId", "status",
                   "inTrash"],
            ignored: ["deviceCount", "id"]
        ) {
            try sheetText("school-users", $0, sheets: ["Users"]) { try $0.writeSchoolUsers() }
        }
    }

    func testClassesSheet() throws {
        try assertReads(
            "school-classes", read: ["name", "studentCount", "teacherCount", "locationId"],
            ignored: ["description", "deviceCount", "source", "uuid"]
        ) {
            try sheetText("school-classes", $0, sheets: ["Classes"]) { try $0.writeSchoolClasses() }
        }
    }

    func testAppsSheet() throws {
        try assertReads(
            "school-apps", read: ["name", "bundleId", "vendor", "platform"],
            ignored: ["adamId", "id", "locationId", "version"]
        ) {
            try sheetText("school-apps", $0, sheets: ["Apps"]) { try $0.writeSchoolApps() }
        }
    }

    func testProfilesSheet() throws {
        try assertReads(
            "school-profiles", read: ["name", "identifier", "platform", "locationId"],
            ignored: ["description", "id"]
        ) {
            try sheetText("school-profiles", $0, sheets: ["Profiles"]) {
                try $0.writeSchoolProfiles()
            }
        }
    }

    func testLocationsSheet() throws {
        try assertReads(
            "school-locations", read: ["name", "isDistrict", "city"], ignored: ["id", "source"]
        ) {
            try sheetText("school-locations", $0, sheets: ["Locations"]) {
                try $0.writeSchoolLocations()
            }
        }
    }

    func testDEPDevicesSheet() throws {
        try assertReads(
            "school-dep-devices",
            read: ["serialNumber", "deviceName", "model", "status", "profileName"],
            ignored: ["color", "id", "locationId"]
        ) {
            try sheetText("school-dep-devices", $0, sheets: ["DEP Devices"]) {
                try $0.writeSchoolDepDevices()
            }
        }
    }
}
