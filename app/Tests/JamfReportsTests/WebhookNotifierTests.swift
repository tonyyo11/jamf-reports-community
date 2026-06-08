import XCTest
@testable import JamfReports

/// v2.2.0 Phase 3 opt-in webhook digest. The payload builders are pure; the
/// network send is not exercised here.
final class WebhookNotifierTests: XCTestCase {

    private let facts: [WebhookNotifier.Fact] = [
        .init(label: "Profile", value: "prod"),
        .init(label: "Status", value: "Success"),
    ]

    func testTeamsPayloadIsAdaptiveCardWithFacts() throws {
        let data = try XCTUnwrap(
            WebhookNotifier.payload(provider: .teams, title: "Jamf Report", facts: facts)
        )
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(obj["type"] as? String, "message")
        let attachments = try XCTUnwrap(obj["attachments"] as? [[String: Any]])
        let content = try XCTUnwrap(attachments.first?["content"] as? [String: Any])
        XCTAssertEqual(content["type"] as? String, "AdaptiveCard")
        let body = try XCTUnwrap(content["body"] as? [[String: Any]])
        let factSet = try XCTUnwrap(body.first { $0["type"] as? String == "FactSet" })
        let cardFacts = try XCTUnwrap(factSet["facts"] as? [[String: String]])
        XCTAssertEqual(cardFacts.map { $0["title"] }, ["Profile", "Status"])
        XCTAssertEqual(cardFacts.map { $0["value"] }, ["prod", "Success"])
    }

    func testSlackPayloadIsBlockKitWithFallbackText() throws {
        let data = try XCTUnwrap(
            WebhookNotifier.payload(provider: .slack, title: "Jamf Report", facts: facts)
        )
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["text"] as? String, "Jamf Report", "fallback notification text")
        let blocks = try XCTUnwrap(obj["blocks"] as? [[String: Any]])
        let header = try XCTUnwrap(blocks.first { $0["type"] as? String == "header" })
        let headerText = try XCTUnwrap(header["text"] as? [String: Any])
        XCTAssertEqual(headerText["text"] as? String, "Jamf Report")
        let section = try XCTUnwrap(blocks.first { $0["type"] as? String == "section" })
        let sectionText = try XCTUnwrap(section["text"] as? [String: Any])
        let mrkdwn = try XCTUnwrap(sectionText["text"] as? String)
        XCTAssertTrue(mrkdwn.contains("*Profile:* prod"))
        XCTAssertTrue(mrkdwn.contains("*Status:* Success"))
    }

    // MARK: - NotifyConfig gating

    func testNotifyConfigUsabilityGate() {
        XCTAssertFalse(NotifyConfig().isUsable, "off + no url by default")
        XCTAssertFalse(
            NotifyConfig(enabled: true, provider: "teams", url: "http://insecure").isUsable,
            "must be https"
        )
        XCTAssertFalse(
            NotifyConfig(enabled: false, provider: "slack", url: "https://hooks.slack.com/x").isUsable,
            "disabled → not usable even with a valid url"
        )
        XCTAssertTrue(
            NotifyConfig(enabled: true, provider: "slack", url: "https://hooks.slack.com/x").isUsable
        )
    }

    func testNotifyConfigProviderResolution() {
        XCTAssertEqual(NotifyConfig(provider: "SLACK").resolvedProvider, .slack)
        XCTAssertEqual(NotifyConfig(provider: "teams").resolvedProvider, .teams)
        XCTAssertEqual(NotifyConfig(provider: "bogus").resolvedProvider, .teams, "unknown → teams")
        XCTAssertEqual(NotifyConfig().resolvedProvider, .teams, "nil → teams")
    }
}
