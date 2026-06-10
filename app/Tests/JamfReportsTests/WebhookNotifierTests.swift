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

    // MARK: - Failed-run digest builders

    func testTeamsFailedCardUsesAttentionColor() throws {
        let failedFacts: [WebhookNotifier.Fact] = [
            .init(label: "Profile", value: "prod"),
            .init(label: "Status", value: "Failed"),
            .init(label: "Error", value: "collect dead: 401"),
        ]
        let card = WebhookNotifier.teamsFailedCard(title: "Jamf Report — prod", facts: failedFacts)
        let attachments = try XCTUnwrap(card["attachments"] as? [[String: Any]])
        let content = try XCTUnwrap(attachments.first?["content"] as? [String: Any])
        let body = try XCTUnwrap(content["body"] as? [[String: Any]])
        let titleBlock = try XCTUnwrap(body.first { $0["type"] as? String == "TextBlock" })
        XCTAssertEqual(titleBlock["color"] as? String, "Attention",
                       "failed-run card must use Attention color")
        let factSet = try XCTUnwrap(body.first { $0["type"] as? String == "FactSet" })
        let cardFacts = try XCTUnwrap(factSet["facts"] as? [[String: String]])
        XCTAssertEqual(cardFacts.map { $0["title"] }, ["Profile", "Status", "Error"])
        XCTAssertEqual(cardFacts.map { $0["value"] }, ["prod", "Failed", "collect dead: 401"])
    }

    func testTeamsFailedCardContainsNoSecretMaterial() throws {
        let failedFacts: [WebhookNotifier.Fact] = [
            .init(label: "Profile", value: "prod"),
            .init(label: "Status", value: "Failed"),
            .init(label: "Error", value: "collect dead: credentials expired"),
        ]
        let data = try XCTUnwrap(
            WebhookNotifier.failedPayload(provider: .teams, title: "Jamf Report", facts: failedFacts)
        )
        let text = String(data: data, encoding: .utf8) ?? ""
        // The payload must not contain URL-shaped content, tokens, or passwords.
        XCTAssertFalse(text.contains("https://"), "payload must not contain URLs")
        XCTAssertFalse(text.contains("Bearer"), "payload must not contain auth headers")
        XCTAssertFalse(text.contains("password"), "payload must not contain password literals")
    }

    func testSlackFailedBlocksPrefixesTitle() throws {
        let failedFacts: [WebhookNotifier.Fact] = [
            .init(label: "Profile", value: "school-prod"),
            .init(label: "Status", value: "Failed"),
        ]
        let blocks = WebhookNotifier.slackFailedBlocks(title: "Jamf Report — school-prod",
                                                       facts: failedFacts)
        let fallbackText = try XCTUnwrap(blocks["text"] as? String)
        XCTAssertTrue(fallbackText.hasPrefix("🔴 "),
                      "Slack failed digest must prefix fallback text with 🔴")
        let blockList = try XCTUnwrap(blocks["blocks"] as? [[String: Any]])
        let header = try XCTUnwrap(blockList.first { $0["type"] as? String == "header" })
        let headerText = try XCTUnwrap(header["text"] as? [String: Any])
        XCTAssertTrue((headerText["text"] as? String)?.hasPrefix("🔴 ") == true,
                      "Slack failed header block must also carry the 🔴 prefix")
    }

    func testSlackFailedBlocksContainsNoSecretMaterial() throws {
        let failedFacts: [WebhookNotifier.Fact] = [
            .init(label: "Profile", value: "prod"),
            .init(label: "Error", value: "connect failed"),
        ]
        let data = try XCTUnwrap(
            WebhookNotifier.failedPayload(provider: .slack, title: "Jamf Report", facts: failedFacts)
        )
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("https://"), "payload must not contain URLs")
        XCTAssertFalse(text.contains("Bearer"), "payload must not contain auth headers")
    }

    func testSendFailedIsNoOpWhenWebhookDisabled() async {
        let config = NotifyConfig(enabled: false, provider: "teams",
                                  url: "https://example.com/hook")
        let sent = await WebhookNotifier.sendFailed(
            config: config, title: "Jamf Report",
            facts: [.init(label: "Status", value: "Failed")]
        )
        // When not usable, sendFailed returns true (no-op, not an error).
        XCTAssertTrue(sent, "disabled config must be a no-op (returns true)")
    }

    func testSendFailedIsNoOpWhenURLNotHTTPS() async {
        let config = NotifyConfig(enabled: true, provider: "teams",
                                  url: "http://insecure.example.com/hook")
        let sent = await WebhookNotifier.sendFailed(
            config: config, title: "Jamf Report",
            facts: [.init(label: "Status", value: "Failed")]
        )
        XCTAssertTrue(sent, "non-https URL must be a no-op (returns true)")
    }
}
