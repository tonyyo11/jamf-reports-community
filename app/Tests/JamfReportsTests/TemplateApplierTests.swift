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

    // Per-template apply() assertions for the remaining 4 templates close the
    // case-deletion gap (PR-8 council CONSIDER). Each test asserts the
    // unique `keepLatestRuns` value so removing a `case "x":` arm in
    // `applyOutputDefaults` surfaces as a value mismatch rather than a silent
    // fall-through to the default (10).

    func testApplyComplianceTemplate() {
        let template = ComplianceTemplate()
        let state = WizardState()
        TemplateApplier.apply(template, to: state)
        XCTAssertEqual(state.keepLatestRuns, 50,
                       "compliance: long audit trail → 50 (removing this case would default to 10)")
        XCTAssertTrue(state.timestampOutputs)
    }

    func testApplyAssetTemplate() {
        let template = AssetTemplate()
        let state = WizardState()
        TemplateApplier.apply(template, to: state)
        XCTAssertEqual(state.keepLatestRuns, 15,
                       "asset: lifecycle tracking → 15 (removing this case would default to 10)")
        XCTAssertTrue(state.timestampOutputs)
    }

    func testApplySecurityPostureTemplate() {
        let template = SecurityPostureTemplate()
        let state = WizardState()
        TemplateApplier.apply(template, to: state)
        XCTAssertEqual(state.keepLatestRuns, 30,
                       "security-posture: security review cycles → 30 (removing this case would default to 10)")
        XCTAssertTrue(state.timestampOutputs)
    }

    func testApplySchoolTemplate() {
        // School currently falls through the default arm. This test pins the
        // observed value to 10; if a school-specific case is added later,
        // update this assertion to the new value.
        let template = SchoolTemplate()
        let state = WizardState()
        TemplateApplier.apply(template, to: state)
        XCTAssertEqual(state.keepLatestRuns, 10,
                       "school: documented default-arm value (10); change if a school case is added")
        XCTAssertTrue(state.timestampOutputs)
    }

    func testRecommendedStaleDays() {
        // Exhaustive across all 6 shipping templates. `operational` (14),
        // `asset` (60), and `security-posture` (7) return values distinct
        // from the default 30 — deleting any of those cases surfaces here
        // as a value change. LIMIT: `compliance` and `executive` both
        // return 30 which equals the default, so deleting either case is
        // undetectable via behavioral testing alone (the value is the
        // same whether the named arm or `default:` is taken).
        //
        // Epic #102 item #9: this limit is ACCEPTED, not closed. A tagged
        // return exposing which switch arm matched would test implementation,
        // not behavior — and `recommendedStaleDays` is a shipping API called
        // by `CLISuggester`, so the tag would leak a test-only concern into
        // production. When two arms return the same value they are
        // behaviorally identical; a deletion that changes nothing observable
        // is not a regression a behavioral test should catch.
        XCTAssertEqual(TemplateApplier.recommendedStaleDays(for: ExecutiveTemplate()), 30,
                       "executive: monthly view → 30 (matches default — case-deletion undetectable)")
        XCTAssertEqual(TemplateApplier.recommendedStaleDays(for: OperationalTemplate()), 14,
                       "operational: daily ops → 14 (distinct from default — case-deletion would fail)")
        XCTAssertEqual(TemplateApplier.recommendedStaleDays(for: ComplianceTemplate()), 30,
                       "compliance: audit tolerance → 30 (matches default — case-deletion undetectable)")
        XCTAssertEqual(TemplateApplier.recommendedStaleDays(for: AssetTemplate()), 60,
                       "asset: lifecycle view → 60 (distinct from default — case-deletion would fail)")
        XCTAssertEqual(TemplateApplier.recommendedStaleDays(for: SecurityPostureTemplate()), 7,
                       "security-posture: fresh data → 7 (distinct from default — case-deletion would fail)")
        XCTAssertEqual(TemplateApplier.recommendedStaleDays(for: SchoolTemplate()), 30,
                       "school: documented default arm (30); change here if a school-specific arm is added")
    }

    func testRecommendedThresholds() {
        // Exhaustive across all 6 shipping templates. Only `compliance` (85,95)
        // and `security-posture` (70,85) return values distinct from the
        // default (80,90). LIMIT: `operational`, `executive`, `asset`, and
        // `school` all return (80,90) which equals the default — case-deletion
        // for those four is undetectable via behavioral testing alone (the
        // value is the same whether the named arm or `default:` is taken).
        // `operational` explicitly ships a `case` arm that returns the same
        // value as default; the tripwire here cannot discriminate.
        //
        // Epic #102 item #9: accepted limit — rationale in testRecommendedStaleDays.
        let compliance = TemplateApplier.recommendedThresholds(for: ComplianceTemplate())
        XCTAssertEqual(compliance.warning, 85, "compliance: audit-tight warning")
        XCTAssertEqual(compliance.critical, 95, "compliance: audit-tight critical")

        let operational = TemplateApplier.recommendedThresholds(for: OperationalTemplate())
        XCTAssertEqual(operational.warning, 80, "operational: actionable warning")
        XCTAssertEqual(operational.critical, 90, "operational: actionable critical")

        let security = TemplateApplier.recommendedThresholds(for: SecurityPostureTemplate())
        XCTAssertEqual(security.warning, 70, "security: early-warning")
        XCTAssertEqual(security.critical, 85, "security: early-critical")

        let executive = TemplateApplier.recommendedThresholds(for: ExecutiveTemplate())
        XCTAssertEqual(executive.warning, 80, "executive: default arm warning")
        XCTAssertEqual(executive.critical, 90, "executive: default arm critical")

        let asset = TemplateApplier.recommendedThresholds(for: AssetTemplate())
        XCTAssertEqual(asset.warning, 80, "asset: default arm warning")
        XCTAssertEqual(asset.critical, 90, "asset: default arm critical")

        let school = TemplateApplier.recommendedThresholds(for: SchoolTemplate())
        XCTAssertEqual(school.warning, 80, "school: default arm warning")
        XCTAssertEqual(school.critical, 90, "school: default arm critical")
    }

    func testEAKeywords() {
        // Exhaustive across all 6 shipping templates. The default arm returns
        // `[]`; executive and school both fall through, so assert empty.
        let compliance = TemplateApplier.eaKeywords(for: ComplianceTemplate())
        XCTAssertTrue(compliance.contains("audit"))
        XCTAssertTrue(compliance.contains("stig"))
        XCTAssertTrue(compliance.contains("nist"))

        let security = TemplateApplier.eaKeywords(for: SecurityPostureTemplate())
        XCTAssertTrue(security.contains("filevault"))
        XCTAssertTrue(security.contains("gatekeeper"))
        XCTAssertTrue(security.contains("firewall"))

        let asset = TemplateApplier.eaKeywords(for: AssetTemplate())
        XCTAssertTrue(asset.contains("warranty"))
        XCTAssertTrue(asset.contains("asset"))
        XCTAssertTrue(asset.contains("serial"))

        let operational = TemplateApplier.eaKeywords(for: OperationalTemplate())
        XCTAssertTrue(operational.contains("status"),
                      "operational must have a `case` arm; expected 'status' keyword")
        XCTAssertTrue(operational.contains("health"))
        XCTAssertTrue(operational.contains("agent"))

        XCTAssertEqual(TemplateApplier.eaKeywords(for: ExecutiveTemplate()), [],
                       "executive: default arm → empty list")
        XCTAssertEqual(TemplateApplier.eaKeywords(for: SchoolTemplate()), [],
                       "school: default arm → empty list (change here if a school case is added)")
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
    // Coverage of the case-deletion gap (PR-8 council CONSIDER, closed in PR-5):
    // the `testApply<Name>Template`, `testRecommendedStaleDays`,
    // `testRecommendedThresholds`, and `testEAKeywords` tests above each pin
    // the per-template values that would change if a `case "x":` arm were
    // deleted — silent fall-through to `default:` would now flip an assertion
    // rather than pass.

    func testEveryShippingTemplateIsExplicitlyCovered() {
        let shipping = Set(TemplateResolver.allTemplates.map(\.identifier))
        let explicitlyCovered: Set<String> = [
            "executive",
            "compliance",
            "operational",
            "asset",
            "security-posture",
            "school",
            // full-instance intentionally uses TemplateApplier's default
            // branches (balanced thresholds, no EA keyword filtering) — it
            // includes every sheet/section, so no template-specific tuning.
            "full-instance",
            // custom is a user-chosen sheet subset; it intentionally uses
            // TemplateApplier's default branches — no template-specific tuning.
            "custom",
        ]
        XCTAssertEqual(
            shipping, explicitlyCovered,
            "When TemplateResolver.allTemplates changes, update this set AND " +
            "verify TemplateApplier's four switches have the right cases " +
            "(or document the default-by-design behavior for the new template)."
        )
    }
}
