import Foundation
import XCTest
@testable import JamfReports

final class OverviewLayoutTests: XCTestCase {

    // MARK: - Defaults

    func testStandardLayoutShowsEverySectionInDeclarationOrder() {
        let layout = OverviewLayout.standard
        XCTAssertEqual(layout.order, OverviewSection.allCases)
        XCTAssertEqual(layout.visible, OverviewSection.allCases)
    }

    // MARK: - Normalization

    func testNormalizedDropsDuplicatesAndAppendsMissingSections() {
        let order = OverviewLayout.normalized([.securityAgents, .scoreCards, .securityAgents])

        XCTAssertEqual(Array(order.prefix(2)), [.securityAgents, .scoreCards])
        XCTAssertEqual(order.count, OverviewSection.allCases.count,
                       "Every section appears exactly once")
        XCTAssertEqual(Set(order), Set(OverviewSection.allCases))
    }

    // MARK: - Visibility and order

    func testHidingASectionRemovesItFromVisibleButKeepsItsPlace() {
        var layout = OverviewLayout.standard
        layout.setVisible(.recentActivity, false)

        XCTAssertFalse(layout.visible.contains(.recentActivity))
        XCTAssertTrue(layout.order.contains(.recentActivity))

        layout.setVisible(.recentActivity, true)
        XCTAssertEqual(layout.visible, OverviewSection.allCases)
    }

    func testSwapTradesPlacesAcrossAnUnlistedSection() {
        // The editor does not list the AI card on a Mac that cannot run it.
        // Moving Score Cards down trades places with the next LISTED section;
        // the unlisted card stays where it was.
        var layout = OverviewLayout(order: [.scoreCards, .aiInsight, .osDistribution])
        layout.swap(.scoreCards, with: .osDistribution)

        XCTAssertEqual(Array(layout.order.prefix(3)), [.osDistribution, .aiInsight, .scoreCards])
    }

    func testArrayMovingClampsAndLeavesAbsentElementAlone() {
        XCTAssertEqual([1, 2, 3].moving(9, by: 1), [1, 2, 3])
        XCTAssertEqual([1, 2, 3].moving(3, by: -2), [3, 1, 2])
        XCTAssertEqual([1, 2, 3].moving(1, by: -1), [1, 2, 3], "The first element cannot move up")
        XCTAssertEqual([1, 2, 3].moving(2, by: 5), [1, 3, 2], "A long move stops at the end")
    }

    // MARK: - Persistence

    func testSerializedRoundTrips() {
        var layout = OverviewLayout(order: [.recentActivity, .scoreCards])
        layout.setVisible(.aiInsight, false)
        layout.setVisible(.topFailingRules, false)

        let restored = OverviewLayout.parse(layout.serialized)
        XCTAssertEqual(restored, layout)
    }

    func testParseDropsUnknownSectionsAndFallsBackOnGarbage() {
        let raw = #"{"order":["recentActivity","futureWidget","scoreCards"],"hidden":["futureWidget"]}"#
        let layout = OverviewLayout.parse(raw)

        XCTAssertEqual(Array(layout.order.prefix(2)), [.recentActivity, .scoreCards])
        XCTAssertTrue(layout.hidden.isEmpty, "An unknown hidden entry is dropped, not kept")

        XCTAssertEqual(OverviewLayout.parse("not json"), .standard)
        XCTAssertEqual(OverviewLayout.parse(nil), .standard)
    }

    // MARK: - Rows

    func testAdjacentPairableSectionsShareARow() {
        let rows = OverviewLayout.rows(
            [.scoreCards, .osDistribution, .topFailingRules, .recentActivity],
            pairable: { $0.isHalfWidth }
        )
        XCTAssertEqual(rows, [[.scoreCards], [.osDistribution, .topFailingRules], [.recentActivity]])
    }

    func testASectionThatCannotPairTakesItsOwnRow() {
        // Top Failing Rules has nothing to show, so it renders full width and
        // macOS Distribution must not be paired with it.
        let rows = OverviewLayout.rows(
            [.osDistribution, .topFailingRules],
            pairable: { $0 == .osDistribution }
        )
        XCTAssertEqual(rows, [[.osDistribution], [.topFailingRules]])
    }

    func testHalfWidthSectionsSeparatedByAFullWidthOneDoNotPair() {
        let rows = OverviewLayout.rows(
            [.osDistribution, .scoreCards, .topFailingRules],
            pairable: { $0.isHalfWidth }
        )
        XCTAssertEqual(rows, [[.osDistribution], [.scoreCards], [.topFailingRules]])
    }
}
