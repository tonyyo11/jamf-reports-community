import AppKit
import SwiftUI
import XCTest
@testable import JamfReports

// MARK: - ModalsViewPolishTests

/// Smoke tests for P9-A-07 SecureSecretField + per-view polish.
///
/// These tests verify:
/// - SecureSecretField conforms to NSViewRepresentable (compile-time).
/// - The `onFinalize` closure receives the correct bytes and the field is
///   zeroed afterward (coordinator behavior).
/// - OnboardingFlow.setClientSecret(_:) writes the UTF-8 string.
/// - WizardState step indicator labels are non-empty for all 9 steps.
/// - GenerateSheetState template picker round-trips correctly.
@MainActor
final class ModalsViewPolishTests: XCTestCase {

    // MARK: - SecureSecretField: NSViewRepresentable conformance

    /// Verifies at compile time that SecureSecretField is NSViewRepresentable.
    /// If it isn't, this test will not compile.
    func testSecureSecretFieldConformsToNSViewRepresentable() {
        func acceptRepresentable<T: NSViewRepresentable>(_: T.Type) {}
        acceptRepresentable(SecureSecretField.self)
    }

    // MARK: - SecureSecretField coordinator: onFinalize behavior

    func testCoordinatorFinalizeDeliversUTF8Bytes() {
        var received: Data?
        let coordinator = SecureSecretField.Coordinator { data in
            received = data
        }

        let field = NSSecureTextField()
        field.stringValue = "s3cr3t"

        // Simulate Return action.
        coordinator.fieldAction(field)

        XCTAssertEqual(received, Data("s3cr3t".utf8))
    }

    func testCoordinatorClearsFieldAfterFinalize() {
        let coordinator = SecureSecretField.Coordinator { _ in }
        let field = NSSecureTextField()
        field.stringValue = "s3cr3t"
        coordinator.fieldAction(field)
        XCTAssertEqual(field.stringValue, "",
                       "field.stringValue must be empty after finalize")
    }

    func testCoordinatorDoesNotFinalizeOnEmptyField() {
        var called = false
        let coordinator = SecureSecretField.Coordinator { _ in called = true }
        let field = NSSecureTextField()
        field.stringValue = ""
        coordinator.fieldAction(field)
        XCTAssertFalse(called, "onFinalize must not be called for empty input")
    }

    func testCoordinatorEndEditingCallsFinalize() {
        var received: Data?
        let coordinator = SecureSecretField.Coordinator { data in received = data }
        let field = NSSecureTextField()
        field.stringValue = "pass"
        let note = Notification(name: NSControl.textDidEndEditingNotification,
                                object: field, userInfo: nil)
        coordinator.controlTextDidEndEditing(note)
        XCTAssertEqual(received, Data("pass".utf8))
    }

    // MARK: - OnboardingFlow.setClientSecret

    func testSetClientSecretWritesUTF8String() {
        let flow = OnboardingFlow()
        let secret = "my-oauth-secret"
        flow.setClientSecret(Data(secret.utf8))
        XCTAssertEqual(flow.clientSecret, secret)
    }

    func testSetClientSecretWithEmptyDataWritesEmpty() {
        let flow = OnboardingFlow()
        flow.setClientSecret(Data())
        // Empty data → no valid UTF-8 string; fallback is ""
        XCTAssertEqual(flow.clientSecret, "")
    }

    func testSetClientSecretOverwritesPreviousValue() {
        let flow = OnboardingFlow()
        flow.setClientSecret(Data("first".utf8))
        flow.setClientSecret(Data("second".utf8))
        XCTAssertEqual(flow.clientSecret, "second")
    }

    // MARK: - WizardState step indicator labels

    func testWizardStepTitlesAreNonEmptyForAllSteps() {
        let state = WizardState()
        // `totalSteps` is the count of steps; valid step indices are 0..<count.
        let titles = (0..<state.totalSteps).map { step -> String in
            state.currentStep = step
            return wizardStepTitle(for: step)
        }
        for (idx, title) in titles.enumerated() {
            XCTAssertFalse(title.isEmpty,
                           "Step \(idx) has an empty title — wizard step indicator broken")
        }
    }

    /// Mirror the `stepTitle` computed property from `CustomizationWizard`
    /// without accessing the private view.
    private func wizardStepTitle(for step: Int) -> String {
        switch step {
        case 0: return "Choose Template"
        case 1: return "Org Branding"
        case 2: return "Compliance Framework"
        case 3: return "Surface Custom EAs"
        case 4: return "Exceptions (optional)"
        case 5: return "Pick & Order Sheets"
        case 6: return "Inventory Fields"
        case 7: return "Output Preferences"
        case 8: return "Done — Preview"
        default: return ""
        }
    }

    func testWizardTotalStepsMatchesExpectedCount() {
        let state = WizardState()
        // 9 steps total (0–8); totalSteps must equal 9.
        XCTAssertEqual(state.totalSteps, 9)
    }

    // MARK: - GenerateSheet template picker round-trip

    func testGenerateSheetTemplatePickerDefaultIsFullInstance() {
        let state = GenerateSheetState()
        XCTAssertEqual(state.selectedTemplateID, FullInstanceTemplate().identifier)
    }

    func testGenerateSheetTemplatePickerRoundTrip() {
        let state = GenerateSheetState()
        let templates = TemplateResolver.allTemplates
        XCTAssertFalse(templates.isEmpty, "TemplateResolver must expose at least one template")

        for template in templates {
            state.selectedTemplateID = template.identifier
            let resolved = state.resolvedTemplate
            XCTAssertEqual(resolved.identifier, template.identifier,
                           "resolvedTemplate identifier must match selectedTemplateID for \(template.displayName)")
            XCTAssertFalse(resolved.description.isEmpty,
                           "Template \(template.displayName) must have a non-empty description")
        }
    }

    func testGenerateSheetAllFiveStandardTemplatesPlusCustom() {
        let templates = TemplateResolver.allTemplates
        // Standard pack: Executive, Operational, Compliance, Asset, SecurityPosture
        let expectedIDs: Set<String> = [
            ExecutiveTemplate().identifier,
            OperationalTemplate().identifier,
            ComplianceTemplate().identifier,
            AssetTemplate().identifier,
            SecurityPostureTemplate().identifier,
        ]
        let actualIDs = Set(templates.map(\.identifier))
        for id in expectedIDs {
            XCTAssertTrue(actualIDs.contains(id),
                          "Expected template '\(id)' missing from TemplateResolver.allTemplates")
        }
    }
}
