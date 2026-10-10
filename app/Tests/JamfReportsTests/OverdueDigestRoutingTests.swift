import XCTest
@testable import JamfReports

/// Pure routing of the headless overdue digest: each profile's issues go to that
/// profile's own webhook, fleet-wide issues to every usable one, profiles that
/// share a webhook get one card, and nothing is cross-posted.
final class OverdueDigestRoutingTests: XCTestCase {
    private let alpha = "https://hooks.example/alpha"
    private let beta = "https://hooks.example/beta"

    private func issue(_ label: String, profile: String, isMulti: Bool = false)
        -> AutomationHealthIssue {
        AutomationHealthIssue(
            label: label, displayName: label, kind: .overdue, isMulti: isMulti,
            profile: profile, expectedFire: nil, lastRunFinishedAt: nil)
    }

    private func target(
        _ profile: String, url: String, detail: String? = nil, sentToday: Bool = false
    ) -> OverdueDigestRouting.Target {
        .init(
            profile: profile,
            notify: NotifyConfig(enabled: true, provider: "teams", url: url, detail: detail),
            workspace: URL(fileURLWithPath: "/tmp/ws-\(profile)"), sentToday: sentToday)
    }

    func testEachProfileGetsOnlyItsOwnIssuesAndFleetWideReachesBoth() {
        let routing = OverdueDigestRouting.route(
            overdue: [
                issue("a-run", profile: "alpha"), issue("b-run", profile: "beta"),
                issue("c-run", profile: "gamma"),
                issue("fleet", profile: "", isMulti: true),
            ],
            targets: [target("alpha", url: alpha), target("beta", url: beta)],
            runProfiles: ["alpha", "beta", "gamma"])
        XCTAssertEqual(routing.batches.map(\.profiles), [["alpha"], ["beta"]])
        XCTAssertEqual(routing.batches[0].issues.map(\.label), ["a-run", "fleet"])
        XCTAssertEqual(routing.batches[1].issues.map(\.label), ["b-run", "fleet"])
        XCTAssertEqual(routing.undeliverable.map(\.label), ["c-run"])
    }

    func testNoWebhookProfileIssuesAreNeverCrossPosted() {
        let routing = OverdueDigestRouting.route(
            overdue: [issue("c-run", profile: "gamma")],
            targets: [target("alpha", url: alpha)],
            runProfiles: ["alpha", "gamma"])
        XCTAssertTrue(routing.batches.isEmpty)
        XCTAssertEqual(routing.undeliverable.map(\.label), ["c-run"])
    }

    func testProfileAlreadyStampedTodayIsExcludedAndNotReported() {
        let routing = OverdueDigestRouting.route(
            overdue: [
                issue("a-run", profile: "alpha"), issue("b-run", profile: "beta"),
                issue("fleet", profile: "", isMulti: true),
            ],
            targets: [
                target("alpha", url: alpha, sentToday: true), target("beta", url: beta),
            ],
            runProfiles: ["alpha", "beta"])
        XCTAssertEqual(routing.batches.map(\.profiles), [["beta"]])
        XCTAssertEqual(routing.batches[0].issues.map(\.label), ["b-run", "fleet"])
        XCTAssertTrue(routing.undeliverable.isEmpty)
    }

    func testZeroUsableWebhooksYieldsNoBatchesAndReportsEverythingInScope() {
        let routing = OverdueDigestRouting.route(
            overdue: [issue("a", profile: "alpha"), issue("fleet", profile: "", isMulti: true)],
            targets: [], runProfiles: ["alpha", "beta"])
        XCTAssertTrue(routing.batches.isEmpty)
        XCTAssertEqual(routing.undeliverable.map(\.label), ["a", "fleet"])
    }

    func testProfileWithOnlyFleetWideIssuesStillGetsABatch() {
        let routing = OverdueDigestRouting.route(
            overdue: [issue("fleet", profile: "", isMulti: true)],
            targets: [target("alpha", url: alpha), target("beta", url: beta)],
            runProfiles: ["alpha", "beta"])
        XCTAssertEqual(routing.batches.map(\.profiles), [["alpha"], ["beta"]])
        XCTAssertTrue(routing.undeliverable.isEmpty)
    }

    func testProfileWithNoIssuesGetsNoBatch() {
        let routing = OverdueDigestRouting.route(
            overdue: [issue("a-run", profile: "alpha")],
            targets: [target("alpha", url: alpha), target("beta", url: beta)],
            runProfiles: ["alpha", "beta"])
        XCTAssertEqual(routing.batches.map(\.profiles), [["alpha"]])
    }

    func testIssueForProfileOutsideTheRunIsNeitherRoutedNorReported() {
        let routing = OverdueDigestRouting.route(
            overdue: [issue("o-run", profile: "other"), issue("a-run", profile: "alpha")],
            targets: [target("alpha", url: alpha)],
            runProfiles: ["alpha"])
        XCTAssertEqual(routing.batches.count, 1)
        XCTAssertEqual(routing.batches[0].issues.map(\.label), ["a-run"])
        XCTAssertTrue(routing.undeliverable.isEmpty)
    }

    func testProfilesSharingAWebhookGetOneCardWithTheUnion() {
        let routing = OverdueDigestRouting.route(
            overdue: [
                issue("a-run", profile: "alpha"), issue("b-run", profile: "beta"),
                issue("fleet", profile: "", isMulti: true),
            ],
            targets: [target("alpha", url: alpha), target("beta", url: alpha)],
            runProfiles: ["alpha", "beta"])
        XCTAssertEqual(routing.batches.count, 1)
        XCTAssertEqual(routing.batches[0].issues.map(\.label), ["a-run", "b-run", "fleet"])
        XCTAssertEqual(routing.batches[0].targets.map(\.profile), ["alpha", "beta"])
        XCTAssertEqual(routing.batches[0].profiles.joined(separator: ", "), "alpha, beta")
    }

    func testSharedWebhookGroupUsesMinimalIfAnyMemberAsksForIt() {
        let routing = OverdueDigestRouting.route(
            overdue: [issue("a-run", profile: "alpha"), issue("b-run", profile: "beta")],
            targets: [
                target("alpha", url: alpha, detail: "full"),
                target("beta", url: alpha, detail: "minimal"),
            ],
            runProfiles: ["alpha", "beta"])
        XCTAssertEqual(routing.batches[0].notify.resolvedDetail, .minimal)
    }
}
