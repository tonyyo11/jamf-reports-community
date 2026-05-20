import XCTest
@testable import JamfReports

/// PR-22 T-2: lock the preset cadence numbers. These values are the
/// public contract — they appear in `docs/architecture/tiered-collection-adr.md`
/// and a future change here is a behavioral change the operator should
/// see in a CHANGELOG entry.
final class CadencePresetTests: XCTestCase {

    // MARK: - On-prem (conservative)

    func testOnPremRefresh() {
        XCTAssertEqual(
            CadencePreset.onPrem.defaultCadence(for: .refresh),
            86_400,
            "On-prem Refresh tier must default to daily (86400 s)"
        )
    }

    func testOnPremInventory() {
        XCTAssertEqual(
            CadencePreset.onPrem.defaultCadence(for: .inventory),
            604_800,
            "On-prem Inventory tier must default to weekly (604800 s)"
        )
    }

    func testOnPremScan() {
        XCTAssertEqual(
            CadencePreset.onPrem.defaultCadence(for: .scan),
            604_800,
            "On-prem Scan tier must default to weekly (604800 s)"
        )
    }

    func testOnPremPaceSeconds() {
        XCTAssertEqual(
            CadencePreset.onPrem.paceSeconds, 15,
            "On-prem must space jamf-cli calls 15 s apart"
        )
    }

    func testOnPremHardExclusions() {
        let excluded = CadencePreset.onPrem.hardExcludedKinds
        XCTAssertTrue(excluded.contains("update-status"))
        XCTAssertTrue(excluded.contains("update-device-failures"))
    }

    // MARK: - Cloud (default)

    func testCloudRefresh() {
        XCTAssertEqual(
            CadencePreset.cloud.defaultCadence(for: .refresh),
            43_200,
            "Cloud Refresh tier must default to twice daily (43200 s = 12 h)"
        )
    }

    func testCloudInventory() {
        XCTAssertEqual(
            CadencePreset.cloud.defaultCadence(for: .inventory),
            172_800,
            "Cloud Inventory tier must default to every 2 days (172800 s) — " +
            "resolved 2026-05-19, picked over 3 days for predictable scheduling"
        )
    }

    func testCloudScan() {
        XCTAssertEqual(
            CadencePreset.cloud.defaultCadence(for: .scan),
            604_800,
            "Cloud Scan tier must default to weekly (604800 s)"
        )
    }

    func testCloudPaceSeconds() {
        XCTAssertEqual(
            CadencePreset.cloud.paceSeconds, 0,
            "Cloud should not space jamf-cli calls — endpoints scale better than on-prem"
        )
    }

    func testCloudHardExclusions() {
        XCTAssertTrue(
            CadencePreset.cloud.hardExcludedKinds.isEmpty,
            "Cloud preset has no hard-excluded kinds (jamfcloud scales)"
        )
    }

    // MARK: - Custom

    func testCustomCadenceIsNilForAllTiers() {
        for tier in CollectionTier.allCases {
            XCTAssertNil(
                CadencePreset.custom.defaultCadence(for: tier),
                "Custom preset must return nil for \(tier) — requires explicit per_report config"
            )
        }
    }

    func testCustomPaceSecondsIsZero() {
        XCTAssertEqual(
            CadencePreset.custom.paceSeconds, 0,
            "Custom defaults to no pacing; users opt in via pace_seconds override"
        )
    }

    func testCustomHardExclusionsAreEmpty() {
        XCTAssertTrue(
            CadencePreset.custom.hardExcludedKinds.isEmpty,
            "Custom has no built-in exclusions; users express skips via per_report: never"
        )
    }

    // MARK: - Conformance

    func testCadencePresetIsCaseIterable() {
        XCTAssertEqual(Set(CadencePreset.allCases), [.onPrem, .cloud, .custom])
    }

    /// Raw values feed into the config.yaml `collect_cadence.preset` key.
    /// Pinned so a rename here is a deliberate, observable break.
    func testRawValueContract() {
        XCTAssertEqual(CadencePreset.onPrem.rawValue, "on-prem")
        XCTAssertEqual(CadencePreset.cloud.rawValue, "cloud")
        XCTAssertEqual(CadencePreset.custom.rawValue, "custom")
        XCTAssertEqual(CadencePreset(rawValue: "on-prem"), .onPrem)
        XCTAssertEqual(CadencePreset(rawValue: "unknown"), nil)
    }
}
