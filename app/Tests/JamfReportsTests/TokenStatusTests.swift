import Foundation
import XCTest
@testable import JamfReports

/// Tests for `TokenStatus` and `CLIBridge.parseTokenStatus`.
///
/// Fixture shape verified against a live `jamf-cli` run on 2026-05-04:
///   { "expires_at": "2026-05-04T13:38:38Z", "token": "eyJ..." }
/// For token-file (static bearer) auth, jamf-cli omits `expires_at`.
final class TokenStatusTests: XCTestCase {

    // MARK: - Helpers

    private func fixtureData(_ name: String) throws -> Data {
        let url = TestFixtures.dir(name)
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("Fixture not found: \(name)")
        }
        return data
    }

    private func makeBridge() -> CLIBridge { CLIBridge() }

    // MARK: - Fixture decode tests

    func testDecodeWithExpiry() throws {
        let data = try fixtureData("auth_token_with_expiry.json")
        let bridge = makeBridge()
        let status = bridge.parseTokenStatus(
            profile: "test",
            data: data
        )

        XCTAssertTrue(status.isValid, "token field must not be empty")
        XCTAssertNotNil(status.expiresAt, "expires_at must parse to a valid Date")
    }

    func testDecodeWithoutExpiry() throws {
        let data = try fixtureData("auth_token_no_expiry.json")
        let bridge = makeBridge()
        let status = bridge.parseTokenStatus(
            profile: "test",
            data: data
        )

        XCTAssertTrue(status.isValid, "token field must not be empty")
        XCTAssertNil(status.expiresAt, "token-file auth fixtures must omit expires_at")
    }

    // MARK: - parseTokenStatus behavior tests

    func testParseTokenStatus_validToken_returnsIsValidTrue() {
        let json = #"{"token":"eyJhbGciOiJSUzI1NiJ9.abc","expires_at":"2099-01-01T00:00:00Z"}"#
        let data = json.data(using: .utf8)!
        let bridge = makeBridge()

        let status = bridge.parseTokenStatus(profile: "p", data: data)

        XCTAssertTrue(status.isValid)
        XCTAssertEqual(status.profile, "p")
    }

    func testParseTokenStatus_emptyToken_returnsIsValidFalse() {
        let json = #"{"token":""}"#
        let data = json.data(using: .utf8)!
        let bridge = makeBridge()

        let status = bridge.parseTokenStatus(profile: "p", data: data)

        XCTAssertFalse(status.isValid)
    }

    func testParseTokenStatus_missingToken_returnsIsValidFalse() {
        let json = #"{}"#
        let data = json.data(using: .utf8)!
        let bridge = makeBridge()

        let status = bridge.parseTokenStatus(profile: "p", data: data)

        XCTAssertFalse(status.isValid)
    }

    func testParseTokenStatus_withExpiry_setsExpiresAt() {
        let json = #"{"token":"abc","expires_at":"2099-06-01T12:00:00Z"}"#
        let data = json.data(using: .utf8)!
        let bridge = makeBridge()

        let status = bridge.parseTokenStatus(profile: "p", data: data)

        XCTAssertNotNil(status.expiresAt)
        // Verify the year parsed correctly.
        let cal = Calendar(identifier: .gregorian)
        XCTAssertEqual(cal.component(.year, from: status.expiresAt!), 2099)
    }

    func testParseTokenStatus_malformedJSON_returnsIsValidFalse() {
        let data = "not json at all".data(using: .utf8)!
        let bridge = makeBridge()

        let status = bridge.parseTokenStatus(profile: "p", data: data)

        XCTAssertFalse(status.isValid)
        XCTAssertNil(status.expiresAt)
    }

    // MARK: - isExpired tests

    func testIsExpired_pastDate_returnsTrue() {
        let past = Date(timeIntervalSinceNow: -3600)
        let status = TokenStatus.make(
            profile: "p",
            token: "tok",
            expiresAt: past
        )

        XCTAssertTrue(status.isExpired)
    }

    func testIsExpired_futureDate_returnsFalse() {
        let future = Date(timeIntervalSinceNow: 3600)
        let status = TokenStatus.make(
            profile: "p",
            token: "tok",
            expiresAt: future
        )

        XCTAssertFalse(status.isExpired)
    }

    func testIsExpired_nilExpiresAt_returnsFalse() {
        let status = TokenStatus.make(profile: "p", token: "tok", expiresAt: nil)

        XCTAssertFalse(status.isExpired)
    }

    // MARK: - make() factory tests

    func testMake_emptyToken_isValidFalse() {
        let status = TokenStatus.make(profile: "p", token: "", expiresAt: nil)
        XCTAssertFalse(status.isValid)
    }

    func testMake_nilToken_isValidFalse() {
        let status = TokenStatus.make(profile: "p", token: nil, expiresAt: nil)
        XCTAssertFalse(status.isValid)
    }

    func testMake_nonEmptyToken_isValidTrue() {
        let status = TokenStatus.make(profile: "p", token: "abc", expiresAt: nil)
        XCTAssertTrue(status.isValid)
        XCTAssertEqual(status.profile, "p")
    }

    // MARK: - Legacy struct-field tests (backward compat)

    func testTokenStatusStructFields() {
        let now = Date()
        let status = TokenStatus.make(
            profile: "test-profile",
            token: "abc",
            expiresAt: now
        )
        XCTAssertEqual(status.profile, "test-profile")
        XCTAssertEqual(status.isValid, true)
        XCTAssertEqual(status.expiresAt, now)
    }

    func testTokenStatusInvalidOnEmptyToken() {
        let status = TokenStatus.make(profile: "p", token: nil, expiresAt: nil)
        XCTAssertFalse(status.isValid)
        XCTAssertNil(status.expiresAt)
    }

    // MARK: - Codable round-trip tests

    func testCodable_tokenIsNotEncoded() throws {
        let status = TokenStatus.make(
            profile: "test-profile",
            token: "secret-token",
            expiresAt: nil
        )
        let data = try JSONEncoder().encode(status)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("secret-token"), "the token must not appear in encoded JSON")
    }

    func testCodable_decodesThePersistedFields() throws {
        let json = #"{"profile":"test-profile","isValid":true}"#
        let decoded = try JSONDecoder().decode(
            TokenStatus.self,
            from: json.data(using: .utf8)!
        )
        XCTAssertTrue(decoded.isValid)
        XCTAssertEqual(decoded.profile, "test-profile")
    }

    func testParsedStatusHoldsNoCopyOfTheToken() {
        let json = #"{"token":"eyJ.secret.jwt","expires_at":"2026-05-04T13:38:38Z"}"#
        let status = CLIBridge().parseTokenStatus(profile: "p", data: Data(json.utf8))
        // The status outlives the probe in `WorkspaceStore.authStatus`; nothing in it may
        // keep the bearer token.
        XCTAssertFalse(String(reflecting: status).contains("eyJ.secret.jwt"))
        XCTAssertFalse(
            Mirror(reflecting: status).children.contains { "\($0.value)".contains("eyJ") }
        )
    }

    // MARK: - Empty profile guard

    func testMake_emptyProfile_isValidFalse() {
        let status = TokenStatus.make(profile: "", token: "valid-token", expiresAt: nil)
        XCTAssertFalse(status.isValid, "empty profile must produce isValid false")
        XCTAssertEqual(status.profile, "")
    }
}
