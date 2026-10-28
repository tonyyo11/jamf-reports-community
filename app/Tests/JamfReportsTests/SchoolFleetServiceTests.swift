import XCTest
@testable import JamfReports

final class SchoolFleetServiceTests: XCTestCase {
    private var dataDir: URL!

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("school-fleet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    private func write(_ json: String, kind: String, stamp: String = "20261019T080000") throws {
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appendingPathComponent("\(kind)_\(stamp).json"))
    }

    func test_noSnapshots_isNotDetected() {
        let snapshot = SchoolFleetService.load(dataDir: dataDir)
        XCTAssertFalse(snapshot.isDetected)
        XCTAssertNil(snapshot.collectedAt)
    }

    func test_devices_readJamfCLIShape_andLeaveTrashOut() throws {
        try write(SchoolRows.json([
            SchoolRows.device(1),
            SchoolRows.device(2, [
                "model": "MacBook Air", "os": "macOS 26.6.2", "isManaged": false,
                "isSupervised": false, "lastCheckin": "2026-08-01 09:00:00",
            ], omitting: ["udid"]),
            SchoolRows.device(3, ["os": "iPadOS 18.1", "inTrash": true], omitting: [
                "isManaged", "isSupervised", "lastCheckin", "udid",
            ]),
            SchoolRows.device(4, ["os": "iOS 27.0"],
                              omitting: ["isSupervised", "lastCheckin", "udid"],
                              malformed: ["isManaged": "yes"]),
        ]), kind: SchoolFleetService.devicesKind)

        let snapshot = SchoolFleetService.load(dataDir: dataDir)
        XCTAssertTrue(snapshot.isDetected)
        XCTAssertEqual(snapshot.devices.map(\.serial),
                       ["SCHOOL-SERIAL-001", "SCHOOL-SERIAL-002", "SCHOOL-SERIAL-004"])
        XCTAssertEqual(snapshot.trashedCount, 1)
        XCTAssertEqual(snapshot.managedCount, 1)
        XCTAssertEqual(snapshot.unmanagedCount, 1, "a non-boolean managed flag is unknown")
        XCTAssertEqual(snapshot.supervisedCount, 1)
        XCTAssertEqual(snapshot.devices[0].id, "SCHOOL-UDID-001")
        XCTAssertEqual(snapshot.devices[1].id, "SCHOOL-SERIAL-002",
                       "the serial stands in for a missing udid")
        XCTAssertEqual(snapshot.devices.map(\.platform), ["iPadOS", "macOS", "iOS"])

        let now = DateParser().parse("2026-10-19 09:00:00")!
        XCTAssertEqual(snapshot.staleCount(atDays: 30, now: now), 1)
        XCTAssertFalse(snapshot.devices[2].isStale(atDays: 30, now: now),
                       "an unknown check-in is not stale")
    }

    func test_staleIsMoreThanTheThreshold() throws {
        let now = DateParser().parse("2026-10-31 09:00:00")!
        let device = SchoolFleetService.device(
            from: SchoolRows.device(1, ["lastCheckin": "2026-10-01 09:00:00"]), index: 0)
        XCTAssertFalse(device.isStale(atDays: 30, now: now), "exactly 30 days is not stale")
        XCTAssertTrue(device.isStale(atDays: 29, now: now))
    }

    func test_overviewAndDEP_rows() throws {
        try write(SchoolRows.json([
            SchoolRows.row("school-overview", 1, ["resource": "Devices", "value": "42"]),
            SchoolRows.row("school-overview", 2,
                           ["section": "People", "resource": "Users", "value": "310"]),
            SchoolRows.row("school-overview", 3, omitting: ["resource"]),
        ]), kind: SchoolFleetService.overviewKind)
        try write(SchoolRows.json([
            SchoolRows.row("school-dep-devices", 1,
                           ["deviceName": "", "profileName": "Cart profile"]),
        ]), kind: SchoolFleetService.depDevicesKind, stamp: "20261019T090000")

        let snapshot = SchoolFleetService.load(dataDir: dataDir)
        XCTAssertEqual(snapshot.overview.map(\.resource), ["Devices", "Users"])
        XCTAssertEqual(snapshot.overview[1].value, "310")
        XCTAssertEqual(snapshot.depDevices.first?.profile, "Cart profile")
        XCTAssertNil(snapshot.devicesDate)
        XCTAssertEqual(snapshot.collectedAt, snapshot.depDate)
    }

    /// A count of 0 or 1 printed as a JSON number is a number, not a boolean. The capture has
    /// `value` as a string; this is what the reader does with an older or odd number.
    func test_overviewNumbersZeroAndOneReadAsText() throws {
        let values: [Any] = [0, 1, true]
        let sent = values.enumerated().map {
            SchoolRows.row("school-overview", $0, malformed: ["value": $1])
        }
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(SchoolRows.json(sent).utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.compactMap(SchoolFleetService.overviewRow).map(\.value), ["0", "1", ""])
    }

    func test_platformCounts_largestFirst() {
        var snapshot = SchoolFleetService.Snapshot()
        snapshot.devices = ["iOS 27", "iPadOS 27", "iPadOS 26", "macOS 26"].enumerated().map {
            SchoolFleetService.device(from: SchoolRows.device($0 + 1, ["os": $1]), index: $0)
        }
        XCTAssertEqual(snapshot.platformCounts.map(\.platform), ["iPadOS", "iOS", "macOS"])
        XCTAssertEqual(snapshot.platformCounts.first?.count, 2)
    }

    func test_tabs_schoolDevicesOnlyOnSchool() {
        XCTAssertTrue(TabVisibility().limited(toSchool: true).isVisible(.schoolDevices))
        XCTAssertFalse(TabVisibility().limited(toSchool: false).isVisible(.schoolDevices))
        XCTAssertFalse(TabVisibility().limited(toSchool: true).isVisible(.devices))
    }
}
