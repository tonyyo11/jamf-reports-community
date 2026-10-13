import Foundation
import XCTest
@testable import JamfReports

/// The `jamf-cli config list` parsers `ProfileAuthMethod` reads a profile's auth method and
/// Platform scope level through.
final class JamfCLIConfigListTests: XCTestCase {
    private func method(_ json: String, _ profile: String) -> String? {
        JamfCLIConfigList.authMethod(data: Data(json.utf8), profile: profile)
    }

    func testReadsAPlatformAndAnOAuthProfile() {
        XCTAssertEqual(method("""
            [{"name": "lighthouse", "url": "https://gw", "auth-method": "platform"}]
            """, "lighthouse"), "platform")
        XCTAssertEqual(method("""
            [{"name": "dummy", "url": "https://x", "auth-method": "oauth2"}]
            """, "dummy"), "oauth2")
    }

    /// jamf-cli's value is read as JamfCLIAuthMethod reads it: trimmed, case kept.
    func testTrimsButKeepsCase() {
        XCTAssertEqual(method("""
            [{"name": "p", "auth-method": " platform "}]
            """, "p"), "platform")
        XCTAssertEqual(method("""
            [{"name": "p", "auth-method": "Platform"}]
            """, "p"), "Platform")
    }

    func testAbsentProfileUnreadableResponseAndEmptyFieldAreNil() {
        XCTAssertNil(method("""
            [{"name": "other", "auth-method": "platform"}]
            """, "missing"))
        XCTAssertNil(JamfCLIConfigList.authMethod(data: Data("not-json".utf8), profile: "x"))
        XCTAssertNil(method("""
            [{"name": "lighthouse", "default": true}]
            """, "lighthouse"))
    }

    func testAnEmptyProfileReadsTheDefaultRow() {
        XCTAssertEqual(method("""
            [{"name": "one", "auth-method": "oauth2", "default": false},
             {"name": "two", "auth-method": "platform", "default": true}]
            """, ""), "platform")
    }

    func testScopeLevelIsForPlatformProfilesOnly() {
        let json = Data("""
            [{"name": "env", "auth-method": "platform", "environment-id": "e"},
             {"name": "ten", "auth-method": "platform", "tenant-id": "t"},
             {"name": "cap", "auth-method": "PLATFORM", "tenant-id": "t"},
             {"name": "org", "auth-method": "platform"},
             {"name": "pro", "auth-method": "oauth2", "tenant-id": "t"}]
            """.utf8)
        XCTAssertEqual(JamfCLIConfigList.scopeLevel(data: json, profile: "env"), .environment)
        XCTAssertEqual(JamfCLIConfigList.scopeLevel(data: json, profile: "ten"), .tenant)
        XCTAssertEqual(JamfCLIConfigList.scopeLevel(data: json, profile: "org"), .organization)
        XCTAssertNil(JamfCLIConfigList.scopeLevel(data: json, profile: "pro"))
        XCTAssertNil(JamfCLIConfigList.scopeLevel(data: json, profile: "cap"), "as jamf-cli reads it")
        XCTAssertEqual(JamfCLIConfigList.isTenantLevel(data: json, profile: "ten"), true)
    }
}
