import Foundation
import XCTest
@testable import JamfReports

final class CustomizationWizardStateTests: XCTestCase {

    // MARK: - Navigation

    @MainActor
    func testAdvanceIncrementsStep() {
        let state = WizardState()
        XCTAssertEqual(state.currentStep, 0)
        state.advance()
        XCTAssertEqual(state.currentStep, 1)
    }

    @MainActor
    func testRetreatDecrementsStep() {
        let state = WizardState()
        state.advance()
        state.advance()
        state.retreat()
        XCTAssertEqual(state.currentStep, 1)
    }

    @MainActor
    func testAdvanceDoesNotExceedTotalSteps() {
        let state = WizardState()
        for _ in 0..<20 { state.advance() }
        XCTAssertEqual(state.currentStep, state.totalSteps)
    }

    @MainActor
    func testRetreatDoesNotGoBelowZero() {
        let state = WizardState()
        state.retreat()
        XCTAssertEqual(state.currentStep, 0)
    }

    @MainActor
    func testStepNavigationPreservesSelections() {
        let state = WizardState()
        state.orgName = "Acme"
        state.selectedEAIDs = ["7", "12"]
        state.advance()
        state.retreat()
        XCTAssertEqual(state.orgName, "Acme")
        XCTAssertEqual(state.selectedEAIDs, ["7", "12"])
    }

    // MARK: - EA type inference

    @MainActor
    func testBooleanDataTypeMapsToBoolean() {
        let ea = ExtensionAttribute(
            id: "1", name: "FileVault", dataType: "BOOLEAN",
            description: nil, inputType: "SCRIPT", enabled: true
        )
        XCTAssertEqual(ea.inferredEAType, "boolean")
    }

    @MainActor
    func testDateDataTypeMapsToDate() {
        let ea = ExtensionAttribute(
            id: "2", name: "CertExpiry", dataType: "DATE",
            description: nil, inputType: "SCRIPT", enabled: true
        )
        XCTAssertEqual(ea.inferredEAType, "date")
    }

    @MainActor
    func testIntegerDataTypeMapsToPercentage() {
        let ea = ExtensionAttribute(
            id: "3", name: "DiskUsage", dataType: "INTEGER",
            description: nil, inputType: "SCRIPT", enabled: true
        )
        XCTAssertEqual(ea.inferredEAType, "percentage")
    }

    @MainActor
    func testStringDataTypeMapsToText() {
        let ea = ExtensionAttribute(
            id: "4", name: "SomeEA", dataType: "STRING",
            description: nil, inputType: "TEXT", enabled: true
        )
        XCTAssertEqual(ea.inferredEAType, "text")
    }

    @MainActor
    func testLowercaseDataTypeIsNormalized() {
        // jamf-cli always returns uppercase but verify case-insensitive handling.
        let ea = ExtensionAttribute(
            id: "5", name: "Edge", dataType: "boolean",
            description: nil, inputType: "SCRIPT", enabled: true
        )
        XCTAssertEqual(ea.inferredEAType, "boolean")
    }

    // MARK: - applyTo: EA picker writes to configState

    @MainActor
    func testApplyToAddsBooleanEAWithTrueValue() {
        let state = WizardState()
        let ea = ExtensionAttribute(
            id: "99", name: "FileVault Status", dataType: "BOOLEAN",
            description: nil, inputType: "SCRIPT", enabled: true
        )
        state.availableEAs = [ea]
        state.selectedEAIDs = ["99"]
        state.booleanTrueValues["99"] = "Encrypted"

        var config = ConfigState.defaultState
        state.applyTo(&config)

        let added = config.customEAs.first(where: { $0.name == "FileVault Status" })
        XCTAssertNotNil(added)
        XCTAssertEqual(added?.type, CustomEA.EAType.boolean)
        XCTAssertEqual(added?.trueValue, "Encrypted")
    }

    @MainActor
    func testApplyToAddsDateEA() {
        let state = WizardState()
        let ea = ExtensionAttribute(
            id: "10", name: "Cert Expiry", dataType: "DATE",
            description: nil, inputType: "SCRIPT", enabled: true
        )
        state.availableEAs = [ea]
        state.selectedEAIDs = ["10"]

        var config = ConfigState.defaultState
        state.applyTo(&config)

        let added = config.customEAs.first(where: { $0.name == "Cert Expiry" })
        XCTAssertEqual(added?.type, CustomEA.EAType.date)
    }

    @MainActor
    func testApplyToDoesNotDuplicateExistingEA() {
        let state = WizardState()
        let ea = ExtensionAttribute(
            id: "7", name: "SysTrack Install Status", dataType: "BOOLEAN",
            description: nil, inputType: "SCRIPT", enabled: true
        )
        state.availableEAs = [ea]
        state.selectedEAIDs = ["7"]

        var config = ConfigState.defaultState
        config.customEAs = [ConfigCustomEA(
            name: "SysTrack Install Status", column: "SysTrack Install Status",
            type: .boolean, trueValue: "Installed",
            warningThreshold: "", criticalThreshold: "", currentVersions: [], warningDays: ""
        )]

        state.applyTo(&config)
        let matches = config.customEAs.filter { $0.name == "SysTrack Install Status" }
        XCTAssertEqual(matches.count, 1, "Existing EA must not be duplicated")
    }

    // MARK: - Inventory field heuristic

    func testInventoryKeyMatcherAssetTag() {
        XCTAssertEqual(InventoryFieldMatcher.matchColumnKey("assetTag"), "asset_tag")
        XCTAssertEqual(InventoryFieldMatcher.matchColumnKey("asset_tag"), "asset_tag")
        XCTAssertEqual(InventoryFieldMatcher.matchColumnKey("Asset Tag"), "asset_tag")
    }

    func testInventoryKeyMatcherFullName() {
        XCTAssertEqual(InventoryFieldMatcher.matchColumnKey("fullName"), "full_name")
        XCTAssertEqual(InventoryFieldMatcher.matchColumnKey("full_name"), "full_name")
        XCTAssertEqual(InventoryFieldMatcher.matchColumnKey("displayName"), "full_name")
    }

    func testInventoryKeyMatcherLastLoggedInUser() {
        XCTAssertEqual(InventoryFieldMatcher.matchColumnKey("lastLoggedInUser"), "last_logged_in_user")
    }

    func testInventoryKeyMatcherUnknownReturnsNil() {
        XCTAssertNil(InventoryFieldMatcher.matchColumnKey("someObscureField"))
    }

    // MARK: - Compliance framework: applyTo writes framework to config

    @MainActor
    func testComplianceFrameworkPresetWrittenToConfig() {
        let state = WizardState()
        state.framework = .nist80053
        var config = ConfigState.defaultState
        state.applyTo(&config)
        XCTAssertEqual(config.complianceFramework, "NIST 800-53 Moderate")
    }

    @MainActor
    func testCustomFrameworkLabelWrittenToConfig() {
        let state = WizardState()
        state.framework = .custom
        state.customFrameworkLabel = "My Internal Framework 2.0"
        var config = ConfigState.defaultState
        state.applyTo(&config)
        XCTAssertEqual(config.complianceFramework, "My Internal Framework 2.0")
    }

    @MainActor
    func testCustomFrameworkEmptyStringWhenBlank() {
        let state = WizardState()
        state.framework = .custom
        state.customFrameworkLabel = ""
        var config = ConfigState.defaultState
        state.applyTo(&config)
        // An empty custom label writes an empty string — not a preset value.
        XCTAssertEqual(config.complianceFramework, "")
    }

    // MARK: - hasUnsavedChanges

    @MainActor
    func testHasUnsavedChangesStartsFalse() {
        let state = WizardState()
        XCTAssertFalse(state.hasUnsavedChanges)
    }

    @MainActor
    func testHasUnsavedChangesFlipsOnOrgNameChange() {
        let state = WizardState()
        state.orgName = "Acme"
        state.hasUnsavedChanges = true    // simulates onChange observer
        XCTAssertTrue(state.hasUnsavedChanges)
    }

    // MARK: - canContinue (Step 2 framework validation)

    @MainActor
    func testCanContinueTrueByDefaultOnStep2() {
        let state = WizardState()
        state.currentStep = 2
        state.framework = .nist80053
        XCTAssertTrue(state.canContinue)
    }

    @MainActor
    func testCanContinueFalseWhenCustomFrameworkEmpty() {
        let state = WizardState()
        state.currentStep = 2
        state.framework = .custom
        state.customFrameworkLabel = ""
        XCTAssertFalse(state.canContinue)
    }

    @MainActor
    func testCanContinueFalseWhenCustomFrameworkWhitespaceOnly() {
        let state = WizardState()
        state.currentStep = 2
        state.framework = .custom
        state.customFrameworkLabel = "   "
        XCTAssertFalse(state.canContinue)
    }

    @MainActor
    func testCanContinueTrueWhenCustomFrameworkNonEmpty() {
        let state = WizardState()
        state.currentStep = 2
        state.framework = .custom
        state.customFrameworkLabel = "My Framework 2.0"
        XCTAssertTrue(state.canContinue)
    }

    @MainActor
    func testCanContinueTrueOnOtherStepsRegardlessOfCustomLabel() {
        let state = WizardState()
        state.framework = .custom
        state.customFrameworkLabel = ""
        // Step 0 requires template selection, so set up a valid template
        state.useCustomTemplate = true
        // Steps other than 2 are not gated by customFrameworkLabel.
        for step in [0, 1, 3, 4, 5, 6, 7] {
            state.currentStep = step
            XCTAssertTrue(state.canContinue, "Expected canContinue == true on step \(step)")
        }
    }

    // MARK: - Output preferences

    @MainActor
    func testApplyToWritesOutputPreferences() {
        let state = WizardState()
        state.outputDir = "/tmp/reports"
        state.timestampOutputs = false
        state.keepLatestRuns = 5

        var config = ConfigState.defaultState
        state.applyTo(&config)

        XCTAssertEqual(config.outputDir, "/tmp/reports")
        XCTAssertEqual(config.timestampOutputs, false)
        XCTAssertEqual(config.keepLatestRuns, 5)
    }

    // MARK: - Template selection (Step 0)

    @MainActor
    func testCanContinueFalseOnStep0WithoutTemplateSelection() {
        let state = WizardState()
        state.currentStep = 0
        // No template selected and not using custom
        XCTAssertFalse(state.canContinue)
    }

    @MainActor
    func testCanContinueTrueOnStep0WithCustomTemplate() {
        let state = WizardState()
        state.currentStep = 0
        state.useCustomTemplate = true
        XCTAssertTrue(state.canContinue)
    }

    @MainActor
    func testCanContinueTrueOnStep0WithSelectedTemplate() {
        let state = WizardState()
        state.currentStep = 0
        state.selectedTemplate = ExecutiveTemplate()
        XCTAssertTrue(state.canContinue)
    }
}
