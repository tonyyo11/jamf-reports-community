import XCTest
@testable import JamfReports

/// What a metric-alert card says per detail level; minimal detail leaves the card with no metric,
/// credential kind, ID or expiry.
final class AlertFactsTests: XCTestCase {
    private let rule = MetricAlertHit(
        metricLabel: "FileVault", ruleDescription: "below 90", current: 80, prior: nil,
        message: "80% - below threshold 90")

    private func credential(expired: Bool) -> MetricAlertHit {
        MetricAlertHit(
            metricLabel: "Days to server credential expiry", ruleDescription: "below 45",
            current: expired ? -3 : 40, prior: nil,
            message: expired ? "ADE token expired 3 days ago" : "ADE token expires in 40 days",
            credentialKey: "ade:SECRET-ID", expires: "2026-12-31",
            credentialState: expired ? "expired" : "hit")
    }

    private func minimal(_ hits: [MetricAlertHit]) -> [String] {
        alertFacts(detail: .minimal, profile: "prod", hits: hits).map { "\($0.label): \($0.value)" }
    }

    private func assertNothingIdentifying(_ lines: [String], file: StaticString = #filePath,
                                          line: UInt = #line) {
        let text = lines.joined(separator: "\n")
        for secret in ["FileVault", "Days to server", "ade", "ADE", "SECRET-ID", "2026-12-31", "80"] {
            XCTAssertFalse(text.contains(secret), "\(secret) in \(text)", file: file, line: line)
        }
    }

    func testMinimalWithARuleHitOnlyCountsTheRule() {
        let lines = minimal([rule])
        XCTAssertEqual(lines, ["Profile: prod", "Alerts: 1 rule tripped"])
    }

    func testMinimalWithACredentialHitOnlyHasNoRuleCount() {
        let lines = minimal([credential(expired: false)])
        XCTAssertEqual(lines, ["Profile: prod", "Server credential: A server credential is expiring"])
        assertNothingIdentifying(lines)
    }

    func testMinimalWithBothSaysBoth() {
        let lines = minimal([rule, credential(expired: false)])
        XCTAssertEqual(lines, ["Profile: prod", "Alerts: 1 rule tripped",
                               "Server credential: A server credential is expiring"])
        assertNothingIdentifying(lines)
    }

    func testMinimalWithAnExpiredCredentialSaysExpired() {
        let lines = minimal([credential(expired: true)])
        XCTAssertEqual(lines, ["Profile: prod", "Server credential: A server credential has expired"])
        assertNothingIdentifying(lines)
    }

    func testFullDetailCarriesTheCredentialMessageUnderItsMetricLabel() {
        let facts = alertFacts(detail: .full, profile: "prod", hits: [credential(expired: false)])
        XCTAssertEqual(facts.last?.label, "Days to server credential expiry")
        XCTAssertEqual(facts.last?.value, "ADE token expires in 40 days")
        XCTAssertFalse(facts.map(\.value).joined().contains("SECRET-ID"), "never the ID")
    }
}
