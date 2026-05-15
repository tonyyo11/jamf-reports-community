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

    // MARK: - Exhaustiveness
    //
    // The four switches in `TemplateApplier` (output defaults, stale-days,
    // thresholds, EA keywords) each carry a `default:` arm. That's load-bearing
    // safety (a future template added in a test target or plugin should not
    // hard-crash), but it also means a typo in a `case` label would silently
    // fall through with no compile-time warning.
    //
    // This test is the addition tripwire: every shipping template identifier
    // from `TemplateResolver.allTemplates` must appear in the
    // `explicitlyCovered` set below. Adding a new template forces the author
    // to (a) add it here and (b) revisit each of the four switches in
    // `TemplateApplier.swift` to decide whether the default-by-design behavior
    // is correct or whether an explicit case is needed.
    //
    // Coverage gap (intentional): does NOT catch deletion of an existing
    // `case "x":` arm while `"x"` still ships — that scenario silently
    // falls through to `default:` by design. Per-template behavioral
    // assertions would be needed to close that gap; logged to BACKLOG.

    func testEveryShippingTemplateIsExplicitlyCovered() {
        let shipping = Set(TemplateResolver.allTemplates.map(\.identifier))
        let explicitlyCovered: Set<String> = [
            "executive",
            "compliance",
            "operational",
            "asset",
            "security-posture",
            "school",
        ]
        XCTAssertEqual(
            shipping, explicitlyCovered,
            "When TemplateResolver.allTemplates changes, update this set AND " +
            "verify TemplateApplier's four switches have the right cases " +
            "(or document the default-by-design behavior for the new template)."
        )
    }
}
