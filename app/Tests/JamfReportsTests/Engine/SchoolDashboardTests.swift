import Foundation
import XCTest
@testable import JamfReports

// MARK: - SchoolDashboardTests
// Tests for SchoolDashboard write* methods backed by committed fixtures.
// Tests that require specific fixtures skip when those fixtures are absent.

final class SchoolDashboardTests: XCTestCase {

    // MARK: - Helpers

    /// Tracks helper-created temp dirs for sweep in `tearDown`. Direct-callsite
    /// temp dirs still use local `defer` cleanup.
    private var createdTempDirs: [URL] = []

    override func tearDown() {
        for url in createdTempDirs {
            try? FileManager.default.removeItem(at: url)
        }
        createdTempDirs = []
        super.tearDown()
    }

    private func tempDataDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-school-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        createdTempDirs.append(tmp)
        return tmp
    }

    private func makeDashboard(
        dataDir: URL, workbook: Workbook = Workbook()
    ) -> SchoolDashboard {
        SchoolDashboard(
            config: ReportConfig(), dataDir: dataDir, workbook: workbook, now: .testNoon)
    }

    // MARK: - iBeacons

    /// The captured tenant returned no iBeacons, so the only captured shape is an empty list:
    /// the tab is written with its header and no rows.
    func testWriteSchoolIBeaconsOnTheCapturedEmptyList() throws {
        let dataDir = try tempDataDir()
        try SchoolRows.write([], kind: "school-ibeacons", into: dataDir)
        let workbook = Workbook()
        let dash = makeDashboard(dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolIBeacons())
        XCTAssertTrue(strings(in: "iBeacons", of: workbook).contains("Name"))
    }

    func testWriteSchoolIBeaconsThrowsOnEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dash = makeDashboard(dataDir: tmp)
        XCTAssertThrowsError(try dash.writeSchoolIBeacons()) { error in
            guard case SchoolDashboardError.noCachedData = error else {
                XCTFail("Expected SchoolDashboardError.noCachedData, got \(error)")
                return
            }
        }
    }

    // MARK: - DEP Devices

    func testWriteSchoolDepDevicesReadsTheCapturedColumns() throws {
        let dataDir = try tempDataDir()
        try SchoolRows.write([
            SchoolRows.row("school-dep-devices", 1, ["status": "Assigned"]),
            SchoolRows.row("school-dep-devices", 2,
                           ["deviceName": "", "profileName": "", "status": "Unassigned"]),
        ], kind: "school-dep-devices", into: dataDir)
        let workbook = Workbook()
        let dash = makeDashboard(dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolDepDevices())
        let cells = strings(in: "DEP Devices", of: workbook)
        for expected in ["SCHOOL-SERIAL-001", "SCHOOL-SERIAL-002", "School DEP Device 001",
                         "School DEP Profile 001", "iPad (10th generation)", "Assigned",
                         "Unassigned"] {
            XCTAssertTrue(cells.contains(expected), expected)
        }
    }

    func testWriteSchoolDepDevicesThrowsOnEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dash = makeDashboard(dataDir: tmp)
        XCTAssertThrowsError(try dash.writeSchoolDepDevices())
    }

    // MARK: - writeAll skips missing snapshots silently

    func testWriteAllReturnsEmptyOnNoData() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dash = makeDashboard(dataDir: tmp)
        let (written, failures) = dash.writeAll()
        XCTAssertTrue(written.isEmpty, "Expected no sheets written on empty dataDir")
        XCTAssertTrue(failures.isEmpty, "Expected no failures on empty dataDir — noCachedData is a skip")
    }

    func testWriteAllWritesIBeaconsAndDepDevicesWhenAvailable() throws {
        let dataDir = try tempDataDir()
        try SchoolRows.write([], kind: "school-ibeacons", into: dataDir)
        try SchoolRows.write([SchoolRows.row("school-dep-devices")],
                             kind: "school-dep-devices", into: dataDir)
        let dash = makeDashboard(dataDir: dataDir)
        let (written, failures) = dash.writeAll()
        XCTAssertTrue(written.contains("iBeacons"), "Expected iBeacons sheet to be written")
        XCTAssertTrue(written.contains("DEP Devices"), "Expected DEP Devices sheet to be written")
        XCTAssertTrue(failures.isEmpty, "No unexpected failures expected for valid fixture data")
    }

    // MARK: - jamf-cli shape helpers
    //
    // Rows come from `SchoolRows`: the key-and-type shape captured from jamf-cli 1.33.0
    // (exact keys and JSON types), not the pre-2026-09 guessed key names the readers used
    // to look for.

    /// Writes `rows` as the newest `<kind>` snapshot of a temp data folder.
    private func tempDataDir(writing rows: [[String: Any]], kind: String) throws -> URL {
        let tmp = try tempDataDir()
        try SchoolRows.write(rows, kind: kind, into: tmp)
        return tmp
    }

    private func strings(in sheetName: String, of workbook: Workbook) -> [String] {
        (workbook.sheet(named: sheetName)?.dedupedCells ?? []).compactMap {
            if case let .string(s) = $0.value { return s } else { return nil }
        }
    }

    private func ints(in sheetName: String, of workbook: Workbook) -> [Int] {
        (workbook.sheet(named: sheetName)?.dedupedCells ?? []).compactMap {
            if case let .int(i) = $0.value { return i } else { return nil }
        }
    }

    /// A jamf-cli School device `lastCheckin` string: "yyyy-MM-dd HH:mm:ss",
    /// no timezone, no "T" separator (confirmed against jamfschool-go-sdk's
    /// device_test.go). Counted back from `.testNoon`, the `now` every dashboard here is given.
    private func schoolCheckinString(daysAgo: Int, extraSeconds: TimeInterval = 3600) -> String {
        let date = Date.testNoon.addingTimeInterval(-(Double(daysAgo) * 86400) - extraSeconds)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: - School Overview: flattenSchoolOverviewRow shape

    func testSchoolOverviewReadsResourceAndValueFieldsNotDictKeys() throws {
        let rows = [
            SchoolRows.row("school-overview", 1, ["resource": "Devices", "value": "42"]),
            SchoolRows.row("school-overview", 2, ["resource": "Device Groups", "value": "3"]),
            SchoolRows.row("school-overview", 3, [
                "section": "Users & Organization", "resource": "Users", "value": "128",
            ]),
        ]
        let dataDir = try tempDataDir(writing: rows, kind: "school-overview")
        let workbook = Workbook()
        let dash = makeDashboard(dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolOverview())
        let cells = workbook.sheet(named: "School Overview")?.dedupedCells ?? []
        let resourceCells: [String] = cells.filter { $0.col == 0 }.compactMap {
            if case let .string(s) = $0.value { return s } else { return nil }
        }
        XCTAssertEqual(resourceCells.filter { $0 == "Devices" }.count, 1,
                        "one row per item, not one row per JSON key")
        XCTAssertTrue(resourceCells.contains("Device Groups"))
        XCTAssertTrue(resourceCells.contains("Users"))
        XCTAssertFalse(resourceCells.contains("Section"),
                        "must not surface the raw JSON key name as a row label")
        let valueCells: [String] = cells.filter { $0.col == 1 }.compactMap {
            if case let .string(s) = $0.value { return s } else { return nil }
        }
        XCTAssertTrue(valueCells.contains("42"))
        XCTAssertTrue(valueCells.contains("3"))
        XCTAssertTrue(valueCells.contains("128"))
    }

    // MARK: - Device Groups: flattenSchoolDeviceGroup shape

    func testDeviceGroupsReadsMembersAndLocationId() throws {
        let rows = [SchoolRows.row("school-device-groups", 1, [
            "name": "iPad Cart A", "members": 24, "locationId": 42,
        ])]
        let dataDir = try tempDataDir(writing: rows, kind: "school-device-groups")
        let workbook = Workbook()
        let dash = makeDashboard(dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolDeviceGroups())
        XCTAssertTrue(strings(in: "Device Groups", of: workbook).contains("iPad Cart A"))
        XCTAssertTrue(ints(in: "Device Groups", of: workbook).contains(24),
                       "device count comes from `members`, not a guessed key")
        XCTAssertTrue(strings(in: "Device Groups", of: workbook).contains("42"),
                       "falls back to the numeric locationId when no name list is present")
    }

    // MARK: - Users: flattenSchoolUser shape

    func testUsersReadsStatusAndLocationId() throws {
        let rows = [SchoolRows.row("school-users", 5, ["locationId": 7])]
        let dataDir = try tempDataDir(writing: rows, kind: "school-users")
        let workbook = Workbook()
        let dash = makeDashboard(dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolUsers())
        let cells = strings(in: "Users", of: workbook)
        XCTAssertTrue(cells.contains("school-user-005"))
        XCTAssertTrue(cells.contains("First005"))
        XCTAssertTrue(cells.contains("Last005"))
        XCTAssertTrue(cells.contains("user-005@example.invalid"))
        XCTAssertTrue(cells.contains("Active"),
                       "Status column reads `status`; jamf-cli has no role")
        XCTAssertTrue(cells.contains("7"), "falls back to the numeric locationId")
    }

    // MARK: - Classes: flattenSchoolClass shape

    func testClassesReadsTeacherCountAndLocationId() throws {
        let rows = [SchoolRows.row("school-classes", 1, [
            "name": "Homeroom 4B", "studentCount": 18, "teacherCount": 3, "locationId": 11,
        ])]
        let dataDir = try tempDataDir(writing: rows, kind: "school-classes")
        let workbook = Workbook()
        let dash = makeDashboard(dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolClasses())
        XCTAssertTrue(strings(in: "Classes", of: workbook).contains("Homeroom 4B"))
        let classInts = ints(in: "Classes", of: workbook)
        XCTAssertTrue(classInts.contains(18), "student count")
        XCTAssertTrue(classInts.contains(3), "teacher count comes from `teacherCount`, not a name")
        XCTAssertTrue(strings(in: "Classes", of: workbook).contains("11"),
                       "falls back to the numeric locationId")
    }

    // MARK: - Apps: flattenSchoolApp shape

    func testAppsReadsVendorAndPlatform() throws {
        let rows = [SchoolRows.row("school-apps", 8)]
        let dataDir = try tempDataDir(writing: rows, kind: "school-apps")
        let workbook = Workbook()
        let dash = makeDashboard(dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolApps())
        let cells = strings(in: "Apps", of: workbook)
        XCTAssertTrue(cells.contains("School App 008"))
        XCTAssertTrue(cells.contains("invalid.example.app008"))
        XCTAssertTrue(cells.contains("Example Vendor 008"),
                       "jamf-cli has no per-app install/managed count; Vendor replaces it")
        XCTAssertTrue(cells.contains("iOS"), "Platform replaces the unavailable Managed column")
    }

    // MARK: - Profiles: flattenSchoolProfile shape

    func testProfilesReadsIdentifierPlatformAndLocation() throws {
        let rows = [SchoolRows.row("school-profiles", 4, ["locationId": 6])]
        let dataDir = try tempDataDir(writing: rows, kind: "school-profiles")
        let workbook = Workbook()
        let dash = makeDashboard(dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolProfiles())
        let cells = strings(in: "Profiles", of: workbook)
        XCTAssertTrue(cells.contains("School Profile 004"))
        XCTAssertTrue(cells.contains("invalid.example.profile004"),
                       "jamf-cli has no per-profile category; Identifier replaces it")
        XCTAssertTrue(cells.contains("Shared"), "Platform replaces the unavailable Devices column")
        XCTAssertTrue(cells.contains("6"), "Location replaces the unavailable Enabled column")
    }

    // MARK: - Locations: flattenSchoolLocation shape

    func testLocationsReadsIsDistrictAndCity() throws {
        let rows = [
            SchoolRows.row("school-locations", 1, ["name": "Main Campus", "city": "Springfield"]),
            SchoolRows.row("school-locations", 2, ["name": "Annex"], omitting: ["city"]),
        ]
        let dataDir = try tempDataDir(writing: rows, kind: "school-locations")
        let workbook = Workbook()
        let dash = makeDashboard(dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolLocations())
        let cells = strings(in: "Locations", of: workbook)
        XCTAssertTrue(cells.contains("Main Campus"))
        XCTAssertTrue(cells.contains("Annex"))
        XCTAssertTrue(cells.contains("Springfield"),
                       "jamf-cli has no street address; City replaces it")
        XCTAssertTrue(cells.contains("Yes"), "Is District replaces the unavailable Device Count")
        XCTAssertTrue(cells.contains("No"))
    }

    // MARK: - Device-fed sheets: flattenSchoolDevice shape (school-devices)

    private func deviceRows() -> [[String: Any]] {
        [
            SchoolRows.device(1, [
                "name": "Mac-Lab-01", "model": "MacBook Air", "os": "macOS 14.3",
                "lastCheckin": schoolCheckinString(daysAgo: 5),
            ]),
            SchoolRows.device(2, [
                "name": "iPad-12", "model": "iPad Air", "os": "iPadOS 17.4",
                "isSupervised": false, "lastCheckin": schoolCheckinString(daysAgo: 40),
            ]),
            SchoolRows.device(3, [
                "name": "iPad-13", "model": "iPad (9th gen)", "os": "iPadOS 17.4",
                "isManaged": false, "isSupervised": false,
                "lastCheckin": schoolCheckinString(daysAgo: 3),
            ]),
        ]
    }

    func testDeviceInventoryReadsOSAndIsManaged() throws {
        let dataDir = try tempDataDir(writing: deviceRows(), kind: "school-devices")
        let workbook = Workbook()
        let dash = makeDashboard(dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolDeviceInventory())
        let cells = strings(in: "Device Inventory", of: workbook)
        XCTAssertTrue(cells.contains("Mac-Lab-01"))
        XCTAssertTrue(cells.contains("SCHOOL-SERIAL-001"))
        XCTAssertTrue(cells.contains("macOS 14.3"), "OS Version reads `os`, not `osVersion`")
        XCTAssertTrue(cells.contains("Yes"), "Managed reads `isManaged`, not `managed`")
        XCTAssertTrue(cells.contains("No"))
    }

    func testOSVersionsGroupsByPlatformAndMajorVersion() throws {
        let dataDir = try tempDataDir(writing: deviceRows(), kind: "school-devices")
        let workbook = Workbook()
        let dash = makeDashboard(dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolOSVersions())
        let cells = strings(in: "OS Versions", of: workbook)
        XCTAssertTrue(cells.contains("macOS 14"), "the major version keeps its platform")
        XCTAssertTrue(cells.contains("iPadOS 17"), "the major version keeps its platform")
        let counts = ints(in: "OS Versions", of: workbook)
        XCTAssertTrue(counts.contains(2), "both iPadOS 17.4 devices grouped into one bucket")
    }

    /// From 26 on every Apple platform shares its major version; "26" alone merged them.
    func testOSVersionsKeepsMacsAndIPadsOnTheSameMajorApart() throws {
        let rows = ["macOS 26.0", "macOS 26.1", "iPadOS 26.0", "macOS 9.2"].enumerated().map {
            SchoolRows.device($0 + 1, ["os": $1])
        }
        let dataDir = try tempDataDir(writing: rows, kind: "school-devices")
        let workbook = Workbook()
        let dash = makeDashboard(dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolOSVersions())
        let cells = strings(in: "OS Versions", of: workbook)
        XCTAssertTrue(cells.contains("macOS 26"))
        XCTAssertTrue(cells.contains("iPadOS 26"))
        XCTAssertFalse(cells.contains("26"), "no bucket merges both platforms")
        let order = cells.filter { $0.hasPrefix("macOS ") }
        XCTAssertEqual(order, ["macOS 26", "macOS 9"], "versions sort numerically, newest first")
        XCTAssertEqual(ints(in: "OS Versions", of: workbook).sorted(), [1, 1, 2])
    }

    func testDeviceStatusCountsIsManagedAndIsSupervised() throws {
        let dataDir = try tempDataDir(writing: deviceRows(), kind: "school-devices")
        let workbook = Workbook()
        let dash = makeDashboard(dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolDeviceStatus())
        let cells = workbook.sheet(named: "Device Status")?.dedupedCells ?? []
        var countByLabel: [String: Int] = [:]
        for label in cells where label.col == 0 {
            guard case let .string(name) = label.value,
                  let cell = cells.first(where: { $0.row == label.row && $0.col == 1 }),
                  case let .int(count) = cell.value else { continue }
            countByLabel[name] = count
        }
        XCTAssertEqual(countByLabel["Total Devices"], 3)
        XCTAssertEqual(countByLabel["Managed"], 2, "Managed reads `isManaged`, not `managed`")
        XCTAssertEqual(countByLabel["Unmanaged"], 1)
        XCTAssertEqual(countByLabel["Supervised"], 1, "reads `isSupervised`, not `supervised`")
    }

    func testStaleDevicesParsesSchoolCheckinFormat() throws {
        let dataDir = try tempDataDir(writing: deviceRows(), kind: "school-devices")
        let workbook = Workbook()
        let dash = makeDashboard(dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolStaleDevices())
        let cells = strings(in: "Stale Devices", of: workbook)
        XCTAssertTrue(cells.contains("iPad-12"), "the 40-day-stale device is listed")
        XCTAssertFalse(cells.contains("Mac-Lab-01"), "the 5-day device is well under the threshold")
        XCTAssertFalse(cells.contains("iPad-13"), "the 3-day device is well under the threshold")
        XCTAssertTrue(ints(in: "Stale Devices", of: workbook).contains(40),
                       "days-since-checkin parses jamf-cli's \"yyyy-MM-dd HH:mm:ss\" format")
    }

    func testStaleDevicesLeavesOutACheckinThatDoesNotRead() throws {
        let rows = [
            SchoolRows.device(1, ["name": "Odd-1", "lastCheckin": "yesterday-ish"]),
            SchoolRows.device(2, ["name": "Blank-2", "lastCheckin": ""]),
            SchoolRows.device(3, [
                "name": "Old-3", "lastCheckin": schoolCheckinString(daysAgo: 60),
            ]),
        ]
        let dataDir = try tempDataDir(writing: rows, kind: "school-devices")
        let workbook = Workbook()
        let dash = makeDashboard(dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolStaleDevices())
        let cells = strings(in: "Stale Devices", of: workbook)
        XCTAssertTrue(cells.contains("Old-3"))
        XCTAssertFalse(cells.contains("Odd-1"), "an unknown age is not 0 days or stale")
        XCTAssertFalse(cells.contains("Blank-2"))
        XCTAssertEqual(ints(in: "Stale Devices", of: workbook).filter { $0 == 0 }, [])
    }

    func testClassesCountOutsideIntRangeReadsAsZero() throws {
        let rows = [SchoolRows.row(
            "school-classes", 1, ["name": "A"],
            malformed: ["studentCount": 1e30, "teacherCount": 2.9])]
        let dataDir = try tempDataDir(writing: rows, kind: "school-classes")
        let workbook = Workbook()
        let dash = makeDashboard(dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolClasses())
        let counts = ints(in: "Classes", of: workbook)
        XCTAssertTrue(counts.contains(0), "1e30 is no count; Int(_:) would trap")
        XCTAssertTrue(counts.contains(2), "a fractional count still truncates")
    }

    // MARK: - Trashed records: one fleet rule with the Devices screen

    /// Devices 1 and 2 are in the fleet; device 3 is in School's trash and long stale.
    private func fleetWithTrash() throws -> (dir: URL, screen: SchoolFleetService.Snapshot) {
        let rows = [
            SchoolRows.device(1, [
                "os": "macOS 26.6.2", "lastCheckin": schoolCheckinString(daysAgo: 2),
            ]),
            SchoolRows.device(2, [
                "os": "iPadOS 18.1", "isManaged": false, "isSupervised": false,
                "lastCheckin": schoolCheckinString(daysAgo: 50),
            ]),
            SchoolRows.device(3, [
                "os": "iPadOS 17.0", "inTrash": true,
                "lastCheckin": schoolCheckinString(daysAgo: 90),
            ]),
            // Exactly 30 days: not stale on the screen, so not on the sheet.
            SchoolRows.device(4, [
                "os": "iPadOS 18.1",
                "lastCheckin": schoolCheckinString(daysAgo: 30, extraSeconds: 0),
            ]),
        ]
        let dir = try tempDataDir(writing: rows, kind: "school-devices")
        let screen = SchoolFleetService.load(dataDir: dir)
        XCTAssertEqual(screen.devices.count, 3)
        XCTAssertEqual(screen.trashedCount, 1)
        return (dir, screen)
    }

    func testDeviceStatusCountsTheScreensFleetAndNamesTheTrashApart() throws {
        let (dir, screen) = try fleetWithTrash()
        let workbook = Workbook()
        try makeDashboard(dataDir: dir, workbook: workbook).writeSchoolDeviceStatus()
        let cells = workbook.sheet(named: "Device Status")?.dedupedCells ?? []
        func count(_ label: String) -> Int? {
            guard let name = cells.first(where: {
                if case .string(label) = $0.value { return $0.col == 0 } else { return false }
            }), let cell = cells.first(where: { $0.row == name.row && $0.col == 1 }),
                  case let .int(n) = cell.value else { return nil }
            return n
        }
        XCTAssertEqual(count("Total Devices"), screen.devices.count)
        XCTAssertEqual(count("Managed"), screen.managedCount)
        XCTAssertEqual(count("Unmanaged"), screen.unmanagedCount)
        XCTAssertEqual(count("Supervised"), screen.supervisedCount)
        XCTAssertEqual(count("In Trash (not counted above)"), screen.trashedCount)
    }

    func testTheGeneratedStampIsTheRunsStartNotTheClock() throws {
        let (dir, _) = try fleetWithTrash()
        let workbook = Workbook()
        try makeDashboard(dataDir: dir, workbook: workbook).writeSchoolDeviceStatus()
        let stamp = ISO8601DateFormatter().string(from: .testNoon)
        XCTAssertTrue(strings(in: "Device Status", of: workbook).contains("Generated: \(stamp)"))
    }

    func testDeviceInventoryLeavesTrashedDevicesOut() throws {
        let (dir, screen) = try fleetWithTrash()
        let workbook = Workbook()
        try makeDashboard(dataDir: dir, workbook: workbook).writeSchoolDeviceInventory()
        let serials = strings(in: "Device Inventory", of: workbook).filter {
            $0.hasPrefix("SCHOOL-SERIAL-")
        }
        XCTAssertEqual(serials.count, screen.devices.count)
        XCTAssertFalse(serials.contains("SCHOOL-SERIAL-003"))
    }

    func testOSVersionsLeavesTrashedDevicesOut() throws {
        let (dir, screen) = try fleetWithTrash()
        let workbook = Workbook()
        try makeDashboard(dataDir: dir, workbook: workbook).writeSchoolOSVersions()
        XCTAssertEqual(ints(in: "OS Versions", of: workbook).reduce(0, +), screen.devices.count)
        XCTAssertFalse(strings(in: "OS Versions", of: workbook).contains("iPadOS 17"))
    }

    func testStaleDevicesLeavesTrashedDevicesOutAndAgreesWithTheScreen() throws {
        let (dir, screen) = try fleetWithTrash()
        let workbook = Workbook()
        try makeDashboard(dataDir: dir, workbook: workbook).writeSchoolStaleDevices()
        let serials = strings(in: "Stale Devices", of: workbook).filter {
            $0.hasPrefix("SCHOOL-SERIAL-")
        }
        XCTAssertEqual(serials, ["SCHOOL-SERIAL-002"])
        XCTAssertEqual(serials.count, screen.staleCount(atDays: 30, now: .testNoon))
    }

    func testUsersLeavesTrashedUsersOut() throws {
        let rows = [
            SchoolRows.row("school-users", 1),
            SchoolRows.row("school-users", 2, ["inTrash": true]),
        ]
        let workbook = Workbook()
        try makeDashboard(
            dataDir: try tempDataDir(writing: rows, kind: "school-users"), workbook: workbook
        ).writeSchoolUsers()
        let users = strings(in: "Users", of: workbook).filter { $0.hasPrefix("school-user-") }
        XCTAssertEqual(users, ["school-user-001"])
    }
}

final class SchoolDashboardSheetNamesTests: XCTestCase {
    /// The Generate sheet lists `sheetNames`; the workbook writes `sheetPlan`.
    func test_sheetNames_matchTheSheetPlan() {
        let dash = SchoolDashboard(
            config: ReportConfig(), dataDir: FileManager.default.temporaryDirectory,
            workbook: Workbook(), now: .testNoon)
        XCTAssertEqual(dash.sheetPlan.map(\.name), SchoolDashboard.sheetNames)
    }
}

/// Experimental: the Blueprints tab reads `school-blueprints` (BlueprintOverview rows).
final class SchoolBlueprintsSheetTests: XCTestCase {
    private func dataDir(_ json: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-school-bp-\(UUID().uuidString)")
        let kind = tmp.appendingPathComponent("school-blueprints", isDirectory: true)
        try FileManager.default.createDirectory(at: kind, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: kind.appendingPathComponent("school-blueprints_fixture.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        return tmp
    }

    func test_blueprintsSheet_readsOverviewRows_andToleratesMissingOptionals() throws {
        let json = """
        [
          {"id": "b1", "name": "Update software", "description": "Keep current",
           "deploymentState": {"state": "OUT_OF_DATE",
             "lastDeployment": {"started": "2026-10-01T16:35:00Z", "state": "SUCCEEDED"}},
           "created": "2026-09-01T12:00:00Z", "updated": "2026-10-02T09:00:00Z"},
          {"id": "b2", "name": "Fresh",
           "deploymentState": {"state": "NOT_DEPLOYED"},
           "created": "2026-10-03T12:00:00Z", "updated": "2026-10-03T12:00:00Z"}
        ]
        """
        let workbook = Workbook()
        let dash = SchoolDashboard(
            config: ReportConfig(), dataDir: try dataDir(json), workbook: workbook,
            now: .testNoon)
        XCTAssertNoThrow(try dash.writeSchoolBlueprints())
        let cells = (workbook.sheet(named: "Blueprints")?.dedupedCells ?? []).compactMap {
            if case let .string(s) = $0.value { return s } else { return nil }
        }
        for expected in ["Name", "State", "Last deployed", "Created", "Updated",
                         "Update software", "Out of date", "2026-10-01T16:35:00Z",
                         "Fresh", "Not deployed", "2026-10-03T12:00:00Z"] {
            XCTAssertTrue(cells.contains(expected), expected)
        }
    }

    func test_blueprintsSheet_isSkippedWithoutASnapshot() {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-school-bp-none-\(UUID().uuidString)")
        let dash = SchoolDashboard(
            config: ReportConfig(), dataDir: empty, workbook: Workbook(), now: .testNoon)
        XCTAssertThrowsError(try dash.writeSchoolBlueprints())
    }

    func test_sheetNames_areTheOldListPlusBlueprintsAndTrends() {
        let old = ["School Overview", "Device Groups", "Users", "Classes", "Apps", "Profiles",
                   "Locations", "DEP Devices", "iBeacons", "Device Inventory", "OS Versions",
                   "Device Status", "Stale Devices"]
        var expected = old
        expected.insert("Blueprints", at: old.firstIndex(of: "Device Inventory") ?? 0)
        XCTAssertEqual(SchoolDashboard.sheetNames,
                       expected + ["Trends"] + CoreDashboard.protectSheetNames)
    }
}

/// Protect works with Jamf School (2.11): the School workbook carries the Jamf Pro workbook's
/// Protect tabs, under the same names and the same protect.enabled gate.
final class SchoolDashboardProtectSheetTests: XCTestCase {
    private func dataDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-school-protect-\(UUID().uuidString)")
        let kind = tmp.appendingPathComponent("protect-alerts", isDirectory: true)
        try FileManager.default.createDirectory(at: kind, withIntermediateDirectories: true)
        try Data(#"""
        [{"computer":"lab-mac-01","created":"2026-10-01T08:00:00.000Z","eventType":"GPFSEvent",
          "severity":"High","status":"New","uuid":"a1"}]
        """#.utf8).write(to: kind.appendingPathComponent("protect-alerts_fixture.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        return tmp
    }

    func test_protectTabs_haveTheProWorkbookNames() {
        let pro = CoreDashboard(config: ReportConfig(), dataDir: FileManager.default
            .temporaryDirectory, workbook: Workbook()).sheetPlan.map(\.name)
        XCTAssertEqual(pro.filter { $0.hasPrefix("Protect ") }, CoreDashboard.protectSheetNames)
        XCTAssertEqual(Array(SchoolDashboard.sheetNames.suffix(6)), CoreDashboard.protectSheetNames)
    }

    func test_protectTabs_areWrittenOnlyWhileProtectIsEnabled() throws {
        let dir = try dataDir()
        let on = Workbook()
        let config = try ConfigLoader.loadFromString(
            "school_cli:\n  enabled: true\nprotect:\n  enabled: true\n  profile: p\n")
        SchoolDashboard(config: config, dataDir: dir, workbook: on, now: .testNoon).writeAll()
        XCTAssertNotNil(on.sheet(named: "Protect Alerts"))
        XCTAssertNotNil(on.sheet(named: "Protect Threat Overview"))

        let off = Workbook()
        let schoolOnly = try ConfigLoader.loadFromString("school_cli:\n  enabled: true\n")
        let (_, failures) = SchoolDashboard(
            config: schoolOnly, dataDir: dir, workbook: off, now: .testNoon)
            .writeAll()
        XCTAssertNil(off.sheet(named: "Protect Alerts"))
        XCTAssertEqual(failures.map(\.sheet), [])
    }

    // MARK: - Trends

    private func trendDay(
        _ date: String, macs: Int, stale: Int?, osCurrent: Double?, mobile: MobileSummary?
    ) -> DailySummary {
        DailySummary(
            date: date, totalDevices: macs, fileVaultPct: nil, compliancePct: nil,
            staleCount: stale, osCurrentPct: osCurrent, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli", mobileDeviceCount: mobile.map { $0.managed + $0.unmanaged },
            mobile: mobile)
    }

    /// Row cells of the Trends tab below its header, by row, as written.
    private func trendRows(_ workbook: Workbook) throws -> [[CellValue]] {
        let cells = try XCTUnwrap(workbook.sheet(named: "Trends")).dedupedCells
        let header = try XCTUnwrap(cells.first { cell in
            if case .string("Date") = cell.value { return true } else { return false }
        }).row
        return Dictionary(grouping: cells.filter { $0.row > header }, by: \.row)
            .sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.col < $1.col }.map(\.value) }
    }

    func testTrendsTabHasOneRowPerSummaryNewestFirstWithEachTypeApart() throws {
        let workbook = Workbook()
        let dash = SchoolDashboard(
            config: ReportConfig(), dataDir: FileManager.default.temporaryDirectory,
            workbook: workbook, summaries: [
                trendDay("2026-10-18", macs: 0, stale: nil, osCurrent: nil, mobile: MobileSummary(
                    managed: 4, unmanaged: 0, supervised: .init(met: 3, of: 4), stale: 1)),
                trendDay("2026-10-19", macs: 2, stale: 1, osCurrent: 50, mobile: nil),
            ], now: .testNoon)
        try dash.writeSchoolTrends()

        let rows = try trendRows(workbook)
        XCTAssertEqual(rows.count, 2)
        guard case .string("2026-10-19") = rows[0][0] else { return XCTFail("\(rows[0])") }
        func describe(_ row: [CellValue]) -> [String] {
            row.map {
                switch $0 {
                case .blank: return "-"
                case .int(let n): return "\(n)"
                case .double(let d): return "\(d)"
                case .string(let t): return t
                case .bool(let b): return "\(b)"
                }
            }
        }
        XCTAssertEqual(describe(rows[0]),
                       ["2026-10-19", "2", "1", "0.5", "-", "-", "-", "-", "-", "-", "-"],
                       "a Mac-only day leaves every mobile column blank")
        XCTAssertEqual(describe(rows[1]),
                       ["2026-10-18", "-", "-", "-", "4", "4", "1", "3", "4", "0.75", "-"],
                       "a mobile-only day leaves the Mac columns blank, never 0")
        XCTAssertEqual(rows[0].count, SchoolDashboard.trendColumns.count)
    }

    func testTrendsTabIsSkippedWithNoSummaries() throws {
        let workbook = Workbook()
        let dash = SchoolDashboard(
            config: ReportConfig(), dataDir: FileManager.default.temporaryDirectory,
            workbook: workbook, now: .testNoon)
        XCTAssertThrowsError(try dash.writeSchoolTrends()) { XCTAssertTrue($0 is SheetSkippable) }
        XCTAssertNil(workbook.sheet(named: "Trends"))
    }

    func testTrendsTabComesAfterTheExistingSchoolTabsAndFollowsSheetsSkip() throws {
        let dash = SchoolDashboard(
            config: ReportConfig(), dataDir: FileManager.default.temporaryDirectory,
            workbook: Workbook(), now: .testNoon)
        let names = dash.sheetPlan.map(\.name)
        XCTAssertEqual(names, SchoolDashboard.sheetNames)
        XCTAssertEqual(names.firstIndex(of: "Trends"), names.firstIndex(of: "Stale Devices")! + 1)
        let skipped = SheetsConfig(only: nil, skip: ["Trends"], order: nil)
            .applyTo(dash.sheetPlan).map(\.name)
        XCTAssertFalse(skipped.contains("Trends"))
    }
}
