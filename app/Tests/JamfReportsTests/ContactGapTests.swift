import XCTest
@testable import JamfReports

/// `ContactGap`: a Mac MDM reaches while its Jamf binary or its inventory has fallen behind.
final class ContactGapTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func gap(
        checkIn: Date?, inventory: Date?, contact: Date?, staleDays: Int = 30, gapDays: Int = 14
    ) -> ContactGap? {
        ContactGap.of(checkIn: checkIn, inventory: inventory, contact: contact,
                      staleDays: staleDays, gapDays: gapDays, now: now)
    }

    func testAJamfBinarySilentWhileContactIsCurrent() {
        let contact = ago(1)
        XCTAssertEqual(gap(checkIn: contact.addingTimeInterval(-20 * 86_400),
                           inventory: contact, contact: contact), .binarySilent)
    }

    func testInventoryNotUpdatingWhileTheMacChecksIn() {
        let contact = ago(1)
        XCTAssertEqual(gap(checkIn: contact.addingTimeInterval(-2 * 86_400),
                           inventory: contact.addingTimeInterval(-20 * 86_400), contact: contact),
                       .inventoryStale)
    }

    func testBothLaggingIsTheSilentBinary() {
        let contact = ago(1)
        let old = contact.addingTimeInterval(-60 * 86_400)
        XCTAssertEqual(gap(checkIn: old, inventory: old, contact: contact), .binarySilent)
    }

    func testALagOfExactlyTheGapIsNoGapAndOneDayMoreIs() {
        let contact = ago(1)
        func lagged(_ days: Double) -> Date { contact.addingTimeInterval(-days * 86_400) }
        XCTAssertNil(gap(checkIn: lagged(14), inventory: contact, contact: contact))
        XCTAssertEqual(gap(checkIn: lagged(15), inventory: contact, contact: contact),
                       .binarySilent)
        XCTAssertNil(gap(checkIn: contact, inventory: lagged(14), contact: contact))
        XCTAssertEqual(gap(checkIn: contact, inventory: lagged(15), contact: contact),
                       .inventoryStale)
        XCTAssertNil(gap(checkIn: lagged(7), inventory: lagged(7), contact: contact, gapDays: 7))
        XCTAssertEqual(gap(checkIn: lagged(8), inventory: lagged(7), contact: contact, gapDays: 7),
                       .binarySilent)
    }

    /// The lag is measured from Last Contact. Measured from today it would flag a Mac whose
    /// contact is 20 days old and whose check-in is 5 days older, which is no gap.
    func testTheLagIsMeasuredFromLastContactNotFromToday() {
        let contact = ago(20)
        let checkIn = ago(25)
        XCTAssertNil(gap(checkIn: checkIn, inventory: checkIn, contact: contact))
    }

    func testAMacWithoutALastContactIsLeftOut() {
        XCTAssertNil(gap(checkIn: ago(90), inventory: ago(90), contact: nil))
    }

    func testAMacSilentOnEveryChannelIsStaleNotAGap() {
        let old = ago(31)
        XCTAssertNil(gap(checkIn: ago(120), inventory: ago(120), contact: old),
                     "contact 31 days old is more than stale_device_days")
        XCTAssertEqual(gap(checkIn: ago(120), inventory: ago(120), contact: ago(30)),
                       .binarySilent, "contact at exactly the threshold is still current")
    }

    func testAMissingCheckInOrInventoryIsOlderThanAnyGap() {
        XCTAssertEqual(gap(checkIn: nil, inventory: ago(1), contact: ago(1)), .binarySilent)
        XCTAssertEqual(gap(checkIn: ago(1), inventory: nil, contact: ago(1)), .inventoryStale)
    }

    func testACheckInAfterTheContactIsNoLag() {
        XCTAssertNil(gap(checkIn: ago(0), inventory: ago(0), contact: ago(1)))
    }

    func testEachKindHasANameARecommendationAndALabel() {
        for kind in ContactGap.allCases {
            XCTAssertFalse(kind.findingName.isEmpty)
            XCTAssertFalse(kind.label.isEmpty)
            XCTAssertTrue(kind.recommendation(gapDays: 9).contains("9 days"))
        }
        XCTAssertTrue(ContactGap.binarySilent.recommendation(gapDays: 14).contains("jamf policy"))
        XCTAssertTrue(ContactGap.inventoryStale.recommendation(gapDays: 14).contains("jamf recon"))
    }

    // MARK: - On inventory records and snapshots

    private func record(
        _ id: String, checkIn: Date?, inventory: Date?, contact: Date?
    ) -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: id, source: "computers.json")
        record.name = "Mac-\(id)"
        record.serial = "SER\(id)"
        record.checkInDate = checkIn
        record.inventoryDate = inventory
        record.contactDate = contact
        record.carriesDates = true
        return record
    }

    func testARecordAndASnapshotGroupMacsByKind() {
        let contact = ago(1)
        let silent = record("1", checkIn: ago(40), inventory: contact, contact: contact)
        let lagging = record("2", checkIn: contact, inventory: ago(40), contact: contact)
        let fine = record("3", checkIn: contact, inventory: contact, contact: contact)
        let noContact = record("4", checkIn: ago(90), inventory: ago(90), contact: nil)
        let rule = StaleRule(days: 30)
        XCTAssertEqual(silent.contactGap(rule: rule, gapDays: 14, now: now), .binarySilent)
        XCTAssertNil(fine.contactGap(rule: rule, gapDays: 14, now: now))
        XCTAssertNil(noContact.contactGap(rule: rule, gapDays: 14, now: now))

        var snapshot = DeviceInventorySnapshot.empty
        snapshot.devices = [silent, lagging, fine, noContact]
        let groups = snapshot.contactGaps(staleDays: 30, now: now)
        XCTAssertEqual(groups[.binarySilent]?.map(\.id), ["1"])
        XCTAssertEqual(groups[.inventoryStale]?.map(\.id), ["2"])
        snapshot.contactGapDays = 60
        XCTAssertTrue(snapshot.contactGaps(staleDays: 30, now: now).isEmpty,
                      "a 60-day gap holds a 40-day lag")
    }

    func testMergingTwoRecordsKeepsTheNewestDateOfEach() {
        var first = record("1", checkIn: ago(10), inventory: ago(30), contact: nil)
        first.carriesDates = false
        let second = record("1", checkIn: ago(3), inventory: ago(50), contact: ago(2))
        first.merge(second)
        XCTAssertEqual(first.checkInDate, ago(3))
        XCTAssertEqual(first.inventoryDate, ago(30))
        XCTAssertEqual(first.contactDate, ago(2))
        XCTAssertTrue(first.carriesDates)
    }
}
