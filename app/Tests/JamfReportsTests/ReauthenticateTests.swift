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

    func testPrefersPlatformGatewayForPlatformAuthMethod() {
        XCTAssertTrue(ReauthenticateSheet.prefersPlatformGateway(authMethod: "platform"))
        XCTAssertTrue(ReauthenticateSheet.prefersPlatformGateway(authMethod: "Platform"))
        XCTAssertTrue(ReauthenticateSheet.prefersPlatformGateway(authMethod: "platform-gateway"))
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
            isBusy: false, gatewayURLValid: true, scope: .environment, scopeID: "e1",
            clientID: "abc", hasSecret: true))
    }

    func testPlatformVerifyDisabledOnBlankScopeID() {
        XCTAssertFalse(ReauthenticateSheet.canVerifyPlatform(
            isBusy: false, gatewayURLValid: true, scope: .environment, scopeID: " ",
            clientID: "abc", hasSecret: true))
    }

    func testPlatformVerifyEnabledForOrganizationScopeWithNoID() {
        XCTAssertTrue(ReauthenticateSheet.canVerifyPlatform(
            isBusy: false, gatewayURLValid: true, scope: .organization, scopeID: "",
            clientID: "abc", hasSecret: true))
    }

    func testPlatformVerifyDisabledOnInvalidGatewayURL() {
        XCTAssertFalse(ReauthenticateSheet.canVerifyPlatform(
            isBusy: false, gatewayURLValid: false, scope: .environment, scopeID: "e1",
            clientID: "abc", hasSecret: true))
    }

    func testPlatformVerifyDisabledWithoutSecret() {
        XCTAssertFalse(ReauthenticateSheet.canVerifyPlatform(
            isBusy: false, gatewayURLValid: true, scope: .environment, scopeID: "e1",
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
