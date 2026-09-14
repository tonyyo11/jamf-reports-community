import XCTest
@testable import JamfReports

/// Spec 2026-09-12 §10.4: a rejected ID blocks setup; "Continue without validating" is offered
/// for a Platform API profile only when the check could not decide. OAuth2 is unchanged.
@MainActor
final class OnboardingConnectionCheckTests: XCTestCase {

    private func flowAtValidate(
        _ type: OnboardingFlow.ProConnectionType, exit: Int32
    ) -> OnboardingFlow {
        let flow = OnboardingFlow()
        flow.proConnectionType = type
        flow.currentStep = .validate
        flow.profileRegistered = true
        flow.validationExitCode = exit
        return flow
    }

    func testARejectedIDBlocksSetup() {
        let flow = flowAtValidate(.platformGateway, exit: 0)
        flow.applyConnectionCheck(.rejectedID(.unknownEnvironment))
        XCTAssertFalse(flow.connectionValidated)
        XCTAssertFalse(flow.offersContinueWithoutValidating)
    }

    func testAnUndecidedCheckOffersTheBypass() {
        let flow = flowAtValidate(.platformGateway, exit: 0)
        flow.applyConnectionCheck(.undecided(exitCode: 1))
        XCTAssertFalse(flow.connectionValidated)
        XCTAssertTrue(flow.offersContinueWithoutValidating)
    }

    func testNoJamfProValidatesWithAWarning() {
        let flow = flowAtValidate(.platformGateway, exit: 0)
        flow.applyConnectionCheck(.noJamfPro)
        XCTAssertTrue(flow.connectionValidated)
        XCTAssertEqual(flow.connectionCheck, .noJamfPro)
    }

    func testAnAcceptedIDValidates() {
        let flow = flowAtValidate(.platformGateway, exit: 0)
        flow.applyConnectionCheck(.accepted(jamfProVersion: "11.25.0"))
        XCTAssertTrue(flow.connectionValidated)
        XCTAssertFalse(flow.offersContinueWithoutValidating)
    }

    func testAPlatformProfileThatFailsValidateKeepsTheBypass() {
        let flow = flowAtValidate(.platformGateway, exit: CLIBridge.exitCodeUnauthorized)
        XCTAssertTrue(flow.offersContinueWithoutValidating)
    }

    func testOAuth2KeepsTheBypassAfterAFailedValidate() {
        XCTAssertTrue(flowAtValidate(.oauth2, exit: 1).offersContinueWithoutValidating)
        XCTAssertFalse(flowAtValidate(.oauth2, exit: 0).offersContinueWithoutValidating)
    }
}
