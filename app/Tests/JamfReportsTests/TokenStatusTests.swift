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
            data: data,
            raw: String(decoding: data, as: UTF8.self)
        )

        XCTAssertTrue(status.isValid, "token field must not be empty")
        XCTAssertNotNil(status.expiresAt, "expires_at must parse to a valid Date")
    }

    func testDecodeWithoutExpiry() throws {
        let data = try fixtureData("auth_token_no_expiry.json")
        let bridge = makeBridge()
        let status = bridge.parseTokenStatus(
            profile: "test",
            data: data,
            raw: String(decoding: data, as: UTF8.self)
        )

        XCTAssertTrue(status.isValid, "token field must not be empty")
        XCTAssertNil(status.expiresAt, "token-file auth fixtures must omit expires_at")
    }

    // MARK: - parseTokenStatus behavior tests

    func testParseTokenStatus_validToken_returnsIsValidTrue() {
        let json = #"{"token":"eyJhbGciOiJSUzI1NiJ9.abc","expires_at":"2099-01-01T00:00:00Z"}"#
        let data = json.data(using: .utf8)!
        let bridge = makeBridge()

        let status = bridge.parseTokenStatus(profile: "p", data: data, raw: json)

        XCTAssertTrue(status.isValid)
        XCTAssertEqual(status.profile, "p")
    }

    func testParseTokenStatus_emptyToken_returnsIsValidFalse() {
        let json = #"{"token":""}"#
        let data = json.data(using: .utf8)!
        let bridge = makeBridge()

        let status = bridge.parseTokenStatus(profile: "p", data: data, raw: json)

        XCTAssertFalse(status.isValid)
    }

    func testParseTokenStatus_missingToken_returnsIsValidFalse() {
        let json = #"{}"#
        let data = json.data(using: .utf8)!
        let bridge = makeBridge()

        let status = bridge.parseTokenStatus(profile: "p", data: data, raw: json)

        XCTAssertFalse(status.isValid)
    }

    func testParseTokenStatus_withExpiry_setsExpiresAt() {
        let json = #"{"token":"abc","expires_at":"2099-06-01T12:00:00Z"}"#
        let data = json.data(using: .utf8)!
        let bridge = makeBridge()

        let status = bridge.parseTokenStatus(profile: "p", data: data, raw: json)

        XCTAssertNotNil(status.expiresAt)
        // Verify the year parsed correctly.
        let cal = Calendar(identifier: .gregorian)
        XCTAssertEqual(cal.component(.year, from: status.expiresAt!), 2099)
    }

    func testParseTokenStatus_malformedJSON_returnsIsValidFalse() {
        let data = "not json at all".data(using: .utf8)!
        let bridge = makeBridge()

        let status = bridge.parseTokenStatus(profile: "p", data: data, raw: "not json at all")

        XCTAssertFalse(status.isValid)
        XCTAssertNil(status.expiresAt)
    }

    // MARK: - isExpired tests

    func testIsExpired_pastDate_returnsTrue() {
        let past = Date(timeIntervalSinceNow: -3600)
        let status = TokenStatus.make(
            profile: "p",
            token: "tok",
            expiresAt: past,
            raw: ""
        )

        XCTAssertTrue(status.isExpired)
    }

    func testIsExpired_futureDate_returnsFalse() {
        let future = Date(timeIntervalSinceNow: 3600)
        let status = TokenStatus.make(
            profile: "p",
            token: "tok",
            expiresAt: future,
            raw: ""
        )

        XCTAssertFalse(status.isExpired)
    }

    func testIsExpired_nilExpiresAt_returnsFalse() {
        let status = TokenStatus.make(profile: "p", token: "tok", expiresAt: nil, raw: "")

        XCTAssertFalse(status.isExpired)
    }

    // MARK: - make() factory tests

    func testMake_emptyToken_isValidFalse() {
        let status = TokenStatus.make(profile: "p", token: "", expiresAt: nil, raw: "{}")
        XCTAssertFalse(status.isValid)
    }

    func testMake_nilToken_isValidFalse() {
        let status = TokenStatus.make(profile: "p", token: nil, expiresAt: nil, raw: "{}")
        XCTAssertFalse(status.isValid)
    }

    func testMake_nonEmptyToken_isValidTrue() {
        let status = TokenStatus.make(profile: "p", token: "abc", expiresAt: nil, raw: "{}")
        XCTAssertTrue(status.isValid)
        XCTAssertEqual(status.profile, "p")
    }

    // MARK: - Legacy struct-field tests (backward compat)

    func testTokenStatusStructFields() {
        let now = Date()
        let status = TokenStatus.make(
            profile: "test-profile",
            token: "abc",
            expiresAt: now,
            raw: "{\"token\":\"abc\",\"expires_at\":\"2026-05-04T13:38:38Z\"}"
        )
        XCTAssertEqual(status.profile, "test-profile")
        XCTAssertEqual(status.isValid, true)
        XCTAssertEqual(status.expiresAt, now)
    }

    func testTokenStatusInvalidOnEmptyToken() {
        let status = TokenStatus.make(profile: "p", token: nil, expiresAt: nil, raw: "{}")
        XCTAssertFalse(status.isValid)
        XCTAssertNil(status.expiresAt)
    }

    // MARK: - Codable round-trip tests

    func testCodable_rawIsExcludedFromEncodedJSON() throws {
        let status = TokenStatus.make(
            profile: "test-profile",
            token: "secret-token",
            expiresAt: nil,
            raw: "sensitive-raw-data"
        )
        let data = try JSONEncoder().encode(status)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("raw"), "key 'raw' must not appear in encoded JSON")
        XCTAssertFalse(json.contains("sensitive-raw-data"), "raw value must not appear in encoded JSON")
    }

    func testCodable_decodeRestoresRawAsEmpty() throws {
        let json = #"{"profile":"test-profile","isValid":true}"#
        let decoded = try JSONDecoder().decode(
            TokenStatus.self,
            from: json.data(using: .utf8)!
        )
        XCTAssertEqual(decoded.raw, "", "decoded TokenStatus.raw must be empty string")
        XCTAssertTrue(decoded.isValid)
        XCTAssertEqual(decoded.profile, "test-profile")
    }

    // MARK: - Empty profile guard

    func testMake_emptyProfile_isValidFalse() {
        let status = TokenStatus.make(profile: "", token: "valid-token", expiresAt: nil, raw: "{}")
        XCTAssertFalse(status.isValid, "empty profile must produce isValid false")
        XCTAssertEqual(status.profile, "")
    }
}
