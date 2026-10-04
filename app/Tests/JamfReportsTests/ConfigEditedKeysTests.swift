import XCTest
@testable import JamfReports

/// The keys the screens edit are read off the code that writes them, so a key added to an
/// editor stops being listed as file-only without a second list to update.
final class ConfigEditedKeysTests: XCTestCase {

    func testEveryEditorsKeysAreIncluded() {
        let paths = ConfigEditedKeys.paths
        let expected: [[String]] = [
            ["columns", "computer_name"], ["columns", "full_name"],
            ["mobile_columns", "device_family"],
            ["security_agents", "connected_value"],
            ["custom_eas", "type"], ["custom_eas", "true_value"],
            ["custom_eas", "warning_threshold"], ["custom_eas", "critical_threshold"],
            ["custom_eas", "current_versions"], ["custom_eas", "warning_days"],
            ["thresholds", "stale_device_days"], ["compliance", "baseline_label"],
            ["platform", "compliance_benchmarks"], ["output", "keep_latest_runs"],
            ["jamf_cli", "require_manifest"], ["branding", "accent_dark"],
            ["charts", "save_png"], ["charts", "os_adoption", "per_major_charts"],
            ["notify", "enabled"], ["notify", "url"], ["notify", "detail"],
            ["ai", "enabled"], ["ai", "tier"], ["ai", "reasoning_level"],
            ["security_policy", "controls", "sip"], ["security_policy", "controls", "filevault"],
            ["security_policy", "filevault_off_hardware_encrypted"],
            ["security_policy", "score_weights", "edr_agent"],
        ]
        for path in expected {
            XCTAssertTrue(paths.contains(path), path.joined(separator: "."))
        }
    }

    func testKeysNoEditorWritesAreLeftOut() {
        let paths = ConfigEditedKeys.paths
        let typedOnly: [[String]] = [
            ["jamf_cli", "data_dir"], ["jamf_cli", "profile"], ["output", "allow_absolute_paths"],
            ["compliance", "baselines"], ["charts", "historical_csv_dir"],
            ["charts", "embed_in_xlsx"], ["retention", "enabled"], ["sheets", "only"],
        ]
        for path in typedOnly {
            XCTAssertFalse(paths.contains(path), path.joined(separator: "."))
        }
    }

    /// A key a writer sets that the schema does not know would show under "Not read by the
    /// app" on the next save, so the two lists must agree.
    func testEveryEditedKeyIsOneTheAppReads() {
        for path in ConfigEditedKeys.paths {
            let known = ConfigSchema.knownKeys(at: Array(path.dropLast()))
            XCTAssertEqual(known?.contains(path.last ?? ""), true, path.joined(separator: "."))
        }
    }
}
