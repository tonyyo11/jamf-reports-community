import XCTest
@testable import JamfReports

final class ScheduleStoreTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("schedule-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func sample(name: String = "nightly", profile: String = "alpha") -> Schedule {
        Schedule(
            name: name, profile: profile, schedule: "Daily 06:20", cadence: "daily",
            mode: .jamfCLIFull, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, tiers: [.refresh, .scan]
        )
    }

    func testAppSupportDirectoryIsCreatedPrivate() throws {
        let home = try tempDir()
        let dir = AppSupport.directory(home: home)
        XCTAssertEqual(dir.path, home.appendingPathComponent(
            "Library/Application Support/JamfReports").path)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o700)
    }

    func testRecordRoundTripsThroughSchedule() throws {
        let record = try XCTUnwrap(ScheduleRecord(schedule: sample()))
        XCTAssertEqual(record.label, "com.github.tonyyo11.jamf-reports-community.alpha.nightly")
        let back = record.toSchedule()
        XCTAssertEqual(back.name, "nightly")
        XCTAssertEqual(back.profile, "alpha")
        XCTAssertEqual(back.mode, .jamfCLIFull)
        XCTAssertEqual(back.tiers, [.refresh, .scan])
        XCTAssertEqual(back.schedule, "Daily 06:20")
        XCTAssertEqual(back.launchAgentLabel, record.label)
        XCTAssertFalse(back.isMulti)
    }

    func testMultiRecordKeepsExclusions() throws {
        var s = sample(name: "fleet")
        s.multiTarget = MultiTarget(scope: .all)
        s.excludedProfiles = ["dummy"]
        let record = try XCTUnwrap(ScheduleRecord(schedule: s))
        XCTAssertTrue(record.allProfiles)
        XCTAssertEqual(record.label, "com.github.tonyyo11.jamf-reports-community.multi.fleet")
        let back = record.toSchedule()
        XCTAssertTrue(back.isMulti)
        XCTAssertEqual(back.excludedProfiles, ["dummy"])
        XCTAssertEqual(back.profile, "")
    }

    func testRecordRefusesManagedLabelAndInvalidName() {
        var managed = sample(name: "managed-freshness")
        managed.multiTarget = MultiTarget(scope: .all)
        XCTAssertNil(ScheduleRecord(schedule: managed))
        XCTAssertNil(ScheduleRecord(schedule: sample(name: "")))
    }

    func testStoreLoadsEmptyWhenFileMissingOrCorrupt() throws {
        let url = try tempDir().appendingPathComponent("schedules.json")
        XCTAssertEqual(ScheduleStore(url: url).load(), [])
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(ScheduleStore(url: url).load(), [])
    }

    func testUpsertReplacesByLabelAndRemoveDeletes() throws {
        let url = try tempDir().appendingPathComponent("schedules.json")
        let store = ScheduleStore(url: url)
        var a = try XCTUnwrap(ScheduleRecord(schedule: sample()))
        try store.upsert(a)
        a.enabled = false
        try store.upsert(a)
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(store.load().first?.enabled, false)
        try store.remove(label: a.label)
        XCTAssertEqual(store.load(), [])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    func testDecodeIsLenientToUnknownAndMissingKeys() throws {
        let json = """
        [{"label":"com.github.tonyyo11.jamf-reports-community.alpha.x","name":"x",
          "profile":"alpha","mode":"backup","schedule":"Mon 07:00","futureKey":1}]
        """
        let url = try tempDir().appendingPathComponent("schedules.json")
        try Data(json.utf8).write(to: url)
        let records = ScheduleStore(url: url).load()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.enabled, true)
        XCTAssertEqual(records.first?.allProfiles, false)
        XCTAssertNil(records.first?.tiers)
    }
}
