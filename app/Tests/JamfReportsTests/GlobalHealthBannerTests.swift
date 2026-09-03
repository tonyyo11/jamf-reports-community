import XCTest
@testable import JamfReports

/// Headline derivation for the app-wide health strip.
///
/// The banner is the only surface that follows the operator onto every screen,
/// so what it chooses to say when several things are wrong at once matters:
/// a reproducing collection failure outranks the staleness it causes, and
/// staleness outranks a schedule issue that Overview already reports in detail.
@MainActor
final class GlobalHealthBannerTests: XCTestCase {

    private func freshness(
        _ kind: String,
        _ issueKind: DataFreshnessIssue.Kind,
        failures: Int = 0
    ) -> DataFreshnessIssue {
        DataFreshnessIssue(
            snapshotKind: kind,
            tier: .refresh,
            kind: issueKind,
            lastSuccess: Date(timeIntervalSince1970: 1_700_000_000),
            consecutiveFailures: failures,
            lastFailure: nil
        )
    }

    private func schedule(_ label: String) -> AutomationHealthIssue {
        AutomationHealthIssue(
            label: label, displayName: "Managed Reports", kind: .overdue,
            expectedFire: Date(), lastRunFinishedAt: nil
        )
    }

    func testHealthyFleetShowsNothing() {
        XCTAssertNil(GlobalHealthBanner.headline(freshness: [], automation: []))
    }

    func testFailingKindOutranksStaleAndSchedule() throws {
        let headline = try XCTUnwrap(GlobalHealthBanner.headline(
            freshness: [
                freshness("security", .stale), freshness("computers", .failing, failures: 3)
            ],
            automation: [schedule("a")]
        ))
        XCTAssertEqual(headline.tone, .danger)
        XCTAssertTrue(headline.text.contains("failing to collect"), headline.text)
        XCTAssertTrue(try XCTUnwrap(headline.detail).contains("computers"))
    }

    func testStaleOutranksSchedule() throws {
        let headline = try XCTUnwrap(GlobalHealthBanner.headline(
            freshness: [freshness("security", .stale)],
            automation: [schedule("a")]
        ))
        XCTAssertEqual(headline.tone, .warn)
        XCTAssertTrue(headline.text.contains("behind schedule"), headline.text)
    }

    func testScheduleIssueSurfacesWhenDataIsFine() throws {
        let headline = try XCTUnwrap(GlobalHealthBanner.headline(
            freshness: [], automation: [schedule("a")]
        ))
        XCTAssertTrue(headline.text.contains("overdue"), headline.text)
        XCTAssertEqual(headline.detail, "Managed Reports")
    }

    func testSingularAndPluralAgree() throws {
        let one = try XCTUnwrap(GlobalHealthBanner.headline(
            freshness: [freshness("security", .stale)], automation: []
        ))
        XCTAssertTrue(one.text.hasPrefix("1 data source is"), one.text)

        let two = try XCTUnwrap(GlobalHealthBanner.headline(
            freshness: [freshness("a", .stale), freshness("b", .stale)], automation: []
        ))
        XCTAssertTrue(two.text.hasPrefix("2 data sources are"), two.text)
    }

    /// A fleet with every kind broken must not push the banner into a wall of
    /// text. Asserts the WHOLE detail string, not just that "+2 more" appears
    /// somewhere in it: a mutation that listed all five names while still
    /// appending "+2 more" passed the substring version of this test.
    func testLongKindListNamesAtMostTheCapThenCollapses() throws {
        let many = ["a", "b", "c", "d", "e"].map { freshness($0, .stale) }
        let headline = try XCTUnwrap(
            GlobalHealthBanner.headline(freshness: many, automation: [])
        )
        XCTAssertEqual(try XCTUnwrap(headline.detail), "a, b, c +2 more — a re-scan is needed")
    }

    func testAtTheCapNothingIsCollapsed() throws {
        let exactly = ["a", "b", "c"].map { freshness($0, .stale) }
        let headline = try XCTUnwrap(
            GlobalHealthBanner.headline(freshness: exactly, automation: [])
        )
        XCTAssertEqual(try XCTUnwrap(headline.detail), "a, b, c — a re-scan is needed")
    }

    func testCapIsThree() {
        XCTAssertEqual(GlobalHealthBanner.maxNamedKinds, 3)
    }

    // MARK: - Primary action

    /// The field defect: a red strip whose only button opened a screen with no
    /// re-collect control. Anything collectable now offers the collect.
    func testFreshnessIssuesOfferCollectNow() {
        XCTAssertEqual(
            GlobalHealthBanner.primaryAction(
                freshness: [freshness("security", .failing, failures: 6)], canCollect: true
            ),
            .collectNow
        )
        XCTAssertEqual(GlobalHealthBanner.PrimaryAction.collectNow.label, "Collect now")
    }

    /// A schedule that has not fired is not fixed by collecting — that button
    /// still has to go to Automation.
    func testScheduleOnlyIssuesKeepOpenAutomation() {
        XCTAssertEqual(
            GlobalHealthBanner.primaryAction(
                freshness: [], canCollect: true
            ),
            .openAutomation
        )
    }

    /// A caller that wires no collect handler must not be offered a button
    /// that does nothing.
    func testCollectNowIsNotOfferedWithoutAHandler() {
        XCTAssertEqual(
            GlobalHealthBanner.primaryAction(
                freshness: [freshness("security", .stale)], canCollect: false
            ),
            .openAutomation
        )
    }
}
