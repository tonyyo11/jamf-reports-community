import XCTest
@testable import JamfReports

/// The three Jamf Pro dates of a Mac in a `computers` snapshot, and the index that finds them
/// from a device-compliance row.
final class ComputerDatesTests: XCTestCase {

    private func item(
        id: Any? = "101", serial: String? = "SERIAL1",
        checkIn: String? = "2026-09-01T10:00:00.000Z",
        inventory: String? = "2026-08-01T10:00:00.000Z",
        contact: String? = "2026-09-20T10:00:00.000Z"
    ) -> [String: Any] {
        var general: [String: Any] = ["name": "Mac"]
        if let checkIn { general["lastCheckIn"] = checkIn }
        if let inventory { general["reportDate"] = inventory }
        general["lastContact"] = contact ?? NSNull()
        var item: [String: Any] = ["general": general]
        if let id { item["id"] = id }
        if let serial { item["hardware"] = ["serialNumber": serial] }
        return item
    }

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(DeviceInventoryService.parseDate(iso))
    }

    func testAComputersElementGivesTheThreeDatesAndIdentifiers() throws {
        let dates = ComputerDates(item: item())
        XCTAssertEqual(dates.jamfID, "101")
        XCTAssertEqual(dates.serial, "SERIAL1")
        XCTAssertEqual(dates.checkIn, try date("2026-09-01T10:00:00.000Z"))
        XCTAssertEqual(dates.inventory, try date("2026-08-01T10:00:00.000Z"))
        XCTAssertEqual(dates.contact, try date("2026-09-20T10:00:00.000Z"))
    }

    func testLastContactIsItsOwnFieldAndNullMeansNone() {
        let none = ComputerDates(item: item(contact: nil))
        XCTAssertNil(none.contact)
        XCTAssertNotNil(none.checkIn, "a null Last Contact does not touch the check-in")
        let numeric = ComputerDates(item: item(id: 42))
        XCTAssertEqual(numeric.jamfID, "42")
    }

    func testTheOlderAndFlatNamesStillRead() throws {
        let v3 = ComputerDates(item: ["general": [
            "lastContactTime": "2024-01-02T03:04:05Z", "reportDate": "2023-12-01T00:00:00Z",
        ]])
        XCTAssertEqual(v3.checkIn, try date("2024-01-02T03:04:05Z"))
        XCTAssertEqual(v3.inventory, try date("2023-12-01T00:00:00Z"))
        let flat = ComputerDates(item: ["last_check_in": "2020-01-01", "serial": "x"])
        XCTAssertEqual(flat.checkIn, try date("2020-01-01"))
        XCTAssertNil(flat.contact, "a flat last_contact is the check-in, never Jamf's Last Contact")
    }

    func testASnapshotDecodesFromAnArrayOrAResultsEnvelope() throws {
        let array = try JSONSerialization.data(withJSONObject: [item(), item(id: "102")])
        XCTAssertEqual(ComputerDates.decodeSnapshot(array)?.count, 2)
        let envelope = try JSONSerialization.data(withJSONObject: ["results": [item()]])
        XCTAssertEqual(ComputerDates.decodeSnapshot(envelope)?.count, 1)
        XCTAssertNil(ComputerDates.decodeSnapshot(Data("{\"a\":1}".utf8)))
        XCTAssertNil(ComputerDateIndex(snapshot: Data("nope".utf8)))
    }

    func testTheIndexJoinsByJamfIDThenSerial() {
        let index = ComputerDateIndex([
            ComputerDates(item: item(id: "1", serial: "AAA")),
            ComputerDates(item: item(id: "2", serial: "BBB")),
            ComputerDates(item: item(id: nil, serial: "NOID")),
        ])
        XCTAssertEqual(index.match(jamfID: "2", serial: nil)?.serial, "BBB")
        XCTAssertEqual(index.match(jamfID: nil, serial: "aaa ")?.jamfID, "1",
                       "a serial is trimmed and read ignoring case")
        XCTAssertEqual(index.match(jamfID: "9", serial: "NOID")?.serial, "NOID",
                       "an ID the snapshot lacks falls to the serial of a record with no ID")
        XCTAssertNil(index.match(jamfID: nil, serial: "ZZZ"))
        XCTAssertNil(index.match(jamfID: nil, serial: nil))
    }

    func testASerialNeverJoinsTwoRecordsWhoseIDsDiffer() {
        let index = ComputerDateIndex([ComputerDates(item: item(id: "1", serial: "AAA"))])
        XCTAssertNil(index.match(jamfID: "2", serial: "AAA"),
                     "a row with another Jamf ID is another Mac, whatever the serial says")
    }

    func testAnIdentifierTwoMacsShareFindsNeither() {
        let index = ComputerDateIndex([
            ComputerDates(item: item(id: "1", serial: "SHARED")),
            ComputerDates(item: item(id: "2", serial: "SHARED")),
            ComputerDates(item: item(id: "3", serial: "OWN")),
        ])
        XCTAssertNil(index.match(jamfID: nil, serial: "SHARED"),
                     "a logic-board swap leaves two records on one serial")
        XCTAssertEqual(index.match(jamfID: "1", serial: "SHARED")?.jamfID, "1",
                       "the Jamf ID still finds its own")
        XCTAssertEqual(index.match(jamfID: nil, serial: "OWN")?.jamfID, "3")
    }
}
