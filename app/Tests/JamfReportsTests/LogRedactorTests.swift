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

    // MARK: - Passthrough

    func testNoMatchReturnsInputUnchanged() {
        let input = "[ok] Collected 47 computers in 9s"
        XCTAssertEqual(LogRedactor.redact(input), input)
    }

    func testEmptyStringReturnsEmpty() {
        XCTAssertEqual(LogRedactor.redact(""), "")
    }
}
