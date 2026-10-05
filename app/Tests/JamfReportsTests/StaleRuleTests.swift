import XCTest
@testable import JamfReports

/// `StaleRule`: the one definition of a stale Mac. Dates are built from a fixed `now`, so
/// every age is exact.
final class StaleRuleTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func rule(_ basis: [StaleBasis], days: Int = 30) -> StaleRule {
        StaleRule(days: days, basis: basis)
    }

    // MARK: - Words and ordering

    func testBasisWordsAreReadIgnoringCaseAndSeparators() {
        XCTAssertEqual(StaleBasis.parse("check_in"), .checkIn)
        XCTAssertEqual(StaleBasis.parse(" Check-In "), .checkIn)
        XCTAssertEqual(StaleBasis.parse("INVENTORY"), .inventory)
        XCTAssertEqual(StaleBasis.parse("contact"), .contact)
        XCTAssertNil(StaleBasis.parse("last_seen"))
        XCTAssertNil(StaleBasis.parse(""))
    }

    func testTheBasisKeepsTheCanonicalOrderOnceEachAndIsNeverEmpty() {
        XCTAssertEqual(rule([.contact, .checkIn, .contact]).basis, [.checkIn, .contact])
        XCTAssertEqual(rule([]).basis, [.checkIn], "an empty basis is the default")
        XCTAssertTrue(rule([]).usesDefaultBasis)
        XCTAssertFalse(rule([.checkIn, .inventory]).usesDefaultBasis)
        XCTAssertFalse(rule([.checkIn]).needsComputers)
        XCTAssertTrue(rule([.checkIn, .contact]).needsComputers)
    }

    // MARK: - Whole days, floor, boundary

    func testAgesAreWholeDaysRoundedDown() {
        XCTAssertEqual(StaleRule.wholeDays(from: ago(30), to: now), 30)
        XCTAssertEqual(StaleRule.wholeDays(from: ago(30.999), to: now), 30)
        XCTAssertEqual(StaleRule.wholeDays(from: ago(31), to: now), 31)
        XCTAssertEqual(StaleRule.wholeDays(from: ago(0.5), to: now), 0)
        XCTAssertLessThan(StaleRule.wholeDays(from: ago(-2), to: now), 0,
                          "a future date is negative")
    }

    func testAMacAtExactlyTheThresholdIsNotStaleAndOneWholeDayLaterIs() {
        let r = rule([.checkIn])
        XCTAssertFalse(r.isStale(StaleInputs(checkIn: ago(30)), now: now))
        XCTAssertFalse(r.isStale(StaleInputs(checkIn: ago(30.999)), now: now),
                       "30 whole days and 23 hours is still 30 days")
        XCTAssertTrue(r.isStale(StaleInputs(checkIn: ago(31)), now: now))
    }

    func testTheBoundaryHoldsForEveryListedDate() {
        for basis in StaleBasis.allCases {
            let r = rule([basis])
            func inputs(_ days: Double) -> StaleInputs {
                switch basis {
                case .checkIn: StaleInputs(checkIn: ago(days))
                case .inventory: StaleInputs(inventory: ago(days))
                case .contact: StaleInputs(contact: ago(days))
                }
            }
            XCTAssertFalse(r.isStale(inputs(30), now: now), "\(basis) at exactly 30")
            XCTAssertTrue(r.isStale(inputs(31), now: now), "\(basis) at 31")
        }
    }

    // MARK: - ANY of the listed dates

    func testAMacIsStaleWhenAnyListedDateIsOlderThanTheThreshold() {
        let fresh = ago(2), old = ago(40)
        let both = rule([.checkIn, .inventory])
        XCTAssertTrue(both.isStale(StaleInputs(checkIn: fresh, inventory: old), now: now),
                      "inventory alone makes it stale")
        XCTAssertTrue(both.isStale(StaleInputs(checkIn: old, inventory: fresh), now: now))
        XCTAssertFalse(both.isStale(StaleInputs(checkIn: fresh, inventory: fresh), now: now))
        XCTAssertFalse(rule([.checkIn]).isStale(
            StaleInputs(checkIn: fresh, inventory: old), now: now),
            "inventory is not counted unless listed")
    }

    func testTheStaleAgeIsTheLargestListedAge() {
        let r = rule([.checkIn, .inventory, .contact])
        let inputs = StaleInputs(checkIn: ago(5), inventory: ago(41), contact: ago(1))
        XCTAssertEqual(r.age(of: inputs, now: now), .days(41))
        XCTAssertEqual(rule([.checkIn, .contact]).age(of: inputs, now: now), .days(5))
    }

    // MARK: - Missing dates

    func testAMissingCheckInOrInventoryOnASourceThatCarriesThemIsNever() {
        let r = rule([.checkIn, .inventory])
        let noInventory = StaleInputs(checkIn: ago(1), carriesDates: true)
        XCTAssertEqual(r.age(of: noInventory, now: now), .never)
        XCTAssertTrue(r.isStale(noInventory, now: now))
        let noCheckIn = StaleInputs(inventory: ago(1), carriesDates: true)
        XCTAssertTrue(r.isStale(noCheckIn, now: now))
        XCTAssertGreaterThan(StaleAge.never, StaleAge.days(100_000))
    }

    func testADateASourceDoesNotCarryIsLeftOutOfTheRule() {
        let r = rule([.checkIn, .inventory])
        let compliance = StaleInputs(checkInDays: 3)
        XCTAssertEqual(r.age(of: compliance, now: now), .days(3))
        XCTAssertFalse(r.isStale(compliance, now: now))
    }

    func testAMissingContactIsIgnoredEvenOnASourceThatCarriesTheOthers() {
        let r = rule([.checkIn, .contact])
        let inputs = StaleInputs(checkIn: ago(2), carriesDates: true)
        XCTAssertEqual(r.age(of: inputs, now: now), .days(2))
        XCTAssertFalse(r.isStale(inputs, now: now))
    }

    func testAMacWhoseListedDatesAreAllUnknownFallsBackToTheSourcesFlag() {
        let r = rule([.contact])
        XCTAssertNil(r.age(of: StaleInputs(checkIn: ago(100)), now: now),
                     "the check-in is not listed and the contact is unknown")
        XCTAssertTrue(r.isStale(StaleInputs(checkIn: ago(100), flag: true), now: now))
        XCTAssertFalse(r.isStale(StaleInputs(checkIn: ago(100), flag: false), now: now))
        let checkInOnly = rule([.checkIn])
        XCTAssertTrue(checkInOnly.isStale(StaleInputs(flag: true), now: now))
        XCTAssertFalse(checkInOnly.isStale(StaleInputs(flag: false), now: now))
    }

    func testTheSourcesOwnDayCountIsTheCheckInAgeWhenItGivesOne() {
        let r = rule([.checkIn])
        let inputs = StaleInputs(checkInDays: 10, checkIn: ago(100))
        XCTAssertEqual(r.age(of: inputs, now: now), .days(10))
        XCTAssertFalse(r.isStale(inputs, now: now))
    }

    func testTheDefaultBasisIsTodaysRuleForADayCountAndAFlag() {
        let r = rule([.checkIn])
        for days in 0...60 {
            XCTAssertEqual(r.isStale(StaleInputs(checkInDays: days, flag: days <= 30), now: now),
                           days > 30, "\(days) days")
        }
    }

    // MARK: - Words for screens

    func testPhrasesNameTheCountedDates() {
        XCTAssertEqual(rule([.checkIn]).basisPhrase, "check-in")
        XCTAssertEqual(rule([.checkIn, .inventory]).basisPhrase, "check-in or inventory update")
        XCTAssertEqual(rule([.checkIn, .inventory, .contact]).basisPhrase,
                       "check-in, inventory update or contact")
        XCTAssertEqual(rule([.checkIn, .inventory]).basisHeading, "Check-in or Inventory Update")
        XCTAssertEqual(rule([.checkIn]).basisHeading, "Check-in")
    }

    func testTheScoreFactorLabelNamesTheBasis() {
        XCTAssertEqual(rule([.checkIn]).checkedInLabel(), "Checked in within 30 days")
        XCTAssertEqual(rule([.checkIn, .inventory]).checkedInLabel(),
                       "Checked in and inventoried within 30 days")
        XCTAssertEqual(rule([.inventory, .contact], days: 14).checkedInLabel(),
                       "Inventoried and in contact within 14 days")
        XCTAssertEqual(rule([.checkIn, .inventory, .contact]).checkedInLabel(shortUnit: true),
                       "Checked in, inventoried and in contact within 30d")
        let factor = SecurityScoreFactor(.checkedIn, weight: 5)
        XCTAssertEqual(factor.label(staleDays: 30), "Checked in within 30 days")
        XCTAssertEqual(factor.label(staleDays: 30, staleBasis: [.checkIn, .inventory]),
                       "Checked in and inventoried within 30 days")
        XCTAssertEqual(factor.label(), "Checked in recently")
    }
}
