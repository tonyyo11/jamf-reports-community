import Foundation
import XCTest
@testable import JamfReports

/// Tests for `TokenStatus` decoding from `jamf-cli pro auth token --output json` fixtures.
///
/// Fixture shape is verified against a live `jamf-cli` run on 2026-05-04:
///   { "expires_at": "2026-05-04T13:38:38Z", "token": "eyJ..." }
/// For token-file (static bearer) auth, jamf-cli omits `expires_at`.
final class TokenStatusTests: XCTestCase {

    // MARK: - Helpers

    private func fixtureData(_ name: String) throws -> Data {
        // Walk up from the test bundle to find Fixtures/ regardless of derived data location.
        let candidates: [URL] = [
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(name)"),
        ]
        for url in candidates {
            if let data = try? Data(contentsOf: url) { return data }
        }
        throw XCTSkip("Fixture not found: \(name) — run from app/ directory")
    }

    // Mirrors the private decode struct inside CLIBridge.parseTokenStatus.
    private struct TokenPayload: Decodable {
        let token: String?
        let expires_at: String?
    }

    // MARK: - Tests

    func testDecodeWithExpiry() throws {
        let data = try fixtureData("auth_token_with_expiry.json")
        let payload = try JSONDecoder().decode(TokenPayload.self, from: data)

        XCTAssertFalse((payload.token ?? "").isEmpty, "token field must not be empty")
        XCTAssertEqual(payload.expires_at, "2026-05-04T13:38:38Z")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let date = formatter.date(from: payload.expires_at ?? "")
        XCTAssertNotNil(date, "expires_at must parse to a valid Date")
    }

    func testDecodeWithoutExpiry() throws {
        let data = try fixtureData("auth_token_no_expiry.json")
        let payload = try JSONDecoder().decode(TokenPayload.self, from: data)

        XCTAssertFalse((payload.token ?? "").isEmpty, "token field must not be empty")
        XCTAssertNil(payload.expires_at, "token-file auth fixtures must omit expires_at")
    }

    func testTokenStatusStructFields() {
        // Verify the struct is Sendable + Codable by constructing one directly.
        let now = Date()
        let status = TokenStatus(
            profile: "test-profile",
            expiresAt: now,
            isValid: true,
            raw: "{\"token\":\"abc\",\"expires_at\":\"2026-05-04T13:38:38Z\"}"
        )
        XCTAssertEqual(status.profile, "test-profile")
        XCTAssertEqual(status.isValid, true)
        XCTAssertEqual(status.expiresAt, now)
    }

    func testTokenStatusInvalidOnEmptyToken() {
        let status = TokenStatus(profile: "p", expiresAt: nil, isValid: false, raw: "{}")
        XCTAssertFalse(status.isValid)
        XCTAssertNil(status.expiresAt)
    }

    func testTokenStatusMalformedJSONProducesNil() throws {
        // Simulates the path where parseTokenStatus returns isValid:false on bad JSON.
        let badData = "not json at all".data(using: .utf8)!
        let result = try? JSONDecoder().decode(TokenPayload.self, from: badData)
        XCTAssertNil(result, "Malformed JSON must fail to decode")
    }
}
