import Foundation

/// Opt-in scheduled-run webhook digest (v2.2.0 Phase 3). Posts a compact
/// summary of a completed scheduled run to a Microsoft Teams or Slack incoming
/// webhook. OFF by default — the caller gates on `NotifyConfig.isUsable`.
///
/// Best-effort: a failed post logs a warning and never throws into the run.
/// Payload builders are pure and unit-tested; the network send is thin.
enum WebhookNotifier {

    /// One labeled fact in the digest (e.g. "Profile" → "prod").
    struct Fact: Sendable, Equatable {
        let label: String
        let value: String
    }

    /// JSON body for `provider`. Pure — no network. Returns nil only if
    /// serialization fails (never expected for these literal structures).
    static func payload(
        provider: NotifyConfig.Provider, title: String, facts: [Fact]
    ) -> Data? {
        let object: [String: Any]
        switch provider {
        case .teams: object = teamsCard(title: title, facts: facts)
        case .slack: object = slackBlocks(title: title, facts: facts)
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// JSON body for a failed-run digest. Uses a red/attention accent so the
    /// failure stands out from success digests on Teams and Slack. Pure — no network.
    static func failedPayload(
        provider: NotifyConfig.Provider, title: String, facts: [Fact]
    ) -> Data? {
        let object: [String: Any]
        switch provider {
        case .teams: object = teamsFailedCard(title: title, facts: facts)
        case .slack: object = slackFailedBlocks(title: title, facts: facts)
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Microsoft Teams Adaptive Card (mirrors the Python `_post_webhook` Teams
    /// shape so both engines render identically).
    static func teamsCard(title: String, facts: [Fact]) -> [String: Any] {
        [
            "type": "message",
            "attachments": [[
                "contentType": "application/vnd.microsoft.card.adaptive",
                "contentUrl": NSNull(),
                "content": [
                    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                    "type": "AdaptiveCard",
                    "version": "1.4",
                    "body": [
                        ["type": "TextBlock", "size": "Large", "weight": "Bolder", "text": title],
                        ["type": "FactSet",
                         "facts": facts.map { ["title": $0.label, "value": $0.value] }],
                    ],
                ],
            ]],
        ]
    }

    /// Microsoft Teams Adaptive Card for a failed run. Uses "Attention" color
    /// so failures are visually distinct from success digests.
    static func teamsFailedCard(title: String, facts: [Fact]) -> [String: Any] {
        [
            "type": "message",
            "attachments": [[
                "contentType": "application/vnd.microsoft.card.adaptive",
                "contentUrl": NSNull(),
                "content": [
                    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                    "type": "AdaptiveCard",
                    "version": "1.4",
                    "body": [
                        [
                            "type": "TextBlock",
                            "size": "Large",
                            "weight": "Bolder",
                            "text": title,
                            "color": "Attention",
                        ],
                        ["type": "FactSet",
                         "facts": facts.map { ["title": $0.label, "value": $0.value] }],
                    ],
                ],
            ]],
        ]
    }

    /// Slack Block Kit message. `text` is the notification/fallback line; the
    /// blocks render the header + a mrkdwn fact list.
    static func slackBlocks(title: String, facts: [Fact]) -> [String: Any] {
        let factLines = facts.map { "*\($0.label):* \($0.value)" }.joined(separator: "\n")
        return [
            "text": title,
            "blocks": [
                ["type": "header",
                 "text": ["type": "plain_text", "text": title]],
                ["type": "section",
                 "text": ["type": "mrkdwn", "text": factLines.isEmpty ? title : factLines]],
            ],
        ]
    }

    /// Slack Block Kit message for a failed run. Prefixes the header with a
    /// red-circle emoji so failures stand out in notification feeds.
    static func slackFailedBlocks(title: String, facts: [Fact]) -> [String: Any] {
        let failedTitle = "🔴 \(title)"
        let factLines = facts.map { "*\($0.label):* \($0.value)" }.joined(separator: "\n")
        return [
            "text": failedTitle,
            "blocks": [
                ["type": "header",
                 "text": ["type": "plain_text", "text": failedTitle]],
                ["type": "section",
                 "text": ["type": "mrkdwn", "text": factLines.isEmpty ? failedTitle : factLines]],
            ],
        ]
    }

    /// Post `facts` under `title` to the configured webhook. No-op when the
    /// config is not usable (off / no https URL). Never throws.
    ///
    /// Returns `true` when the post is a no-op (webhook disabled) or succeeds
    /// with a 2xx response. Returns `false` on encode failure, non-2xx, or
    /// network error so callers can record a warning in the run audit trail.
    @discardableResult
    static func send(config: NotifyConfig, title: String, facts: [Fact]) async -> Bool {
        guard config.isUsable, let url = URL(string: config.resolvedURL) else { return true }
        AppLogger.webhook.debug("posting \(config.resolvedProvider.rawValue, privacy: .public) digest")
        guard let body = payload(provider: config.resolvedProvider, title: title, facts: facts) else {
            AppLogger.webhook.warning(
                "WebhookNotifier: failed to encode \(config.resolvedProvider.rawValue, privacy: .public) payload"
            )
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                AppLogger.webhook.info("WebhookNotifier: webhook returned HTTP \(http.statusCode)")
                return false
            }
            return true
        } catch {
            AppLogger.webhook.warning(
                "WebhookNotifier: post failed: \(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }

    /// Post a failed-run digest using the attention-styled card/blocks. Gated on
    /// `config.isUsable` — no-op when webhook is off or URL is not https.
    /// Never throws.
    @discardableResult
    static func sendFailed(config: NotifyConfig, title: String, facts: [Fact]) async -> Bool {
        guard config.isUsable, let url = URL(string: config.resolvedURL) else { return true }
        guard let body = failedPayload(provider: config.resolvedProvider, title: title, facts: facts) else {
            AppLogger.webhook.warning(
                "WebhookNotifier: failed to encode failed-run \(config.resolvedProvider.rawValue, privacy: .public) payload"
            )
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                AppLogger.webhook.info("WebhookNotifier: failed-run webhook returned HTTP \(http.statusCode)")
                return false
            }
            return true
        } catch {
            AppLogger.webhook.warning(
                "WebhookNotifier: failed-run post failed: \(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }
}
