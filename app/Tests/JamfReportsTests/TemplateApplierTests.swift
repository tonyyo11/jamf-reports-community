import XCTest
@testable import JamfReports

@MainActor
final class TemplateApplierTests: XCTestCase {

    func testApplyExecutiveTemplate() {
        let template = ExecutiveTemplate()
        let state = WizardState()

        // Setup some sheets
        state.orderedSheets = [
            SheetItem(name: "Cover", req: "cli", on: false),
            SheetItem(name: "Fleet Overview", req: "cli", on: false),
            SheetItem(name: "Security Posture", req: "cli", on: false),
            SheetItem(name: "Device Inventory", req: "csv", on: false)
        ]

        TemplateApplier.apply(template, to: state)

        // Check sheets are enabled according to template
        let enabledSheets = state.orderedSheets.filter(\.on).map(\.name)
        XCTAssertTrue(enabledSheets.contains("Cover"))
        XCTAssertTrue(enabledSheets.contains("Fleet Overview"))
        XCTAssertTrue(enabledSheets.contains("Security Posture"))
        XCTAssertFalse(enabledSheets.contains("Device Inventory")) // Not in executive template

        // Check output defaults
        XCTAssertEqual(state.keepLatestRuns, 20)
        XCTAssertTrue(state.timestampOutputs)
    }

    func testApplyOperationalTemplate() {
        let template = OperationalTemplate()
        let state = WizardState()

        state.orderedSheets = [
            SheetItem(name: "Fleet Overview", req: "cli", on: false),
            SheetItem(name: "Patch Compliance", req: "cli", on: false),
            SheetItem(name: "Cover", req: "cli", on: false)
        ]

        TemplateApplier.apply(template, to: state)

        let enabledSheets = state.orderedSheets.filter(\.on).map(\.name)
        XCTAssertTrue(enabledSheets.contains("Fleet Overview"))
        XCTAssertTrue(enabledSheets.contains("Patch Compliance"))
        XCTAssertFalse(enabledSheets.contains("Cover")) // Not in operational template

        XCTAssertEqual(state.keepLatestRuns, 7) // NOC needs fewer archives
    }

    func testRecommendedStaleDays() {
        let executive = ExecutiveTemplate()
        let operational = OperationalTemplate()
        let compliance = ComplianceTemplate()
        let security = SecurityPostureTemplate()

        XCTAssertEqual(TemplateApplier.recommendedStaleDays(for: executive), 30)
        XCTAssertEqual(TemplateApplier.recommendedStaleDays(for: operational), 14)
        XCTAssertEqual(TemplateApplier.recommendedStaleDays(for: compliance), 30)
        XCTAssertEqual(TemplateApplier.recommendedStaleDays(for: security), 7)
    }

    func testRecommendedThresholds() {
        let compliance = ComplianceTemplate()
        let operational = OperationalTemplate()
        let security = SecurityPostureTemplate()

        let complianceThresholds = TemplateApplier.recommendedThresholds(for: compliance)
        XCTAssertEqual(complianceThresholds.warning, 85)
        XCTAssertEqual(complianceThresholds.critical, 95)

        let operationalThresholds = TemplateApplier.recommendedThresholds(for: operational)
        XCTAssertEqual(operationalThresholds.warning, 80)
        XCTAssertEqual(operationalThresholds.critical, 90)

        let securityThresholds = TemplateApplier.recommendedThresholds(for: security)
        XCTAssertEqual(securityThresholds.warning, 70)
        XCTAssertEqual(securityThresholds.critical, 85)
    }

    func testEAKeywords() {
        let compliance = ComplianceTemplate()
        let security = SecurityPostureTemplate()
        let asset = AssetTemplate()

        let complianceKeywords = TemplateApplier.eaKeywords(for: compliance)
        XCTAssertTrue(complianceKeywords.contains("audit"))
        XCTAssertTrue(complianceKeywords.contains("stig"))

        let securityKeywords = TemplateApplier.eaKeywords(for: security)
        XCTAssertTrue(securityKeywords.contains("filevault"))
        XCTAssertTrue(securityKeywords.contains("gatekeeper"))

        let assetKeywords = TemplateApplier.eaKeywords(for: asset)
        XCTAssertTrue(assetKeywords.contains("warranty"))
        XCTAssertTrue(assetKeywords.contains("asset"))
    }
}