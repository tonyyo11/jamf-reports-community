import Foundation
import XCTest
@testable import JamfReports

@MainActor
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

    func testMovingToANeighbourStepsOverWhatLiesBetween() {
        let order = [1, 2, 3, 4]
        XCTAssertEqual(order.moving(1, to: 3), [2, 3, 1, 4])
        XCTAssertEqual(order.moving(4, to: 2), [1, 4, 2, 3])
        XCTAssertEqual(order.moving(1, to: 9), order, "An absent neighbour changes nothing")
        XCTAssertEqual(order.moving(9, to: 1), order, "An absent element changes nothing")
    }

    // MARK: - Security-control score cards

    func testControlCardsMapToTheirSecurityControl() {
        XCTAssertEqual(TrendSeries.Metric.fileVault.securityControl, .fileVault)
        XCTAssertEqual(TrendSeries.Metric.sip.securityControl, .sip)
        XCTAssertEqual(TrendSeries.Metric.firewall.securityControl, .firewall)
        XCTAssertEqual(TrendSeries.Metric.gatekeeper.securityControl, .gatekeeper)
        let controlCards: [TrendSeries.Metric] = [.fileVault, .sip, .firewall, .gatekeeper]
        for metric in TrendSeries.Metric.allCases where !controlCards.contains(metric) {
            XCTAssertNil(metric.securityControl, "\(metric) is not a security control")
        }
    }

    /// Only a control the policy does not count hides its card; a warning is
    /// still a fact worth a card.
    func testACardIsOfferedUnlessItsControlIsIgnored() {
        let policy = SecurityControlPolicy(
            fileVault: .ignore, sip: .warning, firewall: .ignore, gatekeeper: .fail)

        XCTAssertFalse(TrendSeries.Metric.fileVault.isOffered(under: policy))
        XCTAssertFalse(TrendSeries.Metric.firewall.isOffered(under: policy))
        XCTAssertTrue(TrendSeries.Metric.sip.isOffered(under: policy))
        XCTAssertTrue(TrendSeries.Metric.gatekeeper.isOffered(under: policy))
        XCTAssertTrue(TrendSeries.Metric.stability.isOffered(under: policy))
        XCTAssertTrue(TrendSeries.Metric.edrAgent.isOffered(under: policy))
        for metric in TrendSeries.Metric.allCases {
            XCTAssertTrue(metric.isOffered(under: .default), "\(metric) under no policy")
        }
    }

    func testControlCardsNeedTheSecurityReport() {
        for metric in [TrendSeries.Metric.sip, .firewall, .gatekeeper] {
            XCTAssertEqual(metric.dataRequirement, "Needs jamf-cli's security report.")
        }
    }

    /// With no policy the editor lists what it always did: the selection in its
    /// order, then every other card in declaration order.
    func testScoreCardRowsKeepTodaysOrderUnderTheDefaultPolicy() {
        let selected: [TrendSeries.Metric] = [.patch, .fileVault]
        let rows = OverviewCustomizeSheet.scoreCardRows(selected: selected, policy: .default)

        XCTAssertEqual(
            rows, selected + TrendSeries.Metric.allCases.filter { !selected.contains($0) })
        XCTAssertEqual(Set(rows), Set(TrendSeries.Metric.allCases))
    }

    func testScoreCardRowsDropACardWhoseControlIsIgnored() {
        let policy = SecurityControlPolicy(firewall: .ignore)
        let selected: [TrendSeries.Metric] = [.firewall, .stability, .sip]
        let rows = OverviewCustomizeSheet.scoreCardRows(selected: selected, policy: policy)

        XCTAssertFalse(rows.contains(.firewall), "A card that is not offered is not listed")
        XCTAssertEqual(Array(rows.prefix(2)), [.stability, .sip])
        XCTAssertEqual(
            Set(rows), Set(TrendSeries.Metric.allCases).subtracting([.firewall]))
        XCTAssertEqual(selected, [.firewall, .stability, .sip], "The selection is not edited")
    }

    /// A hidden card sits between two listed ones; moving a listed card past its
    /// listed neighbour must change what the editor shows, not swap with the hidden one.
    func testMovingAListedCardStepsOverAHiddenOne() {
        let policy = SecurityControlPolicy(firewall: .ignore)
        let selected: [TrendSeries.Metric] = [.stability, .firewall, .sip]

        let moved = selected.moving(.sip, to: .stability)

        XCTAssertEqual(moved, [.sip, .stability, .firewall], "The hidden card stays selected")
        let rows = OverviewCustomizeSheet.scoreCardRows(selected: moved, policy: policy)
        XCTAssertEqual(Array(rows.prefix(2)), [.sip, .stability])
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
