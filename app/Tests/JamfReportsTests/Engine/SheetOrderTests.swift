import Foundation
import XCTest
@testable import JamfReports

/// Tests for `sheets.order` tab ordering in `SheetsConfig.applyTo(_:)`.
///
/// Covers: default order preserved, custom order applied, unknown names in `order`
/// skipped without crash, unordered sheets appended after ordered ones,
/// combined with `skip`, combined with `only`.
final class SheetOrderTests: XCTestCase {

    // MARK: - Helpers

    private typealias Plan = [(name: String, write: () -> Void)]

    private func plan(_ names: [String]) -> Plan {
        names.map { name in (name: name, write: {}) }
    }

    private func names(_ plan: Plan) -> [String] {
        plan.map { $0.name }
    }

    private func sheets(only: [String]? = nil,
                        skip: [String]? = nil,
                        order: [String]? = nil) -> SheetsConfig {
        var s = SheetsConfig()
        s.only = only
        s.skip = skip
        s.order = order
        return s
    }

    // MARK: - Default order preserved when `order` is nil

    func testDefaultOrderPreservedWhenOrderNil() {
        let input = plan(["A", "B", "C", "D"])
        let result = sheets().applyTo(input)
        XCTAssertEqual(names(result), ["A", "B", "C", "D"])
    }

    func testDefaultOrderPreservedWhenOrderEmpty() {
        let input = plan(["A", "B", "C"])
        let result = sheets(order: []).applyTo(input)
        XCTAssertEqual(names(result), ["A", "B", "C"])
    }

    // MARK: - Custom order applied

    func testCustomOrderReordersAllSheets() {
        let input = plan(["A", "B", "C"])
        let result = sheets(order: ["C", "B", "A"]).applyTo(input)
        XCTAssertEqual(names(result), ["C", "B", "A"])
    }

    func testCustomOrderPartialListAppendsRemainder() {
        let input = plan(["A", "B", "C", "D"])
        let result = sheets(order: ["C", "A"]).applyTo(input)
        // C and A come first; B and D append in their default order.
        XCTAssertEqual(names(result), ["C", "A", "B", "D"])
    }

    func testCustomOrderIsCaseInsensitive() {
        let input = plan(["Fleet Overview", "Security Posture", "Patch Compliance"])
        let result = sheets(order: ["patch compliance", "fleet overview"]).applyTo(input)
        XCTAssertEqual(names(result), ["Patch Compliance", "Fleet Overview", "Security Posture"])
    }

    // MARK: - Unknown names in `order` skipped without crash

    func testUnknownNamesInOrderAreIgnored() {
        let input = plan(["A", "B", "C"])
        let result = sheets(order: ["Z", "B", "Unknown Sheet", "A"]).applyTo(input)
        // Z and Unknown Sheet don't exist — they're silently skipped.
        XCTAssertEqual(names(result), ["B", "A", "C"])
    }

    func testAllUnknownNamesInOrderProducesDefaultOrder() {
        let input = plan(["A", "B", "C"])
        let result = sheets(order: ["X", "Y", "Z"]).applyTo(input)
        XCTAssertEqual(names(result), ["A", "B", "C"])
    }

    // MARK: - Skipped sheets stay removed

    func testSkipRemovesSheetFromOrderedOutput() {
        let input = plan(["A", "B", "C", "D"])
        let result = sheets(skip: ["B"], order: ["D", "A"]).applyTo(input)
        // B is skipped entirely; D and A are ordered first, then C.
        XCTAssertEqual(names(result), ["D", "A", "C"])
        XCTAssertFalse(names(result).contains("B"))
    }

    func testSkipCaseInsensitive() {
        let input = plan(["Fleet Overview", "Security Posture", "Patch Compliance"])
        let result = sheets(skip: ["security posture"]).applyTo(input)
        XCTAssertFalse(names(result).contains("Security Posture"))
        XCTAssertEqual(names(result), ["Fleet Overview", "Patch Compliance"])
    }

    // MARK: - Combined with `only`

    func testOnlyLimitsToSubset() {
        let input = plan(["A", "B", "C", "D"])
        let result = sheets(only: ["A", "C"]).applyTo(input)
        XCTAssertEqual(names(result), ["A", "C"])
    }

    func testOnlyAndOrderCombined() {
        let input = plan(["A", "B", "C", "D"])
        let result = sheets(only: ["A", "B", "C"], order: ["C", "A"]).applyTo(input)
        // Only A, B, C survive; then ordered C, A, remainder B.
        XCTAssertEqual(names(result), ["C", "A", "B"])
        XCTAssertFalse(names(result).contains("D"))
    }

    func testOnlyAndSkipCombined() {
        let input = plan(["A", "B", "C", "D"])
        // only includes A, B, C; skip removes B.
        let result = sheets(only: ["A", "B", "C"], skip: ["B"]).applyTo(input)
        XCTAssertEqual(names(result), ["A", "C"])
    }

    func testOnlySkipAndOrderAllCombined() {
        let input = plan(["A", "B", "C", "D", "E"])
        // only: A, B, C, D; skip: B; order: D, A → result: D, A, C
        let result = sheets(only: ["A", "B", "C", "D"], skip: ["B"], order: ["D", "A"]).applyTo(input)
        XCTAssertEqual(names(result), ["D", "A", "C"])
    }

    // MARK: - SheetsConfig decodes `order` from YAML

    func testOrderDecodesFromYAML() throws {
        let yaml = """
            sheets:
              order:
                - "Security Posture"
                - "Fleet Overview"
                - "Patch Compliance"
            """
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertEqual(config.sheets?.order, ["Security Posture", "Fleet Overview", "Patch Compliance"])
    }

    func testOrderNilWhenAbsentFromYAML() throws {
        let yaml = "sheets:\n  skip: []\n"
        let config = try ConfigLoader.loadFromString(yaml)
        XCTAssertNil(config.sheets?.order)
    }
}
