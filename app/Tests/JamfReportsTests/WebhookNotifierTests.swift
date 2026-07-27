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

    // MARK: - Markup sanitization (review CONSIDER C1)

    func testSanitizeNeutralizesSlackChannelBroadcast() {
        // <!channel> is Slack's @channel broadcast form. Escaping < and >
        // structurally destroys it — the angle brackets no longer delimit a
        // directive, so no broadcast ping can be injected via fact text.
        let out = WebhookNotifier.sanitize("<!channel>")
        XCTAssertFalse(out.contains("<"), "opening angle bracket must be escaped")
        XCTAssertFalse(out.contains(">"), "closing angle bracket must be escaped")
        XCTAssertEqual(out, "&lt;!channel&gt;")
    }

    func testSanitizeNeutralizesSlackUserMention() {
        let out = WebhookNotifier.sanitize("<@U123ABC>")
        XCTAssertFalse(out.contains("<"))
        XCTAssertFalse(out.contains(">"))
        XCTAssertEqual(out, "&lt;@U123ABC&gt;")
    }

    func testSanitizeEscapesAmpersandExactlyOnce() {
        // A lone & becomes &amp; — never &amp;amp;. Facts arrive as plain
        // strings, so the helper escapes them exactly once.
        XCTAssertEqual(WebhookNotifier.sanitize("Tom & Jerry"), "Tom &amp; Jerry")
        // An input containing what looks like an entity is still single-escaped
        // (the & is escaped, the rest is literal), never double-escaped.
        XCTAssertEqual(WebhookNotifier.sanitize("&amp;"), "&amp;amp;")
    }

    func testSanitizeLeavesBenignTextUnchanged() {
        XCTAssertEqual(WebhookNotifier.sanitize("prod"), "prod")
        XCTAssertEqual(WebhookNotifier.sanitize("Compliance Benchmark 92%"),
                       "Compliance Benchmark 92%")
    }

    func testSanitizeRoutesThroughEveryPayloadFamily() throws {
        // A single crafted fact value must be neutralized in all four families
        // (send / sendFailed / sendAlert) across both providers.
        let hostile: [WebhookNotifier.Fact] = [
            .init(label: "Profile", value: "<!channel>"),
        ]
        let builds: [Data?] = [
            WebhookNotifier.payload(provider: .teams, title: "T", facts: hostile),
            WebhookNotifier.payload(provider: .slack, title: "T", facts: hostile),
            WebhookNotifier.failedPayload(provider: .teams, title: "T", facts: hostile),
            WebhookNotifier.failedPayload(provider: .slack, title: "T", facts: hostile),
            WebhookNotifier.alertPayload(provider: .teams, title: "T", facts: hostile),
            WebhookNotifier.alertPayload(provider: .slack, title: "T", facts: hostile),
        ]
        for build in builds {
            let data = try XCTUnwrap(build)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            // JSON-encoded output must carry the escaped entity, never the raw
            // <!channel> directive form.
            XCTAssertTrue(text.contains("&lt;!channel&gt;"),
                          "each family must carry the neutralized form")
            XCTAssertFalse(text.contains("<!channel>"),
                           "no family may emit the raw broadcast directive")
        }
    }

    func testSanitizeAlsoNeutralizesTitle() throws {
        let card = WebhookNotifier.teamsCard(title: "<!here> alert", facts: [])
        let attachments = try XCTUnwrap(card["attachments"] as? [[String: Any]])
        let content = try XCTUnwrap(attachments.first?["content"] as? [String: Any])
        let body = try XCTUnwrap(content["body"] as? [[String: Any]])
        let titleBlock = try XCTUnwrap(body.first { $0["type"] as? String == "TextBlock" })
        let titleText = try XCTUnwrap(titleBlock["text"] as? String)
        XCTAssertFalse(titleText.contains("<!here>"))
        XCTAssertTrue(titleText.contains("&lt;!here&gt;"))
    }

    // MARK: - Minimal-detail fact reduction (main.swift assembly helpers)

    func testSuccessFactsFullKeepsRichFacts() {
        let full = successFacts(
            detail: .full, profile: "prod", mode: .jamfCLIFull,
            artifact: "report_prod_2026-07-06_101500.xlsx", sheetFailures: 2
        )
        XCTAssertEqual(full.map { $0.label },
                       ["Profile", "Run", "Status", "Sheets failed", "Report"])
        XCTAssertEqual(full.first { $0.label == "Status" }?.value, "Partial")
    }

    func testSuccessFactsMinimalKeepsOnlyProfileRunStatus() {
        let minimal = successFacts(
            detail: .minimal, profile: "prod", mode: .jamfCLIFull,
            artifact: "report_prod_2026-07-06_101500.xlsx", sheetFailures: 2
        )
        XCTAssertEqual(minimal.map { $0.label }, ["Profile", "Run", "Status"])
        // Filename (embeds profile+timestamp) and sheet-failure count dropped.
        XCTAssertFalse(minimal.contains { $0.label == "Report" })
        XCTAssertFalse(minimal.contains { $0.label == "Sheets failed" })
        // Status still reflects the partial run (it's a status word, not data).
        XCTAssertEqual(minimal.first { $0.label == "Status" }?.value, "Partial")
    }

    func testFailureFactsFullRedactsHostnameFromError() {
        // A network errorDescription can embed the Jamf server hostname — the
        // only free-text egress channel. Full mode must scrub it.
        let host = "jamf.prod-example.gov"
        let error = "collect failed: could not connect to https://\(host)/api/v1/auth"
        let full = failureFacts(
            detail: .full, profile: "prod", mode: .jamfCLIFull, errorDescription: error
        )
        let errorFact = full.first { $0.label == "Error" }
        XCTAssertNotNil(errorFact, "full mode carries the (redacted) error fact")
        XCTAssertFalse(errorFact?.value.contains(host) == true,
                       "the raw server hostname must not survive redaction")
        XCTAssertTrue(errorFact?.value.contains("host-") == true,
                      "the hostname is replaced by a redaction placeholder")
    }

    func testFailureFactsFullRedactsBearerTokenFromError() {
        let token = "Bearer abcdEFGH1234567890xyzTOKEN"
        let full = failureFacts(
            detail: .full, profile: "prod", mode: .jamfCLIFull,
            errorDescription: "auth echoed \(token)"
        )
        let errorFact = full.first { $0.label == "Error" }
        XCTAssertFalse(errorFact?.value.contains("abcdEFGH1234567890xyzTOKEN") == true)
        XCTAssertTrue(errorFact?.value.contains("REDACTED_BEARER") == true)
    }

    func testFailureFactsMinimalDropsErrorEntirely() {
        let full = failureFacts(
            detail: .minimal, profile: "prod", mode: .jamfCLIFull,
            errorDescription: "collect failed: https://jamf.prod-example.gov timed out"
        )
        XCTAssertEqual(full.map { $0.label }, ["Profile", "Run", "Status"])
        XCTAssertEqual(full.first { $0.label == "Status" }?.value, "Failed")
        XCTAssertFalse(full.contains { $0.label == "Error" },
                       "minimal mode carries no free-text error channel at all")
    }

    func testAlertFactsFullListsEveryHit() {
        let hits = [
            MetricAlertHit(metricLabel: "FileVault", ruleDescription: "below 90",
                           current: 82, prior: nil, message: "82% below 90"),
            MetricAlertHit(metricLabel: "Patch", ruleDescription: "drops_more_than 5",
                           current: 60, prior: 70, message: "dropped 10pp"),
        ]
        let full = alertFacts(detail: .full, profile: "prod", hits: hits)
        XCTAssertEqual(full.map { $0.label }, ["Profile", "FileVault", "Patch"])
        XCTAssertEqual(full.first { $0.label == "FileVault" }?.value, "82% below 90")
    }

    func testAlertFactsMinimalHidesMetricNamesAndValues() {
        let hits = [
            MetricAlertHit(metricLabel: "FileVault", ruleDescription: "below 90",
                           current: 82, prior: nil, message: "82% below 90"),
            MetricAlertHit(metricLabel: "Patch", ruleDescription: "below 80",
                           current: 60, prior: nil, message: "60% below 80"),
        ]
        let minimal = alertFacts(detail: .minimal, profile: "prod", hits: hits)
        XCTAssertEqual(minimal.map { $0.label }, ["Profile", "Alerts"])
        XCTAssertEqual(minimal.first { $0.label == "Alerts" }?.value, "2 rules tripped")
        // No metric name, value, threshold, or date leaks.
        let joined = minimal.map { "\($0.label)\($0.value)" }.joined()
        XCTAssertFalse(joined.contains("FileVault"))
        XCTAssertFalse(joined.contains("82"))
        XCTAssertFalse(joined.contains("below"))
    }

    func testAlertFactsMinimalSingularWording() {
        let hits = [
            MetricAlertHit(metricLabel: "FileVault", ruleDescription: "below 90",
                           current: 82, prior: nil, message: "82% below 90"),
        ]
        let minimal = alertFacts(detail: .minimal, profile: "prod", hits: hits)
        XCTAssertEqual(minimal.first { $0.label == "Alerts" }?.value, "1 rule tripped")
    }

    // MARK: - Overdue dead-man digest reduction (WorkspaceStore+Automation)

    func testOverdueFactsFullListsEverySchedule() {
        let issues = [
            AutomationHealthIssue(
                label: "com.x.prod.freshness", displayName: "Daily freshness",
                kind: .overdue, isMulti: false, profile: "prod",
                expectedFire: Date(timeIntervalSince1970: 1_700_000_000),
                lastRunFinishedAt: nil),
            AutomationHealthIssue(
                label: "com.x.prod.weekly-report", displayName: "Weekly reports",
                kind: .overdue, isMulti: false, profile: "prod",
                expectedFire: nil, lastRunFinishedAt: nil),
        ]
        let full = WorkspaceStore.overdueFacts(detail: .full, profile: "prod", overdue: issues)
        XCTAssertEqual(full.map { $0.label }, ["prod — Daily freshness", "prod — Weekly reports"])
        XCTAssertEqual(full.first { $0.label == "prod — Weekly reports" }?.value, "no run recorded")
    }

    /// The evaluation is fleet-wide: an issue's OWN profile must appear on its
    /// fact, not whichever profile happened to send the digest (the bug: the
    /// full-detail card previously carried no attribution at all).
    func testOverdueFactsFullAttributesEachScheduleToItsOwnProfileNotTheSender() {
        let issues = [
            AutomationHealthIssue(
                label: "com.x.prod.freshness", displayName: "Daily freshness",
                kind: .overdue, isMulti: false, profile: "prod",
                expectedFire: nil, lastRunFinishedAt: nil),
        ]
        // Digest sent via "dev"'s webhook, but the schedule itself belongs to "prod".
        let full = WorkspaceStore.overdueFacts(detail: .full, profile: "dev", overdue: issues)
        XCTAssertEqual(full.first?.label, "prod — Daily freshness")
    }

    /// An `isMulti` (global managed) schedule belongs to no single profile — it
    /// must be labeled fleet-wide, matching OverviewView's banner wording,
    /// never attributed to the sending profile or left unattributed.
    func testOverdueFactsFullLabelsMultiAsFleetWideNotAnyProfile() {
        let issues = [
            AutomationHealthIssue(
                label: "com.x.multi.managed-backup", displayName: "Managed Backup",
                kind: .overdue, isMulti: true, profile: "",
                expectedFire: nil, lastRunFinishedAt: nil),
        ]
        let full = WorkspaceStore.overdueFacts(detail: .full, profile: "prod", overdue: issues)
        XCTAssertEqual(full.first?.label, "Managed automation (all profiles) — Backup")
    }

    func testOverdueFactsMinimalCollapsesToCount() {
        let issues = [
            AutomationHealthIssue(
                label: "com.x.managed-freshness", displayName: "Daily freshness",
                kind: .overdue, expectedFire: nil, lastRunFinishedAt: nil),
            AutomationHealthIssue(
                label: "com.x.managed-reports", displayName: "Weekly reports",
                kind: .overdue, expectedFire: nil, lastRunFinishedAt: nil),
        ]
        let minimal = WorkspaceStore.overdueFacts(detail: .minimal, profile: "prod", overdue: issues)
        XCTAssertEqual(minimal.map { $0.label }, ["Profile", "Overdue"])
        XCTAssertEqual(minimal.first { $0.label == "Overdue" }?.value,
                       "2 schedules missed their run")
        // Schedule display names never leak in minimal mode.
        let joined = minimal.map { "\($0.label)\($0.value)" }.joined()
        XCTAssertFalse(joined.contains("Daily freshness"))
        XCTAssertFalse(joined.contains("Weekly reports"))
    }

    func testOverdueFactsMinimalSingularWording() {
        let issues = [
            AutomationHealthIssue(
                label: "com.x.managed-freshness", displayName: "Daily freshness",
                kind: .overdue, expectedFire: nil, lastRunFinishedAt: nil),
        ]
        let minimal = WorkspaceStore.overdueFacts(detail: .minimal, profile: "prod", overdue: issues)
        XCTAssertEqual(minimal.first { $0.label == "Overdue" }?.value,
                       "1 schedule missed their run")
    }
}
