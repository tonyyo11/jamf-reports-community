import XCTest
@testable import JamfReports

final class FailedRuleListTests: XCTestCase {

    private func rules(_ cell: String?) -> [String]? { FailedRuleList.rules(in: cell) }

    /// mSCP's audit script writes one rule ID per line; prod's lists have no other
    /// separator. A pipe-only split read a whole 20-rule list as one rule.
    func testNewlineSeparatedListSplitsIntoRules() {
        XCTAssertEqual(rules("os_a\nos_b\naudit_c"), ["os_a", "os_b", "audit_c"])
        XCTAssertEqual(rules("os_a\r\nos_b\r\n"), ["os_a", "os_b"])
    }

    func testEverySeparatorSplitsAndEntriesAreTrimmed() {
        XCTAssertEqual(rules("os_a|os_b"), ["os_a", "os_b"])
        XCTAssertEqual(rules("os_a, os_b,os_c"), ["os_a", "os_b", "os_c"])
        XCTAssertEqual(rules("os_a; os_b"), ["os_a", "os_b"])
        XCTAssertEqual(rules("os_a\t os_b | os_c\n"), ["os_a", "os_b", "os_c"])
        XCTAssertEqual(rules("| os_a ||"), ["os_a"])
    }

    func testARuleListedTwiceCountsOnce() {
        XCTAssertEqual(rules("os_a\nos_b\nos_a"), ["os_a", "os_b"])
    }

    func testBlankCellIsAnEmptyList() {
        XCTAssertEqual(rules(nil), [])
        XCTAssertEqual(rules(""), [])
        XCTAssertEqual(rules("  \n "), [])
        XCTAssertEqual(rules("|"), [])
    }

    /// An audit that cannot evaluate a Mac writes a status where the list goes; that Mac
    /// has no list, which is neither "no failures" nor a failing rule named "No Baseline Set".
    func testStatusValuesAreNotLists() {
        for status in ["No Baseline Set", "Multiple Baselines Found", "no baseline set",
                       "None", "Pass", "N/A", "  No Baseline Set \n"] {
            XCTAssertNil(rules(status), status)
        }
    }

    func testTextWithoutARuleIDIsNotAList() {
        XCTAssertNil(rules("Audit has not run yet"))
        XCTAssertNil(rules("Could not read baseline, try again"))
    }

    func testStatusTokensInsideAListAreDropped() {
        XCTAssertEqual(rules("os_a\nNone\nos_b"), ["os_a", "os_b"])
    }
}
