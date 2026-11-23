import XCTest
@testable import JamfReports

final class SchoolDeviceHealthTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-school-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ rows: [[String: Any]], _ kind: String) throws {
        try SchoolRows.write(rows, kind: kind, into: dir)
    }

    private func health() -> SchoolDeviceHealth? {
        SchoolDeviceHealth(SchoolFleetService.load(dataDir: dir))
    }

    private func dep(_ n: Int, _ over: [String: Any] = [:], omitting: Set<String> = [],
                     malformed: [String: Any] = [:]) -> [String: Any] {
        SchoolRows.row("school-dep-devices", n, over, omitting: omitting, malformed: malformed)
    }

    // MARK: - ADE join

    func test_serialJoin_ignoresCaseAndWhitespace_andTrashDoesNotEnrol() throws {
        try write([
            SchoolRows.device(1),
            SchoolRows.device(2, ["serialNumber": " school-serial-002 "]),
            SchoolRows.device(3, ["inTrash": true]),
        ], "school-devices")
        try write([
            dep(1, ["serialNumber": "school-serial-001"]), dep(2), dep(3), dep(4),
            dep(5, omitting: ["serialNumber"]),
            dep(6, malformed: ["serialNumber": true]),
        ], "school-dep-devices")
        let h = try XCTUnwrap(health())
        // 001 and 002 enrolled; 003 is only in trash; 5 has no serial, 6 a wrong-type one.
        XCTAssertEqual(h.figures[.adeNotEnrolled], .init(count: 2, of: 4))
        XCTAssertEqual(h.notEnrolled.map(\.serial), ["SCHOOL-SERIAL-003", "SCHOOL-SERIAL-004"])
    }

    func test_depStatusAndProfileBreakdowns_areCappedAndDisplayText() throws {
        try write([SchoolRows.device(99)], "school-devices")
        var rows = (1...7).map { dep($0, ["status": "state-\($0)", "profileName": "P\($0)"]) }
        rows.append(dep(8, ["status": "state-1", "profileName": "  "]))
        rows.append(dep(9, ["status": "bad\u{202E}x"]))
        try write(rows, "school-dep-devices")
        let h = try XCTUnwrap(health())
        XCTAssertEqual(h.depStatuses.shown.count, SchoolDeviceHealth.maxShown)
        XCTAssertEqual(h.depStatuses.shown.first?.value, "state-1")
        XCTAssertEqual(h.depStatuses.shown.first?.count, 2)
        XCTAssertEqual(h.depStatuses.distinct, 8)
        XCTAssertFalse(h.depStatuses.shown.contains { $0.value.contains("\u{202E}") })
        XCTAssertGreaterThan(h.notEnrolledProfiles.distinct, h.notEnrolledProfiles.shown.count)
        XCTAssertEqual(h.notEnrolledProfiles.shown.count, SchoolDeviceHealth.maxShown)
    }

    func test_blankProfileReadsAsNoProfile() throws {
        try write([SchoolRows.device(99)], "school-devices")
        try write([dep(1, ["profileName": ""])], "school-dep-devices")
        let h = try XCTUnwrap(health())
        XCTAssertEqual(h.notEnrolledProfiles.shown.map(\.value), [L("No profile")])
    }

    // MARK: - Other figures

    func test_usersGroupsClasses_countZeroesAndLeaveWrongTypesOut() throws {
        try write([
            SchoolRows.row("school-users", 1, ["deviceCount": 0]),
            SchoolRows.row("school-users", 2, ["deviceCount": 3]),
            SchoolRows.row("school-users", 3, ["deviceCount": 0, "inTrash": true]),
            SchoolRows.row("school-users", 4, malformed: ["deviceCount": "0"]),
            SchoolRows.row("school-users", 5, malformed: ["deviceCount": true]),
        ], "school-users")
        try write([
            SchoolRows.row("school-device-groups", 1, ["members": 0]),
            SchoolRows.row("school-device-groups", 2, ["members": 0, "isSmartGroup": true]),
            SchoolRows.row("school-device-groups", 3, ["members": 4, "isSmartGroup": true]),
            SchoolRows.row("school-device-groups", 4, malformed: ["members": "x"]),
        ], "school-device-groups")
        try write([
            SchoolRows.row("school-classes", 1, ["deviceCount": 0, "studentCount": 0]),
            SchoolRows.row("school-classes", 2, ["teacherCount": 0]),
            SchoolRows.row("school-classes", 3, malformed: ["teacherCount": "0"]),
        ], "school-classes")
        let h = try XCTUnwrap(health())
        XCTAssertEqual(h.figures[.usersNoDevice], .init(count: 1, of: 2))
        XCTAssertEqual(h.figures[.groupsNoMembers], .init(count: 1, of: 1))
        XCTAssertEqual(h.figures[.smartGroupsNoMembers], .init(count: 1, of: 2))
        XCTAssertEqual(h.figures[.classesNoDevices], .init(count: 1, of: 3))
        XCTAssertEqual(h.figures[.classesNoStudents], .init(count: 1, of: 3))
        XCTAssertEqual(h.figures[.classesNoTeacher], .init(count: 1, of: 2))
    }

    func test_eachFigureIsAbsentWhenItsSnapshotIsMissing() throws {
        try write([SchoolRows.row("school-classes", 1)], "school-classes")
        let h = try XCTUnwrap(health())
        XCTAssertNil(h.figures[.usersNoDevice])
        XCTAssertNil(h.figures[.groupsNoMembers])
        XCTAssertNil(h.figures[.adeNotEnrolled])
        XCTAssertEqual(h.items, [.classesNoDevices, .classesNoStudents, .classesNoTeacher])
    }

    func test_depWithoutDevicesSnapshot_hasNoEnrollmentFigure() throws {
        try write([dep(1)], "school-dep-devices")
        XCTAssertNil(health(), "no figure and nothing unreadable: no card")
    }

    func test_noSnapshots_isNil() { XCTAssertNil(health()) }

    // MARK: - Unreadable

    func test_unreadableSnapshot_isSaidNotHidden() throws {
        let kind = SchoolFleetService.usersKind
        let folder = dir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8)
            .write(to: folder.appendingPathComponent("\(kind)_20261019T080000.json"))
        try write([SchoolRows.row("school-classes", 1)], "school-classes")
        let h = try XCTUnwrap(health())
        XCTAssertTrue(h.unreadable.contains(.usersNoDevice))
        XCTAssertNil(h.figures[.usersNoDevice])
        XCTAssertTrue(h.items.contains(.usersNoDevice))
    }
}

final class SchoolDeviceHealthWorkbookTests: XCTestCase {
    private func dash(_ dir: URL, _ book: Workbook) -> SchoolDashboard {
        SchoolDashboard(config: ReportConfig(), dataDir: dir, workbook: book, now: .testNoon)
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-school-hw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func test_tabIsLast_andSkippedWithNoFigure() throws {
        XCTAssertEqual(SchoolDashboard.sheetNames.last, "Device Health")
        let book = Workbook()
        XCTAssertThrowsError(try dash(try tempDir(), book).writeSchoolDeviceHealth()) {
            XCTAssertTrue($0 is SheetSkippable)
        }
        XCTAssertNil(book.sheet(named: "Device Health"))
    }

    func test_tabHasSummaryAndNotEnrolledTable() throws {
        let dir = try tempDir()
        try SchoolRows.write([SchoolRows.device(1)], kind: "school-devices", into: dir)
        try SchoolRows.write(
            [SchoolRows.row("school-dep-devices", 1), SchoolRows.row("school-dep-devices", 2)],
            kind: "school-dep-devices", into: dir)
        let book = Workbook()
        try dash(dir, book).writeSchoolDeviceHealth()
        let cells = (book.sheet(named: "Device Health")?.dedupedCells ?? []).compactMap {
            if case let .string(s) = $0.value { return s } else { return nil }
        }
        for header in ["Figure", "Count", "Of", "Device name", "Serial", "Model", "Profile",
                       "Status", "SCHOOL-SERIAL-002"] {
            XCTAssertTrue(cells.contains(header), header)
        }
        XCTAssertFalse(cells.contains("SCHOOL-SERIAL-001"), "enrolled, so not listed")
    }
}
