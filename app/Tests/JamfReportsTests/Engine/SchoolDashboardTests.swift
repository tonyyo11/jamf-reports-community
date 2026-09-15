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

    private var fixturesDir: URL { TestFixtures.root }

    private func tempDataDir(copying names: [String]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-school-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        createdTempDirs.append(tmp)
        let src = fixturesDir.appendingPathComponent("jamf-cli-data")
        for name in names {
            let from = src.appendingPathComponent(name, isDirectory: true)
            let to = tmp.appendingPathComponent(name, isDirectory: true)
            try? TestFixtures.copyDir(from, to: to)
        }
        return tmp
    }

    private func makeDashboard(dataDir: URL) -> SchoolDashboard {
        SchoolDashboard(config: ReportConfig(), dataDir: dataDir, workbook: Workbook())
    }

    // MARK: - iBeacons

    func testWriteSchoolIBeaconsHappyPath() throws {
        let dataDir = try tempDataDir(copying: ["school-ibeacons"])
        let fixtureDir = dataDir.appendingPathComponent("school-ibeacons")
        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            throw XCTSkip("school-ibeacons fixture not available")
        }
        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeSchoolIBeacons())
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

    func testWriteSchoolDepDevicesHappyPath() throws {
        let dataDir = try tempDataDir(copying: ["school-dep-devices"])
        let fixtureDir = dataDir.appendingPathComponent("school-dep-devices")
        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            throw XCTSkip("school-dep-devices fixture not available")
        }
        let dash = makeDashboard(dataDir: dataDir)
        XCTAssertNoThrow(try dash.writeSchoolDepDevices())
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
        let dataDir = try tempDataDir(copying: ["school-ibeacons", "school-dep-devices"])
        let ibeaconsDir = dataDir.appendingPathComponent("school-ibeacons")
        let depDir = dataDir.appendingPathComponent("school-dep-devices")
        guard FileManager.default.fileExists(atPath: ibeaconsDir.path),
              FileManager.default.fileExists(atPath: depDir.path) else {
            throw XCTSkip("school fixture(s) not available")
        }
        let dash = makeDashboard(dataDir: dataDir)
        let (written, failures) = dash.writeAll()
        XCTAssertTrue(written.contains("iBeacons"), "Expected iBeacons sheet to be written")
        XCTAssertTrue(written.contains("DEP Devices"), "Expected DEP Devices sheet to be written")
        XCTAssertTrue(failures.isEmpty, "No unexpected failures expected for valid fixture data")
    }

    // MARK: - SchoolCSVDashboard nil-init on empty data

    func testSchoolCSVDashboardNilOnEmpty() {
        let result = SchoolCSVDashboard(
            config: ReportConfig(),
            csvData: Data(),
            workbook: Workbook()
        )
        XCTAssertNil(result)
    }

    func testSchoolCSVDashboardNonNilOnData() {
        let result = SchoolCSVDashboard(
            config: ReportConfig(),
            csvData: Data("name,serial\nfoo,bar".utf8),
            workbook: Workbook()
        )
        XCTAssertNotNil(result)
    }

    // MARK: - iBeacons fixture data validates expected columns

    func testIBeaconsFixtureDecodesExpectedFields() throws {
        let dataDir = try tempDataDir(copying: ["school-ibeacons"])
        let fixtureDir = dataDir.appendingPathComponent("school-ibeacons")
        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            throw XCTSkip("school-ibeacons fixture not available")
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: fixtureDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" && $0.lastPathComponent.contains("happy") }
        guard let file = files.first else { throw XCTSkip("happy fixture not found") }
        let data = try Data(contentsOf: file)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let items = json as? [[String: Any]], !items.isEmpty else {
            throw XCTSkip("Empty iBeacons fixture")
        }
        let first = items[0]
        XCTAssertNotNil(first["name"], "iBeacon should have name field")
        XCTAssertNotNil(first["uuid"], "iBeacon should have uuid field")
    }

    // MARK: - DEP devices fixture validates expected columns

    func testDepDevicesFixtureDecodesExpectedFields() throws {
        let dataDir = try tempDataDir(copying: ["school-dep-devices"])
        let fixtureDir = dataDir.appendingPathComponent("school-dep-devices")
        guard FileManager.default.fileExists(atPath: fixtureDir.path) else {
            throw XCTSkip("school-dep-devices fixture not available")
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: fixtureDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" && $0.lastPathComponent.contains("happy") }
        guard let file = files.first else { throw XCTSkip("happy fixture not found") }
        let data = try Data(contentsOf: file)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let items = json as? [[String: Any]], !items.isEmpty else {
            throw XCTSkip("Empty DEP devices fixture")
        }
        let first = items[0]
        XCTAssertNotNil(first["serialNumber"] ?? first["serial"], "DEP device should have serial field")
        XCTAssertNotNil(first["model"], "DEP device should have model field")
    }

    // MARK: - jamf-cli shape helpers
    //
    // These fixtures mirror jamf-cli's flatten* functions verbatim (exact keys
    // and JSON types), not the pre-2026-09 guessed key names the readers used
    // to look for. See internal/commands/school_*.go in jamf-cli and
    // jamfschool/*.go in jamfschool-go-sdk for the source of truth.

    /// Write raw jamf-cli-shaped JSON directly into a temp `<kind>/` dir,
    /// bypassing the committed-fixture directories `tempDataDir(copying:)` uses.
    private func tempDataDir(writing json: String, kind: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-school-\(UUID().uuidString)")
        let kindDir = tmp.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        createdTempDirs.append(tmp)
        try Data(json.utf8).write(to: kindDir.appendingPathComponent("\(kind)_fixture.json"))
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
    /// device_test.go). `extraSeconds` keeps the value safely on one side of
    /// a day boundary regardless of test execution delay.
    private func schoolCheckinString(daysAgo: Int, extraSeconds: TimeInterval = 3600) -> String {
        let date = Date().addingTimeInterval(-(Double(daysAgo) * 86400) - extraSeconds)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: - School Overview: flattenSchoolOverviewRow shape

    func testSchoolOverviewReadsResourceAndValueFieldsNotDictKeys() throws {
        let json = """
        [
          {"section": "Devices", "resource": "Devices", "value": "42"},
          {"section": "Devices", "resource": "Device Groups", "value": "3"},
          {"section": "Users & Organization", "resource": "Users", "value": "128"}
        ]
        """
        let dataDir = try tempDataDir(writing: json, kind: "school-overview")
        let workbook = Workbook()
        let dash = SchoolDashboard(config: ReportConfig(), dataDir: dataDir, workbook: workbook)
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
        let json = """
        [
          {"id": 1, "name": "iPad Cart A", "description": "", "isSmartGroup": false,
           "members": 24, "shared": true, "type": "static", "locationId": 42}
        ]
        """
        let dataDir = try tempDataDir(writing: json, kind: "school-device-groups")
        let workbook = Workbook()
        let dash = SchoolDashboard(config: ReportConfig(), dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolDeviceGroups())
        XCTAssertTrue(strings(in: "Device Groups", of: workbook).contains("iPad Cart A"))
        XCTAssertTrue(ints(in: "Device Groups", of: workbook).contains(24),
                       "device count comes from `members`, not a guessed key")
        XCTAssertTrue(strings(in: "Device Groups", of: workbook).contains("42"),
                       "falls back to the numeric locationId when no name list is present")
    }

    // MARK: - Users: flattenSchoolUser shape

    func testUsersReadsStatusAndLocationId() throws {
        let json = """
        [
          {"id": 5, "username": "jdoe", "email": "jdoe@school.edu", "firstName": "Jane",
           "lastName": "Doe", "status": "Active", "deviceCount": 2, "locationId": 7,
           "inTrash": false}
        ]
        """
        let dataDir = try tempDataDir(writing: json, kind: "school-users")
        let workbook = Workbook()
        let dash = SchoolDashboard(config: ReportConfig(), dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolUsers())
        let cells = strings(in: "Users", of: workbook)
        XCTAssertTrue(cells.contains("jdoe"))
        XCTAssertTrue(cells.contains("Jane"))
        XCTAssertTrue(cells.contains("Doe"))
        XCTAssertTrue(cells.contains("jdoe@school.edu"))
        XCTAssertTrue(cells.contains("Active"),
                       "Status column reads `status`; jamf-cli has no role")
        XCTAssertTrue(cells.contains("7"), "falls back to the numeric locationId")
    }

    // MARK: - Classes: flattenSchoolClass shape

    func testClassesReadsTeacherCountAndLocationId() throws {
        let json = """
        [
          {"uuid": "abc-123", "name": "Homeroom 4B", "description": "", "source": "manual",
           "studentCount": 18, "teacherCount": 3, "deviceCount": 18, "locationId": 11}
        ]
        """
        let dataDir = try tempDataDir(writing: json, kind: "school-classes")
        let workbook = Workbook()
        let dash = SchoolDashboard(config: ReportConfig(), dataDir: dataDir, workbook: workbook)
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
        let json = """
        [
          {"id": 88, "locationId": 1, "bundleId": "com.example.reader", "adamId": 12345,
           "name": "Example Reader", "vendor": "Example Vendor Inc.", "version": "3.2.1",
           "platform": "iOS"}
        ]
        """
        let dataDir = try tempDataDir(writing: json, kind: "school-apps")
        let workbook = Workbook()
        let dash = SchoolDashboard(config: ReportConfig(), dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolApps())
        let cells = strings(in: "Apps", of: workbook)
        XCTAssertTrue(cells.contains("Example Reader"))
        XCTAssertTrue(cells.contains("com.example.reader"))
        XCTAssertTrue(cells.contains("Example Vendor Inc."),
                       "jamf-cli has no per-app install/managed count; Vendor replaces it")
        XCTAssertTrue(cells.contains("iOS"), "Platform replaces the unavailable Managed column")
    }

    // MARK: - Profiles: flattenSchoolProfile shape

    func testProfilesReadsIdentifierPlatformAndLocation() throws {
        let json = """
        [
          {"id": 4, "locationId": 6, "identifier": "com.example.wifi.profile",
           "name": "Campus WiFi", "description": "", "platform": "Shared"}
        ]
        """
        let dataDir = try tempDataDir(writing: json, kind: "school-profiles")
        let workbook = Workbook()
        let dash = SchoolDashboard(config: ReportConfig(), dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolProfiles())
        let cells = strings(in: "Profiles", of: workbook)
        XCTAssertTrue(cells.contains("Campus WiFi"))
        XCTAssertTrue(cells.contains("com.example.wifi.profile"),
                       "jamf-cli has no per-profile category; Identifier replaces it")
        XCTAssertTrue(cells.contains("Shared"), "Platform replaces the unavailable Devices column")
        XCTAssertTrue(cells.contains("6"), "Location replaces the unavailable Enabled column")
    }

    // MARK: - Locations: flattenSchoolLocation shape

    func testLocationsReadsIsDistrictAndCity() throws {
        let json = """
        [
          {"id": 2, "name": "Main Campus", "isDistrict": true, "source": "manual",
           "city": "Springfield"},
          {"id": 3, "name": "Annex", "isDistrict": false, "source": "manual"}
        ]
        """
        let dataDir = try tempDataDir(writing: json, kind: "school-locations")
        let workbook = Workbook()
        let dash = SchoolDashboard(config: ReportConfig(), dataDir: dataDir, workbook: workbook)
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

    private func deviceFixtureJSON() -> String {
        """
        [
          {"name": "Mac-Lab-01", "udid": "UDID-1", "serialNumber": "C02AAA111",
           "model": "MacBook Air", "os": "macOS 14.3", "isManaged": true,
           "isSupervised": true, "lastCheckin": "\(schoolCheckinString(daysAgo: 5))",
           "inTrash": false},
          {"name": "iPad-12", "udid": "UDID-2", "serialNumber": "DLXBBB222",
           "model": "iPad Air", "os": "iPadOS 17.4", "isManaged": true,
           "isSupervised": false, "lastCheckin": "\(schoolCheckinString(daysAgo: 40))",
           "inTrash": false},
          {"name": "iPad-13", "udid": "UDID-3", "serialNumber": "DLXCCC333",
           "model": "iPad (9th gen)", "os": "iPadOS 17.4", "isManaged": false,
           "isSupervised": false, "lastCheckin": "\(schoolCheckinString(daysAgo: 3))",
           "inTrash": false}
        ]
        """
    }

    func testDeviceInventoryReadsOSAndIsManaged() throws {
        let dataDir = try tempDataDir(writing: deviceFixtureJSON(), kind: "school-devices")
        let workbook = Workbook()
        let dash = SchoolDashboard(config: ReportConfig(), dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolDeviceInventory())
        let cells = strings(in: "Device Inventory", of: workbook)
        XCTAssertTrue(cells.contains("Mac-Lab-01"))
        XCTAssertTrue(cells.contains("C02AAA111"))
        XCTAssertTrue(cells.contains("macOS 14.3"), "OS Version reads `os`, not `osVersion`")
        XCTAssertTrue(cells.contains("Yes"), "Managed reads `isManaged`, not `managed`")
        XCTAssertTrue(cells.contains("No"))
    }

    func testOSVersionsGroupsByMajorVersionDespiteNamePrefix() throws {
        let dataDir = try tempDataDir(writing: deviceFixtureJSON(), kind: "school-devices")
        let workbook = Workbook()
        let dash = SchoolDashboard(config: ReportConfig(), dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolOSVersions())
        let cells = strings(in: "OS Versions", of: workbook)
        XCTAssertTrue(cells.contains("14"), "major version extracted past the \"macOS \" prefix")
        XCTAssertTrue(cells.contains("17"), "major version extracted past the \"iPadOS \" prefix")
        let counts = ints(in: "OS Versions", of: workbook)
        XCTAssertTrue(counts.contains(2), "both iPadOS 17.4 devices grouped into one bucket")
    }

    func testDeviceStatusCountsIsManagedAndIsSupervised() throws {
        let dataDir = try tempDataDir(writing: deviceFixtureJSON(), kind: "school-devices")
        let workbook = Workbook()
        let dash = SchoolDashboard(config: ReportConfig(), dataDir: dataDir, workbook: workbook)
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
        let dataDir = try tempDataDir(writing: deviceFixtureJSON(), kind: "school-devices")
        let workbook = Workbook()
        let dash = SchoolDashboard(config: ReportConfig(), dataDir: dataDir, workbook: workbook)
        XCTAssertNoThrow(try dash.writeSchoolStaleDevices())
        let cells = strings(in: "Stale Devices", of: workbook)
        XCTAssertTrue(cells.contains("iPad-12"), "the 40-day-stale device is listed")
        XCTAssertFalse(cells.contains("Mac-Lab-01"), "the 5-day device is well under the threshold")
        XCTAssertFalse(cells.contains("iPad-13"), "the 3-day device is well under the threshold")
        XCTAssertTrue(ints(in: "Stale Devices", of: workbook).contains(40),
                       "days-since-checkin parses jamf-cli's \"yyyy-MM-dd HH:mm:ss\" format")
    }
}
