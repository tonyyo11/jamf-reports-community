import XCTest
@testable import JamfReports

final class DeviceCorrelationTests: XCTestCase {

    private func pro(
        _ id: String, udid: String? = nil, serial: String = ""
    ) -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: id, source: "test")
        record.name = "Mac"
        record.jamfID = id
        record.udid = udid
        record.serial = serial
        return record
    }

    private func probe(udid: String? = nil, serial: String = "") -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: "p", source: "test")
        record.udid = udid
        record.serial = serial
        return record
    }

    private func protectRow(
        uuid: String?, serial: String?, host: String? = "host"
    ) throws -> ProtectComputerRow {
        var object: [String: Any] = [:]
        object["uuid"] = uuid
        object["serial"] = serial
        object["hostname"] = host
        let data = try JSONSerialization.data(withJSONObject: [object])
        return try XCTUnwrap(JSONDecoder().decode([ProtectComputerRow].self, from: data).first)
    }

    func testUDIDMatchesIgnoringCase() {
        let correlation = DeviceCorrelation(records: [pro("1", udid: "ABC-123")])
        XCTAssertEqual(correlation.match(probe(udid: " abc-123 ")), .matched(0, via: .udid))
    }

    func testSerialAloneMatches() {
        let correlation = DeviceCorrelation(records: [pro("1", serial: "C02ABC")])
        XCTAssertEqual(correlation.match(probe(serial: "c02abc")), .matched(0, via: .serial))
    }

    func testSameSerialDifferentUDIDIsUnmatched() {
        let correlation = DeviceCorrelation(records: [pro("1", udid: "AAA", serial: "C02ABC")])
        XCTAssertEqual(correlation.match(probe(udid: "BBB", serial: "C02ABC")), .unmatched)
    }

    func testOneSerialOnTwoRecordsIsAmbiguous() {
        let correlation = DeviceCorrelation(
            records: [pro("1", serial: "C02ABC"), pro("2", serial: "C02ABC")])
        XCTAssertEqual(correlation.match(probe(serial: "C02ABC")), .ambiguous(2))
    }

    func testStrongIdentifierBeatsSerialCandidate() {
        let correlation = DeviceCorrelation(
            records: [pro("1", udid: "AAA"), pro("2", serial: "C02ABC")])
        XCTAssertEqual(correlation.match(probe(udid: "AAA", serial: "C02ABC")),
                       .matched(0, via: .udid))
    }

    func testNoIdentifierWhenOnlyAHostnameIsKnown() throws {
        let row = try protectRow(uuid: nil, serial: nil, host: "Mac")
        let result = ProtectProCorrelation.build(protect: [row], pro: [pro("1", serial: "X")])
        XCTAssertEqual(result.noIdentifier, 1)
        XCTAssertEqual(result.matched, 0)
        XCTAssertTrue(result.notInPro.isEmpty)
    }

    func testPlaceholderSerialOverTheCapJoinsNothing() {
        let cap = DeviceRecordMerger.maxRecordsPerSharedIdentifier
        let records = (0...cap).map { pro("\($0)", serial: "0") }
        XCTAssertEqual(DeviceCorrelation(records: records).match(probe(serial: "0")), .unmatched)
    }

    func testProWithoutProtectIsWhatNoMatchedRowClaimed() throws {
        let rows = [
            try protectRow(uuid: "AAA", serial: nil),
            try protectRow(uuid: "ZZZ", serial: "NOPE"),
            try protectRow(uuid: nil, serial: nil),
            try protectRow(uuid: nil, serial: "DUP"),
        ]
        let records = [
            pro("1", udid: "aaa"), pro("2", udid: "BBB", serial: "C02B"),
            pro("3", serial: "DUP"), pro("4", serial: "DUP"),
        ]
        let result = ProtectProCorrelation.build(protect: rows, pro: records)
        XCTAssertEqual(result.protectCount, 4)
        XCTAssertEqual(result.matched, 1)
        XCTAssertEqual(result.notInPro.count, 1)
        XCTAssertEqual(result.ambiguous, 1)
        XCTAssertEqual(result.noIdentifier, 1)
        XCTAssertEqual(result.proWithoutProtect.map(\.jamfID), ["2", "3", "4"])
    }

    func testTwoProtectRowsOnOneMacClaimItOnceAndCountTheRepeatApart() throws {
        let rows = [
            try protectRow(uuid: "AAA", serial: nil),
            try protectRow(uuid: nil, serial: "C02A"),
            try protectRow(uuid: "BBB", serial: nil),
        ]
        let records = [pro("1", udid: "aaa", serial: "C02A"), pro("2", udid: "bbb")]
        let result = ProtectProCorrelation.build(protect: rows, pro: records)
        XCTAssertEqual(result.matched, 2, "each Jamf Pro Mac is claimed once")
        XCTAssertEqual(result.duplicates, 1)
        XCTAssertTrue(result.proWithoutProtect.isEmpty)
        XCTAssertEqual(result.matchedShare, .init(met: 2, of: 2), "a repeat is not a gap")
    }

    func testAnAmbiguousRowClaimsNoRecordSoItsCandidatesStayGaps() throws {
        let rows = [try protectRow(uuid: nil, serial: "DUP")]
        let records = [pro("1", serial: "DUP"), pro("2", serial: "DUP")]
        let result = ProtectProCorrelation.build(protect: rows, pro: records)
        XCTAssertEqual([result.matched, result.ambiguous], [0, 1])
        XCTAssertEqual(result.proWithoutProtect.map(\.jamfID), ["1", "2"])
        XCTAssertEqual(result.matchedShare, .init(met: 0, of: 1))
    }

    /// Keys and types of a captured `protect computers list` row; the values are invented.
    func testTheCapturedProtectRowShapeMatchesByLowercasedUUID() throws {
        let url = TestFixtures.root
            .appendingPathComponent("jamf-cli-data/protect-computers/computers_captured.json")
        let rows = try JSONDecoder().decode(
            [ProtectComputerRow].self, from: Data(contentsOf: url))
        XCTAssertEqual(rows.map(\.osString), ["macOS 15.7.3", "macOS 26.1"])
        XCTAssertEqual(rows.map(\.planName), ["Fixture MDE", "Fixture MDE"])
        XCTAssertEqual(rows.map(\.fullDiskAccess), [true, true])
        let records = [
            pro("1", udid: "0F1E2D3C-4B5A-6978-8A9B-0C1D2E3F4A5B"), pro("2", serial: "OTHER"),
        ]
        let result = ProtectProCorrelation.build(protect: rows, pro: records)
        XCTAssertEqual(result.matched, 1)
        XCTAssertEqual(result.notInPro.map(\.serial), ["F1X7URE0B2"])
        XCTAssertEqual(result.proWithoutProtect.map(\.jamfID), ["2"])
    }

    // MARK: - Jamf School (2.11)

    /// jamf-cli's flattened `school devices list` row, through the reader the screens use.
    private func schoolDevice(
        _ name: String, udid: String = "", serial: String = "", os: String = "macOS 26.6.2"
    ) -> SchoolFleetService.Device {
        SchoolFleetService.device(
            from: SchoolRows.device(
                1, ["name": name, "udid": udid, "serialNumber": serial, "os": os]),
            index: 0)
    }

    func testProtectMatchesSchoolDevicesByUDIDThenSerialNeverByName() throws {
        let rows = [
            try protectRow(uuid: "aaaa-1111", serial: nil, host: "Lab-1"),
            try protectRow(uuid: nil, serial: "C02X", host: "Lab-2"),
            try protectRow(uuid: "ffff-9999", serial: nil, host: "Cart-iPad"),
            try protectRow(uuid: nil, serial: "DUP"),
        ]
        let school = [
            schoolDevice("Lab-1", udid: "AAAA-1111"),
            schoolDevice("Lab-2", udid: "BBBB-2222", serial: "c02x"),
            schoolDevice("Cart-iPad", udid: "CCCC", os: "iPadOS 26.1"),
            schoolDevice("Lab-3", serial: "DUP"), schoolDevice("Lab-4", serial: "DUP"),
            schoolDevice("Lab-5", udid: "EEEE"),
        ]
        let result = ProtectProCorrelation.build(protect: rows, school: school)
        XCTAssertEqual(result.inventory, .jamfSchool)
        XCTAssertEqual(result.matched, 2, "UDID ignoring case, then serial")
        XCTAssertEqual(result.notInPro.map(\.hostName), ["Cart-iPad"], "a name never matches")
        XCTAssertEqual(result.ambiguous, 1)
        XCTAssertEqual(result.proWithoutProtect.map(\.name), ["Lab-3", "Lab-4", "Lab-5"],
                       "only Macs count as School devices without Protect")
    }

    func testTheSchoolMatchReadsTheSchoolDevicesSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-school-match-\(UUID().uuidString)", isDirectory: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let devices = root.appendingPathComponent("campus/jamf-cli-data/school-devices",
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        let rows = [try protectRow(uuid: "aaaa", serial: nil)]
        XCTAssertNil(ProtectProCorrelation.load(
            protect: rows, profile: "campus", demoMode: false, school: true))
        try SchoolRows.write(
            [SchoolRows.device(1, ["name": "Lab-1", "udid": "AAAA", "os": "macOS 26.6.2"])],
            kind: "school-devices", into: root.appendingPathComponent("campus/jamf-cli-data"),
            stamp: "20261020T090000")
        let match = try XCTUnwrap(ProtectProCorrelation.load(
            protect: rows, profile: "campus", demoMode: false, school: true))
        XCTAssertEqual([match.matched, match.proWithoutProtect.count], [1, 0])
    }

    func testMatchedShareCountsOnlyIdentifiedComputersAndNeedsAnInventory() {
        var c = ProtectProCorrelation(protectCount: 5)
        c.noIdentifier = 1
        c.matched = 2
        c.inventorySize = 4
        XCTAssertEqual(c.identified, 4)
        XCTAssertEqual(c.matchedShare, .init(met: 2, of: 4))
        c.inventorySize = 0
        XCTAssertNil(c.matchedShare)
        c.inventorySize = 4
        c.duplicates = 1
        XCTAssertEqual(c.matchedShare, .init(met: 2, of: 3), "a repeat leaves the denominator")
        c.noIdentifier = 5
        XCTAssertNil(c.matchedShare)
    }
}
