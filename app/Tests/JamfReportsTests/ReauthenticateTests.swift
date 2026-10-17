import XCTest
@testable import JamfReports

/// Unit coverage for `ReauthenticateSheet`'s pure gating/prefill logic.
///
/// The credential-transport, redaction, and clearing behavior is deliberately
/// NOT re-tested here — the sheet reuses `OnboardingFlow`'s already-tested PTY
/// stdin path verbatim (see OnboardingFlowRedactionTests). These tests cover
/// only the sheet's own decisions: which form to prefill and when the
/// "Verify & save" action is enabled.
@MainActor
final class ReauthenticateTests: XCTestCase {

    // MARK: - Form selection from recorded auth method

    /// Reported on 2.10.0: a Jamf School workspace opened the Jamf Pro form, labelled its
    /// School URL "Jamf Pro URL" and could not save School credentials.
    func testASchoolWorkspaceGetsTheSchoolFormWhateverItsAuthMethod() {
        XCTAssertEqual(ReauthenticateSheet.form(isSchool: true, authMethod: "apikey"), .school)
        XCTAssertEqual(ReauthenticateSheet.form(isSchool: true, authMethod: "platform"), .school)
        XCTAssertEqual(ReauthenticateSheet.form(isSchool: true, authMethod: ""), .school)
    }

    func testAJamfProWorkspaceKeepsItsForms() {
        XCTAssertEqual(
            ReauthenticateSheet.form(isSchool: false, authMethod: "platform"), .platformGateway)
        XCTAssertEqual(ReauthenticateSheet.form(isSchool: false, authMethod: "oauth2"), .oauth2)
        XCTAssertEqual(ReauthenticateSheet.form(isSchool: false, authMethod: "apikey"), .oauth2)
    }

    func testSchoolVerifyNeedsAURLANetworkIDAndAKey() {
        XCTAssertTrue(ReauthenticateSheet.canVerifySchool(
            isBusy: false, urlValid: true, networkID: "123", hasKey: true))
        XCTAssertFalse(ReauthenticateSheet.canVerifySchool(
            isBusy: true, urlValid: true, networkID: "123", hasKey: true))
        XCTAssertFalse(ReauthenticateSheet.canVerifySchool(
            isBusy: false, urlValid: false, networkID: "123", hasKey: true))
        XCTAssertFalse(ReauthenticateSheet.canVerifySchool(
            isBusy: false, urlValid: true, networkID: "  ", hasKey: true))
        XCTAssertFalse(ReauthenticateSheet.canVerifySchool(
            isBusy: false, urlValid: true, networkID: "123", hasKey: false))
    }

    /// The URL jamf-cli stored for Keith's profile had no scheme and ended in /api; the School
    /// form reads it as valid and saves it without /api.
    func testAStoredSchoolURLWithoutSchemeOrWithAPIIsUsable() {
        XCTAssertEqual(OnboardingFlow.normalizedSchoolURL("albion.jamfcloud.com/api"),
                       "https://albion.jamfcloud.com")
    }

    func testPrefersPlatformGatewayForPlatformAuthMethod() {
        XCTAssertTrue(ReauthenticateSheet.prefersPlatformGateway(authMethod: "platform"))
        // jamf-cli matches `platform` exactly (2.10, `JamfCLIAuthMethod`): neither of these is a
        // gateway profile to it.
        XCTAssertFalse(ReauthenticateSheet.prefersPlatformGateway(authMethod: "Platform"))
        XCTAssertFalse(ReauthenticateSheet.prefersPlatformGateway(authMethod: "platform-gateway"))
    }

    func testDefaultsToOAuth2ForOtherAuthMethods() {
        XCTAssertFalse(ReauthenticateSheet.prefersPlatformGateway(authMethod: "oauth2"))
        XCTAssertFalse(ReauthenticateSheet.prefersPlatformGateway(authMethod: ""))
        XCTAssertFalse(ReauthenticateSheet.prefersPlatformGateway(authMethod: "basic"))
    }

    // MARK: - OAuth2 verify gating

    func testOAuth2VerifyEnabledWhenComplete() {
        XCTAssertTrue(ReauthenticateSheet.canVerifyOAuth2(
            isBusy: false, urlValid: true, clientID: "abc", hasSecret: true))
    }

    func testOAuth2VerifyDisabledWhileBusy() {
        XCTAssertFalse(ReauthenticateSheet.canVerifyOAuth2(
            isBusy: true, urlValid: true, clientID: "abc", hasSecret: true))
    }

    func testOAuth2VerifyDisabledOnInvalidURL() {
        XCTAssertFalse(ReauthenticateSheet.canVerifyOAuth2(
            isBusy: false, urlValid: false, clientID: "abc", hasSecret: true))
    }

    func testOAuth2VerifyDisabledOnBlankClientID() {
        XCTAssertFalse(ReauthenticateSheet.canVerifyOAuth2(
            isBusy: false, urlValid: true, clientID: "   ", hasSecret: true))
    }

    func testOAuth2VerifyDisabledWithoutSecret() {
        XCTAssertFalse(ReauthenticateSheet.canVerifyOAuth2(
            isBusy: false, urlValid: true, clientID: "abc", hasSecret: false))
    }

    // MARK: - Platform Gateway verify gating

    func testPlatformVerifyEnabledWhenComplete() {
        XCTAssertTrue(ReauthenticateSheet.canVerifyPlatform(
            isBusy: false, gatewayURLValid: true, scopeID: "e1",
            clientID: "abc", hasSecret: true))
    }

    func testPlatformVerifyDisabledOnBlankScopeID() {
        XCTAssertFalse(ReauthenticateSheet.canVerifyPlatform(
            isBusy: false, gatewayURLValid: true, scopeID: " ",
            clientID: "abc", hasSecret: true))
    }

    func testPlatformVerifyDisabledOnAnUnusableScopeID() {
        for bad in ["--tenant-id", "my env", "é"] {
            XCTAssertFalse(ReauthenticateSheet.canVerifyPlatform(
                isBusy: false, gatewayURLValid: true, scopeID: bad,
                clientID: "abc", hasSecret: true), bad)
        }
        XCTAssertTrue(ReauthenticateSheet.canVerifyPlatform(
            isBusy: false, gatewayURLValid: true, scopeID: " e1 ",
            clientID: "abc", hasSecret: true))
    }

    func testPlatformVerifyDisabledOnInvalidGatewayURL() {
        XCTAssertFalse(ReauthenticateSheet.canVerifyPlatform(
            isBusy: false, gatewayURLValid: false, scopeID: "e1",
            clientID: "abc", hasSecret: true))
    }

    func testPlatformVerifyDisabledWithoutSecret() {
        XCTAssertFalse(ReauthenticateSheet.canVerifyPlatform(
            isBusy: false, gatewayURLValid: true, scopeID: "e1",
            clientID: "abc", hasSecret: false))
    }

    // MARK: - Health verdicts that offer re-authentication

    func testHealthNeedingCredentials() {
        XCTAssertTrue(SourcesView.healthNeedsCredentials(.credentialsUnresolved))
        XCTAssertTrue(SourcesView.healthNeedsCredentials(.unauthorized))
        XCTAssertTrue(SourcesView.healthNeedsCredentials(.noProfile))
    }

    func testHealthNotNeedingCredentials() {
        XCTAssertFalse(SourcesView.healthNeedsCredentials(.healthy))
        XCTAssertFalse(SourcesView.healthNeedsCredentials(.unreachable))
    }
}
