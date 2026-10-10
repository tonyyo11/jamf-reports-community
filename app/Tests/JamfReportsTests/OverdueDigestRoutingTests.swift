import XCTest
@testable import JamfReports

/// Pure routing of the headless overdue digest: each profile's issues go to that
/// profile's own webhook, fleet-wide issues to every usable one, and nothing is
/// cross-posted to a channel that belongs to another profile.
final class OverdueDigestRoutingTests: XCTestCase {
    private func notify(_ url: String?, enabled: Bool = true) -> NotifyConfig {
        NotifyConfig(enabled: enabled, provider: "teams", url: url, detail: nil)
    }

    private func issue(_ label: String, profile: String, isMulti: Bool = false)
        -> AutomationHealthIssue {
        AutomationHealthIssue(
            label: label, displayName: label, kind: .overdue, isMulti: isMulti,
            profile: profile, expectedFire: nil, lastRunFinishedAt: nil)
    }

    private func target(
        _ profile: String, url: String?, sentToday: Bool = false
    ) -> OverdueDigestRouting.Target {
        .init(profile: profile, notify: url.map { notify($0) }, sentToday: sentToday)
    }

    private let alpha = "https://hooks.example/alpha"
    private let beta = "https://hooks.example/beta"

    func testEachProfileGetsOnlyItsOwnIssuesAndFleetWideReachesBoth() {
        let issues = [
            issue("a-run", profile: "alpha"),
            issue("b-run", profile: "beta"),
            issue("c-run", profile: "gamma"),
            issue("fleet", profile: "", isMulti: true),
        ]
        let routing = OverdueDigestRouting.route(
            overdue: issues,
            targets: [
                target("alpha", url: alpha), target("beta", url: beta),
                target("gamma", url: nil),
            ])
        XCTAssertEqual(routing.batches.map(\.profile), ["alpha", "beta"])
        XCTAssertEqual(routing.batches[0].issues.map(\.label), ["a-run", "fleet"])
        XCTAssertEqual(routing.batches[1].issues.map(\.label), ["b-run", "fleet"])
        XCTAssertEqual(routing.undeliverable.map(\.label), ["c-run"])
    }

    func testNoWebhookProfileIssuesAreNeverCrossPosted() {
        let routing = OverdueDigestRouting.route(
            overdue: [issue("c-run", profile: "gamma")],
            targets: [target("alpha", url: alpha), target("gamma", url: nil)])
        XCTAssertTrue(routing.batches.isEmpty)
        XCTAssertEqual(routing.undeliverable.map(\.label), ["c-run"])
    }

    func testUnusableNotifyBlockCountsAsNoWebhook() {
        let off = OverdueDigestRouting.Target(
            profile: "alpha", notify: notify(alpha, enabled: false), sentToday: false)
        let http = OverdueDigestRouting.Target(
            profile: "beta", notify: notify("http://insecure.example"), sentToday: false)
        let routing = OverdueDigestRouting.route(
            overdue: [issue("a", profile: "alpha"), issue("b", profile: "beta")],
            targets: [off, http])
        XCTAssertTrue(routing.batches.isEmpty)
        XCTAssertEqual(routing.undeliverable.map(\.label), ["a", "b"])
    }

    func testProfileAlreadyStampedTodayIsExcludedAndNotReported() {
        let routing = OverdueDigestRouting.route(
            overdue: [
                issue("a-run", profile: "alpha"), issue("b-run", profile: "beta"),
                issue("fleet", profile: "", isMulti: true),
            ],
            targets: [target("alpha", url: alpha, sentToday: true), target("beta", url: beta)])
        XCTAssertEqual(routing.batches.map(\.profile), ["beta"])
        XCTAssertEqual(routing.batches[0].issues.map(\.label), ["b-run", "fleet"])
        XCTAssertTrue(routing.undeliverable.isEmpty)
    }

    func testZeroUsableWebhooksYieldsNoBatchesAndReportsEverything() {
        let routing = OverdueDigestRouting.route(
            overdue: [issue("a", profile: "alpha"), issue("fleet", profile: "", isMulti: true)],
            targets: [target("alpha", url: nil), target("beta", url: nil)])
        XCTAssertTrue(routing.batches.isEmpty)
        XCTAssertEqual(routing.undeliverable.map(\.label), ["a", "fleet"])
    }

    func testProfileWithOnlyFleetWideIssuesStillGetsABatch() {
        let routing = OverdueDigestRouting.route(
            overdue: [issue("fleet", profile: "", isMulti: true)],
            targets: [target("alpha", url: alpha), target("beta", url: beta)])
        XCTAssertEqual(routing.batches.map(\.profile), ["alpha", "beta"])
        XCTAssertTrue(routing.undeliverable.isEmpty)
    }

    func testProfileWithNoIssuesGetsNoBatch() {
        let routing = OverdueDigestRouting.route(
            overdue: [issue("a-run", profile: "alpha")],
            targets: [target("alpha", url: alpha), target("beta", url: beta)])
        XCTAssertEqual(routing.batches.map(\.profile), ["alpha"])
    }
}
