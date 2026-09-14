import XCTest
@testable import JamfReports

/// Wording for a workspace that has collected something but not everything:
/// a kind never attempted here is information, not an alarm, and must not read
/// as "far behind schedule" beside kinds that genuinely are.
@MainActor
final class GroupCGlobalHealthBannerWordingTests: XCTestCase {

    private let landed = Date(timeIntervalSince1970: 1_700_000_000)

    private func never(_ kind: String) -> DataFreshnessIssue {
        DataFreshnessIssue(
            snapshotKind: kind, tier: .scan, kind: .stale,
            lastSuccess: nil, consecutiveFailures: 0, lastFailure: nil
        )
    }

    private func stale(_ kind: String) -> DataFreshnessIssue {
        DataFreshnessIssue(
            snapshotKind: kind, tier: .refresh, kind: .stale,
            lastSuccess: landed, consecutiveFailures: 0, lastFailure: nil
        )
    }

    private func failing(_ kind: String) -> DataFreshnessIssue {
        DataFreshnessIssue(
            snapshotKind: kind, tier: .refresh, kind: .failing,
            lastSuccess: nil, consecutiveFailures: 3, lastFailure: landed
        )
    }

    private func overdue(_ label: String) -> AutomationHealthIssue {
        AutomationHealthIssue(
            label: label, displayName: "Managed Reports", kind: .overdue,
            expectedFire: Date(), lastRunFinishedAt: nil
        )
    }

    func testAllNeverCollectedReadsAsNotCollectedYetInInfoTone() throws {
        let headline = try XCTUnwrap(GlobalHealthBanner.headline(
            freshness: [never("ddm-device-status"), never("mdm-command-health")],
            automation: []
        ))
        XCTAssertEqual(headline.tone, .info)
        XCTAssertEqual(headline.text, "2 data sources are not collected yet")
        XCTAssertEqual(
            headline.detail,
            "ddm-device-status, mdm-command-health — not attempted yet on this workspace"
        )
    }

    func testSingularNeverCollected() throws {
        let headline = try XCTUnwrap(GlobalHealthBanner.headline(
            freshness: [never("computers")], automation: []
        ))
        XCTAssertEqual(headline.text, "1 data source is not collected yet")
    }

    /// A mixed set leads with the more serious issue, and the stale detail
    /// names only the kinds that are actually behind.
    func testStaleOutranksNeverCollected() throws {
        let headline = try XCTUnwrap(GlobalHealthBanner.headline(
            freshness: [never("ddm-device-status"), stale("security")], automation: []
        ))
        XCTAssertEqual(headline.tone, .warn)
        XCTAssertEqual(headline.text, "1 data source is far behind schedule")
        XCTAssertEqual(headline.detail, "security — a re-scan is needed")
    }

    func testFailingOutranksNeverCollected() throws {
        let headline = try XCTUnwrap(GlobalHealthBanner.headline(
            freshness: [never("ddm-device-status"), failing("computers")], automation: []
        ))
        XCTAssertEqual(headline.tone, .danger)
        XCTAssertTrue(headline.text.contains("failing to collect"), headline.text)
    }

    /// Any freshness issue makes the button "Collect now", so the headline must
    /// describe the data, not the schedule, when both are present.
    func testNeverCollectedOutranksScheduleIssuesAndKeepsCollectNow() throws {
        let freshness = [never("ddm-device-status")]
        let headline = try XCTUnwrap(GlobalHealthBanner.headline(
            freshness: freshness, automation: [overdue("a")]
        ))
        XCTAssertEqual(headline.text, "1 data source is not collected yet")
        XCTAssertEqual(
            GlobalHealthBanner.primaryAction(freshness: freshness, canCollect: true),
            .collectNow
        )
    }
}
