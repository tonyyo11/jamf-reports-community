import XCTest
@testable import JamfReports

/// Spec 2026-09-12 §10.4: a rejected ID blocks setup; "Continue without validating" is offered
/// for a Platform API profile when Validate fails or the check could not decide. OAuth2 is
/// unchanged.
@MainActor
final class OnboardingConnectionCheckTests: XCTestCase {
    func test_skipFinishText_doesNotCallAnUnvalidatedProfileFullySetUp() {
        XCTAssertTrue(OnboardingView.skipFinishText(validated: true).contains("fully set up"))
        let unvalidated = OnboardingView.skipFinishText(validated: false)
        XCTAssertFalse(unvalidated.contains("fully set up"))
        XCTAssertTrue(unvalidated.contains("did not validate"))
    }

    /// School has no Validate step: its Connect step is the check, so a connected School
    /// setup is never told its profile did not validate.
    func testASchoolSetupCountsItsConnectStepAsTheCheck() {
        let flow = OnboardingFlow()
        flow.productPath = .school
        XCTAssertFalse(flow.connectionConfirmed)
        flow.schoolConnected = true
        XCTAssertTrue(flow.connectionConfirmed)
        flow.productPath = .pro
        XCTAssertFalse(flow.connectionConfirmed, "Jamf Pro still needs Validate")
        flow.connectionValidated = true
        XCTAssertTrue(flow.connectionConfirmed)
    }

    func testOnlyAFirstReportThatExitedZeroFinishesSetup() {
        let flow = OnboardingFlow()
        XCTAssertFalse(flow.firstReportSucceeded)
        flow.firstReportExitCode = 1
        XCTAssertFalse(flow.firstReportSucceeded)
        flow.firstReportExitCode = -1
        XCTAssertFalse(flow.firstReportSucceeded)
        flow.firstReportExitCode = 0
        XCTAssertTrue(flow.firstReportSucceeded)
    }

    /// Going back from the last step can change the profile, so coming forward runs again.
    func testGoingBackFromTheFirstReportClearsItsResult() {
        let flow = OnboardingFlow()
        flow.currentStep = .firstReport
        flow.firstReportExitCode = 0
        flow.previousStep()
        XCTAssertNotEqual(flow.currentStep, .firstReport)
        XCTAssertNil(flow.firstReportExitCode)
        XCTAssertFalse(flow.firstReportSucceeded)
    }


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

    func testAMissingPermissionDoesNotValidateButOffersTheBypass() {
        let flow = flowAtValidate(.platformGateway, exit: 0)
        flow.applyConnectionCheck(.missingPermission(names: ["Read"]))
        XCTAssertFalse(flow.connectionValidated)
        XCTAssertTrue(flow.offersContinueWithoutValidating)
        XCTAssertEqual(flow.connectionCheck, .missingPermission(names: ["Read"]))
    }

    func testNoJamfProDoesNotValidateAndOffersNoWayOn() {
        let flow = flowAtValidate(.platformGateway, exit: 0)
        flow.applyConnectionCheck(.noJamfPro)
        XCTAssertFalse(flow.connectionValidated)
        XCTAssertFalse(flow.offersContinueWithoutValidating)
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
