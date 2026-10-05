import Foundation
import XCTest
@testable import JamfReports

/// Coverage for `LogRedactor` — one positive + one negative per pattern, plus a
/// passthrough test that ensures the wrapper does not corrupt non-matching text.
final class LogRedactorTests: XCTestCase {

    // MARK: - client_secret

    func testRedactsClientSecretYAML() {
        let input = "client_secret: super-secret-value-1234"
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_CLIENT_SECRET"))
        XCTAssertFalse(redacted.contains("super-secret-value-1234"))
    }

    func testRedactsClientSecretJSON() {
        let input = #"{"client_secret": "abcd1234efgh5678"}"#
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_CLIENT_SECRET"))
        XCTAssertFalse(redacted.contains("abcd1234efgh5678"))
        // Quotes preserved (output still valid JSON-like).
        XCTAssertTrue(redacted.contains(#""REDACTED_CLIENT_SECRET""#))
    }

    func testShortClientSecretIsNotRedacted() {
        // 7 chars — below the 8-char floor. Should pass through unchanged.
        let input = "client_secret: 7charsx"
        let redacted = LogRedactor.redact(input)
        XCTAssertEqual(input, redacted)
    }

    // MARK: - client_id

    func testRedactsClientIdUUID() {
        // 36-char UUID matches the 20+ hex-or-dash branch.
        let input = "client_id: 11111111-2222-3333-4444-555555555555"
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_CLIENT_ID"))
        XCTAssertFalse(redacted.contains("11111111-2222"))
    }

    func testRedactsClientIdOpaque16Chars() {
        // 16-char opaque alphanumeric matches the second branch.
        let input = #"client_id="abcdef0123456789""#
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_CLIENT_ID"))
    }

    func testShortClientIdIsNotRedacted() {
        // 8-char value — below the 16-char floor and not a UUID. Should pass through.
        let input = "client_id: dev123ab"
        let redacted = LogRedactor.redact(input)
        XCTAssertEqual(input, redacted)
    }

    // MARK: - Bearer

    func testRedactsBearerToken() {
        let input = "Authorization: Bearer abcdef0123456789abcdef0123456789"
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_BEARER"))
        XCTAssertFalse(redacted.contains("abcdef0123456789abcdef0123456789"))
    }

    func testRedactsBearerCaseInsensitive() {
        let input = "bearer XYZ1234567890XYZ1234567890"
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_BEARER"))
    }

    func testShortBearerIsNotRedacted() {
        // 10-char token — below the 20-char floor.
        let input = "Bearer short12345x"
        let redacted = LogRedactor.redact(input)
        XCTAssertEqual(input, redacted)
    }

    // MARK: - JWT

    func testRedactsJWT() {
        let input = "token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123def456ghi789"
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_JWT"))
        XCTAssertFalse(redacted.contains("eyJhbGciOiJIUzI1NiJ9"))
    }

    func testRedactsJWTInline() {
        let input = "JWT: eyJhAAAAAAAAAA.eyJBBBBBBBBBB.ccCCCCCCCCCCCCC end"
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_JWT"))
        XCTAssertTrue(redacted.contains("end"))
    }

    func testNonJWTLooksLikeIsNotRedacted() {
        // Starts with eyJ but only two dots-segments (missing third) — not a JWT.
        let input = "ref=eyJabcdef.short"
        let redacted = LogRedactor.redact(input)
        XCTAssertEqual(input, redacted)
    }

    // MARK: - access_token / refresh_token

    func testRedactsAccessTokenJSON() {
        let input = #"{"access_token": "atk-1234567890"}"#
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_ACCESS_TOKEN"))
        XCTAssertFalse(redacted.contains("atk-1234567890"))
    }

    func testRedactsRefreshTokenJSON() {
        let input = #"{"refresh_token": "rtk-xyz"}"#
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_REFRESH_TOKEN"))
        XCTAssertFalse(redacted.contains("rtk-xyz"))
    }

    func testAccessTokenAsYAMLKeyIsNotRedacted() {
        // YAML form (key: value, no quotes) is not matched by the JSON-only pattern.
        // Confirms the pattern is scoped to JSON shapes by design.
        let input = "access_token: yaml-not-matched"
        let redacted = LogRedactor.redact(input)
        XCTAssertEqual(input, redacted)
    }

    // MARK: - password

    func testRedactsPasswordYAML() {
        let input = "password: hunter2"
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_PASSWORD"))
        XCTAssertFalse(redacted.contains("hunter2"))
    }

    func testRedactsPasswordJSON() {
        let input = #"{"password": "p@ssw0rd!"}"#
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_PASSWORD"))
        XCTAssertFalse(redacted.contains("p@ssw0rd!"))
    }

    func testPasswordReferenceWordIsNotRedacted() {
        // "password" mentioned in a sentence without a value pattern should pass through.
        let input = "User forgot the password. Please reset."
        let redacted = LogRedactor.redact(input)
        XCTAssertEqual(input, redacted)
    }

    // MARK: - HTTP Basic auth

    func testRedactsBasicAuth() {
        let input = "Authorization: Basic dXNlcjpwYXNzd29yZA=="
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_BASIC"))
        XCTAssertFalse(redacted.contains("dXNlcjpwYXNzd29yZA=="))
    }

    func testRedactsBasicAuthCaseInsensitive() {
        let input = "authorization: basic YWJjZGVmZ2hpamtsbW5vcA=="
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_BASIC"))
    }

    func testShortBasicAuthIsNotRedacted() {
        // 8-char base64 — below the 16-char floor.
        let input = "Authorization: Basic dXNlcjEy"
        let redacted = LogRedactor.redact(input)
        XCTAssertEqual(input, redacted)
    }

    // MARK: - webhook_url

    func testRedactsTeamsWebhookURL() {
        let input = #"webhook_url: "https://outlook.office.com/webhook/abc-def-123""#
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_WEBHOOK_URL"))
        XCTAssertFalse(redacted.contains("abc-def-123"))
    }

    func testRedactsSlackWebhookURLYAML() {
        let input = "webhook_url: https://hooks.slack.com/services/T00/B00/XXXXXX"
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_WEBHOOK_URL"))
        XCTAssertFalse(redacted.contains("hooks.slack.com"))
    }

    func testNonWebhookURLIsNotRedacted() {
        // URL elsewhere in the line (not in webhook_url key) passes through.
        let input = "Connecting to https://jamf.example.com/api/v1/policies"
        let redacted = LogRedactor.redact(input)
        XCTAssertEqual(input, redacted)
    }

    // MARK: - api_key / apikey

    func testRedactsApiKeyYAML() {
        // 16-char value above the 8-char floor.
        let input = "api_key: abcd1234efgh5678"
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_API_KEY"))
        XCTAssertFalse(redacted.contains("abcd1234efgh5678"))
    }

    func testRedactsApikeyEqualsForm() {
        // `apikey` (no underscore) in equals/URL form — 24-char value.
        let input = #"apikey="abcdef0123456789abcdef01""#
        let redacted = LogRedactor.redact(input)
        XCTAssertTrue(redacted.contains("REDACTED_API_KEY"))
        XCTAssertFalse(redacted.contains("abcdef0123456789abcdef01"))
    }

    // MARK: - Passthrough

    func testNoMatchReturnsInputUnchanged() {
        let input = "[ok] Collected 47 computers in 9s"
        XCTAssertEqual(LogRedactor.redact(input), input)
    }

    func testEmptyStringReturnsEmpty() {
        XCTAssertEqual(LogRedactor.redact(""), "")
    }

    // MARK: - notify.url (the app's own webhook key)

    /// NotifyConfig stores the webhook at `notify.url`, so the `webhook_url`
    /// rule never fires on it. The path is the credential, so masking the
    /// host alone would leave a usable token behind a well-known hostname.
    func testNotifyURLSlackWebhookIsRedacted() {
        let secret = "T0ABCDEF/B0GHIJKL/9xQ2fTnotarealtoken"
        let redacted = LogRedactor.redact("  url: \"https://hooks.slack.com/services/\(secret)\"")
        XCTAssertFalse(redacted.contains(secret), "webhook path token must not survive")
        XCTAssertFalse(redacted.contains("hooks.slack.com"))
    }

    func testNotifyURLTeamsWebhookIsRedacted() {
        let secret = "IncomingWebhook/0123456789abcdef0123456789abcdef/abc"
        let redacted = LogRedactor.redact(
            "url: https://contoso.webhook.office.com/webhookb2/\(secret)")
        XCTAssertFalse(redacted.contains(secret))
        XCTAssertFalse(redacted.contains("webhook.office.com"))
    }

    /// The webhook rules key on the endpoint shape, so an ordinary Jamf URL in
    /// a log line still passes through — this is a log redactor, not a URL
    /// stripper, and over-redaction costs diagnostic value.
    func testOrdinaryURLStillPassesThroughAfterWebhookRules() {
        let input = "Connecting to https://jamf.example.com/api/v1/policies"
        XCTAssertEqual(LogRedactor.redact(input), input)
    }

    // MARK: - Teams Workflows and Power Automate webhooks

    /// A Workflows (Logic Apps / Power Automate) trigger URL carries its credential as a `sig=`
    /// query value, so the whole URL goes; none of these hosts is `webhook.office.com`.
    private static let workflowWebhooks: [(host: String, url: String)] = [
        ("logic.azure.com",
         "https://prod-12.westus.logic.azure.com:443/workflows/0a1b2c3d/triggers/manual/paths/"
         + "invoke?api-version=2016-06-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=Zm9vYmFyU0lH"),
        ("logic.azure.us",
         "https://prod-03.usgovvirginia.logic.azure.us/workflows/9f8e7d/triggers/manual/paths/"
         + "invoke?api-version=2016-06-01&sig=Zm9vYmFyU0lH"),
        ("api.powerplatform.com",
         "https://env0123.4.environment.api.powerplatform.com/powerautomate/automations/direct/"
         + "workflows/abc123/triggers/manual/paths/invoke?api-version=1&sv=1.0&sig=Zm9vYmFyU0lH"),
        ("api.powerplatform.us",
         "https://env0123.4.environment.api.powerplatform.us/powerautomate/automations/direct/"
         + "workflows/abc123/triggers/manual/paths/invoke?api-version=1&sig=Zm9vYmFyU0lH"),
    ]

    func testRedactsWorkflowWebhookHostsInAnyContext() {
        for (host, url) in Self.workflowWebhooks {
            let redacted = LogRedactor.redact("POST to \(url) returned 202")
            XCTAssertEqual(redacted, "POST to REDACTED_WEBHOOK_URL returned 202", host)
        }
    }

    func testRedactsWorkflowWebhookAtNotifyURL() {
        for (host, url) in Self.workflowWebhooks {
            let redacted = LogRedactor.redact("  url: \"\(url)\"")
            XCTAssertFalse(redacted.contains("sig="), host)
            XCTAssertFalse(redacted.contains(host), host)
        }
    }

    func testRedactsSignatureQueryValueOnAnyHost() {
        let redacted = LogRedactor.redact(
            "retry https://flows.example.com/invoke?api-version=1&sig=Zm9vYmFyU0lH&x=1 later")
        XCTAssertFalse(redacted.contains("Zm9vYmFyU0lH"), "a sig= value is a credential")
        XCTAssertTrue(redacted.contains("sig=REDACTED_SIG"))
        XCTAssertTrue(redacted.contains("&x=1 later"), "text after the value stays")
    }

    func testSignatureRuleLeavesUnrelatedWordsAlone() {
        let input = "assigned design=sig-less; sigma=1"
        XCTAssertEqual(LogRedactor.redact(input), input)
    }

    func testOtherAzureAndPowerPlatformURLsPassThrough() {
        let input = "see https://learn.microsoft.com/azure/logic-apps and "
            + "https://api.powerplatform.com/health"
        XCTAssertEqual(LogRedactor.redact(input), input)
    }

    // MARK: - redactedForSharing

    /// The fixture line from `FailureCauseTests`: jamf-cli names the host and the environment ID.
    private let environmentNotFound = "API request failed with status 404 Not Found, traceId "
        + "0000000000000000 (method=GET, url=https://us.api.jamfcloud.com/compliance-benchmarks/"
        + "v1/benchmarks): [ENVIRONMENT_NOT_FOUND] Environment "
        + "'3f2b8c1e-5d4a-4e7b-9c10-a1b2c3d4e5f6' not found."

    func testSharingDropsTheHostAndTheScopeIDButKeepsTheRest() {
        let shared = LogRedactor.redactedForSharing(
            environmentNotFound, profile: "harbor",
            scopeIDs: { $0 == "harbor" ? ["3F2B8C1E-5D4A-4E7B-9C10-A1B2C3D4E5F6"] : [] })

        XCTAssertFalse(shared.contains("jamfcloud.com"), "the Jamf host must not leave")
        XCTAssertFalse(shared.lowercased().contains("3f2b8c1e"), "the environment ID must leave")
        // The bundle's `url=` rule replaces the whole value, endpoint path included.
        XCTAssertTrue(shared.contains("(method=GET, url=REDACTED_URL"), shared)
        XCTAssertTrue(shared.contains("[ENVIRONMENT_NOT_FOUND] Environment '"))
        XCTAssertTrue(shared.contains("' not found."))
        XCTAssertTrue(shared.contains("API request failed with status 404 Not Found"))
    }

    func testSharingWithNoProfileLooksUpNoScopeIDs() {
        var asked = false
        let shared = LogRedactor.redactedForSharing(
            environmentNotFound, profile: nil, scopeIDs: { _ in asked = true; return [] })

        XCTAssertFalse(asked, "demo mode must not read the jamf-cli config")
        XCTAssertFalse(shared.contains("jamfcloud.com"), "the host goes with or without a profile")
    }

    func testSharingStillAppliesTheCredentialPatterns() {
        let shared = LogRedactor.redactedForSharing(
            "client_secret: super-secret-value-1234", profile: nil)
        XCTAssertFalse(shared.contains("super-secret-value-1234"))
    }
}
