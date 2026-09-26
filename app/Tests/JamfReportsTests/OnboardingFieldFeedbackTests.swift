import XCTest
@testable import JamfReports

/// A setup field nothing has been typed into shows its rule as a hint, not as an error;
/// Continue stays disabled while the value is invalid either way.
@MainActor
final class OnboardingFieldFeedbackTests: XCTestCase {

    func test_emptyField_isHint() {
        XCTAssertEqual(OnboardingFlow.feedback(for: "", isValid: false), .hint)
    }

    func test_whitespaceOnlyField_isHint() {
        XCTAssertEqual(OnboardingFlow.feedback(for: "  \n", isValid: false), .hint)
    }

    func test_typedInvalidValue_isInvalid() {
        XCTAssertEqual(OnboardingFlow.feedback(for: "My Tenant", isValid: false), .invalid)
    }

    func test_typedValidValue_isValid() {
        XCTAssertEqual(OnboardingFlow.feedback(for: "my-tenant", isValid: true), .valid)
    }

    func test_emptyProfileName_blocksWorkspaceStepWithoutAnError() {
        let flow = OnboardingFlow()
        flow.currentStep = .workspace
        flow.profileName = ""
        XCTAssertFalse(flow.canAdvance)
        XCTAssertEqual(
            OnboardingFlow.feedback(for: flow.profileName, isValid: flow.isProfileNameValid),
            .hint
        )
    }
}
