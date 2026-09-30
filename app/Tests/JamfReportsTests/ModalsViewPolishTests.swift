import AppKit
import SwiftUI
import XCTest
@testable import JamfReports

// MARK: - ModalsViewPolishTests

/// Smoke tests for P9-A-07 SecureSecretField + per-view polish.
///
/// These tests verify:
/// - SecureSecretField wraps an NSViewRepresentable (compile-time).
/// - The `onFinalize` closure receives the correct bytes and the field is
///   zeroed afterward (coordinator behavior).
/// - OnboardingFlow.setClientSecret(_:) writes the UTF-8 string.
/// - GenerateSheetState template picker round-trips correctly.
@MainActor
final class ModalsViewPolishTests: XCTestCase {

    // MARK: - SecureSecretField: NSViewRepresentable conformance

    /// Verifies at compile time that SecureSecretField wraps a native
    /// NSViewRepresentable field. If it doesn't, this test will not compile.
    func testSecureSecretFieldWrapsNSViewRepresentable() {
        func acceptRepresentable<T: NSViewRepresentable>(_: T.Type) {}
        acceptRepresentable(SecureSecretField.NativeField.self)
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

    // MARK: - GenerateSheet template picker round-trip

    func testGenerateSheetTemplatePickerDefaultIsFullInstance() {
        let state = GenerateSheetState()
        XCTAssertEqual(state.selectedTemplateID, FullInstanceTemplate().identifier)
    }

    func testGenerateSheetTemplatePickerRoundTrip() {
        let state = GenerateSheetState()
        let templates = TemplateResolver.allTemplates
        XCTAssertFalse(templates.isEmpty, "TemplateResolver must expose at least one template")
        // "custom" resolves to Executive without a persisted selection.
        state.customSelectedSheets = [.executiveSummary]
        defer { UserDefaults.standard.removeObject(forKey: GenerateSheetState.customSheetsKey) }

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
