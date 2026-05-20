import XCTest
@testable import JamfReports

/// PR-23 T-21: the display helpers behind the Settings → Performance
/// preset picker. The picker UI itself needs visual verification; these
/// pin the pure formatting it renders.
final class CadencePresetDisplayTests: XCTestCase {

    // MARK: - displayName

    func testDisplayNames() {
        XCTAssertEqual(CadencePreset.onPrem.displayName, "On-prem")
        XCTAssertEqual(CadencePreset.cloud.displayName, "Cloud")
        XCTAssertEqual(CadencePreset.custom.displayName, "Custom")
    }

    // MARK: - humanCadence

    func testHumanCadenceKnownPresetValues() {
        XCTAssertEqual(CadencePreset.humanCadence(seconds: 43_200), "Twice daily")
        XCTAssertEqual(CadencePreset.humanCadence(seconds: 86_400), "Daily")
        XCTAssertEqual(CadencePreset.humanCadence(seconds: 172_800), "Every 2 days")
        XCTAssertEqual(CadencePreset.humanCadence(seconds: 604_800), "Weekly")
    }

    func testHumanCadenceGenericFallbacks() {
        XCTAssertEqual(CadencePreset.humanCadence(seconds: 259_200), "Every 3 days")
        XCTAssertEqual(CadencePreset.humanCadence(seconds: 7_200), "Every 2 h")
        XCTAssertEqual(CadencePreset.humanCadence(seconds: 90), "90 s")
        XCTAssertEqual(CadencePreset.humanCadence(seconds: 0), "0 s")
    }

    // MARK: - cadenceSummary

    func testOnPremSummaryListsAllThreeTiers() {
        let summary = CadencePreset.onPrem.cadenceSummary
        XCTAssertEqual(summary, "Refresh: Daily · Inventory: Weekly · Scan: Weekly")
    }

    func testCloudSummaryListsAllThreeTiers() {
        let summary = CadencePreset.cloud.cadenceSummary
        XCTAssertEqual(
            summary,
            "Refresh: Twice daily · Inventory: Every 2 days · Scan: Weekly"
        )
    }

    func testCustomSummaryPointsToPerReportEditor() {
        XCTAssertEqual(
            CadencePreset.custom.cadenceSummary,
            "Per-report — configure each report individually."
        )
    }

    // MARK: - displaySubtitle

    func testEveryPresetHasANonEmptySubtitle() {
        for preset in CadencePreset.allCases {
            XCTAssertFalse(preset.displaySubtitle.isEmpty,
                           "\(preset.rawValue) must have a radio-option subtitle")
        }
    }

    /// The summary must stay in sync with the preset cadence table — if a
    /// future change to defaultCadence(for:) drifts, this catches it.
    func testSummaryReflectsDefaultCadenceTable() {
        for preset in [CadencePreset.onPrem, .cloud] {
            for tier in CollectionTier.allCases {
                let seconds = preset.defaultCadence(for: tier) ?? 0
                let phrase = CadencePreset.humanCadence(seconds: seconds)
                XCTAssertTrue(
                    preset.cadenceSummary.contains(phrase),
                    "\(preset.rawValue) summary must contain \(tier.displayName)'s '\(phrase)'"
                )
            }
        }
    }
}
