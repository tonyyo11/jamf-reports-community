import XCTest
@testable import JamfReports

/// One reading of a profile's `auth-method` (2.10). Before it, the app compared the raw text
/// three ways (`== "platform"`, lowercased, `.contains("platform")`), and an unusable profile
/// carried its reason in that text, so "(same folder as prod-platform)" read as Platform.
final class JamfCLIAuthMethodTests: XCTestCase {
    /// Matched as jamf-cli matches it: exactly, after trimming, so `Platform` is not Platform.
    func testReadsJamfCLIsValuesAsJamfCLIDoes() {
        XCTAssertEqual(JamfCLIAuthMethod(raw: "platform"), .platform)
        XCTAssertEqual(JamfCLIAuthMethod(raw: " platform\n"), .platform)
        XCTAssertEqual(JamfCLIAuthMethod(raw: "Platform"), .other("Platform"))
        XCTAssertEqual(JamfCLIAuthMethod(raw: "oauth2"), .oauth2)
        XCTAssertEqual(JamfCLIAuthMethod(raw: "apikey"), .apiKey)
        XCTAssertEqual(JamfCLIAuthMethod(raw: "security"), .security)
        XCTAssertEqual(JamfCLIAuthMethod(raw: "token"), .other("token"))
        XCTAssertNil(JamfCLIAuthMethod(raw: "  "))
        XCTAssertNil(JamfCLIAuthMethod(raw: nil))
    }

    func testOnlyTheWholeWordIsPlatform() {
        XCTAssertFalse(JamfCLIAuthMethod(raw: "platform-legacy")?.isPlatform ?? true)
        XCTAssertFalse(JamfCLIAuthMethod(raw: "(same folder as prod-platform)")?.isPlatform ?? true)
    }

    func testAnUnusableProfileHasNoAuthAndKeepsItsReasonApart() {
        let unusable = JamfCLIProfile(
            name: "Prod-Platform", url: "", schedules: 0, status: .error,
            authMethod: "platform", unusableReason: "(same folder as prod-platform)")
        XCTAssertNil(unusable.auth)
        XCTAssertEqual(unusable.authMethod, "platform", "what jamf-cli reported, for display")

        let usable = JamfCLIProfile(
            name: "prod-platform", url: "", schedules: 0, status: .ok, authMethod: "platform ")
        XCTAssertEqual(usable.auth, .platform)
    }

    func testTheReadersThatTookStringsAgree() {
        XCTAssertTrue(ReauthenticateSheet.prefersPlatformGateway(authMethod: " platform "))
        XCTAssertFalse(ReauthenticateSheet.prefersPlatformGateway(authMethod: "oauth2"))
        XCTAssertTrue(CLIBridge.shouldSkipAuthProbe(for: "apikey "))
        XCTAssertEqual(ReportEngine.nonPlatformAuthMethod(" oauth2 "), "oauth2")
        XCTAssertNil(ReportEngine.nonPlatformAuthMethod("platform"))
        XCTAssertNil(ReportEngine.nonPlatformAuthMethod(nil), "unknown skips nothing")
        XCTAssertEqual(
            WorkspaceStore.consoleServer(forProfileURL: "https://us.api.jamfcloud.com",
                                         authMethod: "platform"), "")
    }

    func testDiscoveryPutsTheReasonInItsOwnField() {
        let rows = ProfileService.unusableProfiles(in: ["Acme", "acme"])
        XCTAssertFalse(rows.isEmpty, "two spellings of one folder: one is unusable")
    }
}
