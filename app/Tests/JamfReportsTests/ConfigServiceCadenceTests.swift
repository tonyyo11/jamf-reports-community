import Foundation
import XCTest
@testable import JamfReports

/// PR-23 T-22: `ConfigService.setCadencePreset` writes `collect_cadence.preset`
/// and finalizes the legacy `collect_skip` migration.
final class ConfigServiceCadenceTests: XCTestCase {

    // MARK: - Block creation

    func testSetPresetCreatesCollectCadenceBlock() throws {
        let root = try tempRoot()
        let profile = "cad-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
            jamf_cli:
              profile: tenant-a
            """,
            profile: profile, root: root
        )

        try ConfigService.setCadencePreset(profile: profile, preset: .cloud, workspaceRoot: root)

        let cfg = try loadEngineConfig(profile: profile, root: root)
        XCTAssertEqual(cfg.collectCadence?.preset, .cloud)
    }

    func testSetPresetOnFreshConfigFileCreatesIt() throws {
        // No config.yaml on disk yet — setCadencePreset must create one.
        let root = try tempRoot()
        let profile = "cad-fresh-\(UUID().uuidString.lowercased())"

        try ConfigService.setCadencePreset(profile: profile, preset: .onPrem, workspaceRoot: root)

        let url = try ConfigService.configURL(for: profile, workspaceRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let cfg = try loadEngineConfig(profile: profile, root: root)
        XCTAssertEqual(cfg.collectCadence?.preset, .onPrem)
    }

    // MARK: - Sibling-key preservation

    func testSetPresetPreservesPaceSecondsAndPerReport() throws {
        let root = try tempRoot()
        let profile = "cad-sib-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
            collect_cadence:
              preset: on-prem
              pace_seconds: 30
              per_report:
                update-status: never
            """,
            profile: profile, root: root
        )

        try ConfigService.setCadencePreset(profile: profile, preset: .cloud, workspaceRoot: root)

        let cfg = try loadEngineConfig(profile: profile, root: root)
        XCTAssertEqual(cfg.collectCadence?.preset, .cloud, "preset updated")
        XCTAssertEqual(cfg.collectCadence?.paceSeconds, 30, "pace_seconds preserved")
        XCTAssertEqual(
            cfg.collectCadence?.perReport?["update-status"]?.cadence, .never,
            "per_report preserved"
        )
    }

    // MARK: - Legacy collect_skip finalization

    func testSetPresetRemovesLegacyCollectSkip() throws {
        let root = try tempRoot()
        let profile = "cad-skip-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
            jamf_cli:
              profile: tenant-a
              collect_skip:
                - update-status
            """,
            profile: profile, root: root
        )

        try ConfigService.setCadencePreset(profile: profile, preset: .onPrem, workspaceRoot: root)

        let url = try ConfigService.configURL(for: profile, workspaceRoot: root)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("collect_skip"),
                       "Legacy jamf_cli.collect_skip must be removed on the cadence write")
        // jamf_cli's other keys survive.
        XCTAssertTrue(raw.contains("tenant-a"), "Other jamf_cli keys must remain")
    }

    func testSetPresetLeavesJamfCliIntactWhenNoCollectSkip() throws {
        let root = try tempRoot()
        let profile = "cad-nojc-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
            jamf_cli:
              profile: tenant-b
              data_dir: my-data
            """,
            profile: profile, root: root
        )

        try ConfigService.setCadencePreset(profile: profile, preset: .cloud, workspaceRoot: root)

        let cfg = try loadEngineConfig(profile: profile, root: root)
        XCTAssertEqual(cfg.jamfCli?.profile, "tenant-b")
        XCTAssertEqual(cfg.jamfCli?.dataDir, "my-data")
        XCTAssertEqual(cfg.collectCadence?.preset, .cloud)
    }

    // MARK: - Round trip + idempotence

    func testPresetWriteReadRoundTrip() throws {
        let root = try tempRoot()
        let profile = "cad-rt-\(UUID().uuidString.lowercased())"
        for preset in CadencePreset.allCases {
            try ConfigService.setCadencePreset(profile: profile, preset: preset, workspaceRoot: root)
            let cfg = try loadEngineConfig(profile: profile, root: root)
            XCTAssertEqual(cfg.collectCadence?.preset, preset,
                           "\(preset.rawValue) must round-trip through write → read")
        }
    }

    func testRepeatedWritesConvergeOnLastValue() throws {
        let root = try tempRoot()
        let profile = "cad-idem-\(UUID().uuidString.lowercased())"
        try ConfigService.setCadencePreset(profile: profile, preset: .cloud, workspaceRoot: root)
        try ConfigService.setCadencePreset(profile: profile, preset: .onPrem, workspaceRoot: root)
        try ConfigService.setCadencePreset(profile: profile, preset: .custom, workspaceRoot: root)
        let cfg = try loadEngineConfig(profile: profile, root: root)
        XCTAssertEqual(cfg.collectCadence?.preset, .custom)
    }

    // MARK: - setCustomCadence (T-23)

    func testSetCustomCadenceWritesScalarAndObjectForms() throws {
        let root = try tempRoot()
        let profile = "cad-custom-\(UUID().uuidString.lowercased())"
        try ConfigService.setCustomCadence(
            profile: profile,
            perReport: [
                "update-status": PerReportCadence(cadence: .never),
                "overview": PerReportCadence(cadence: .seconds(86_400)),
                "ea-results": PerReportCadence(tier: .scan, cadence: .seconds(604_800)),
            ],
            workspaceRoot: root
        )

        let cfg = try loadEngineConfig(profile: profile, root: root)
        XCTAssertEqual(cfg.collectCadence?.perReport?["update-status"]?.cadence, .never)
        XCTAssertNil(cfg.collectCadence?.perReport?["update-status"]?.tier)
        XCTAssertEqual(cfg.collectCadence?.perReport?["overview"]?.cadence, .seconds(86_400))
        XCTAssertEqual(cfg.collectCadence?.perReport?["ea-results"]?.tier, .scan)
        XCTAssertEqual(cfg.collectCadence?.perReport?["ea-results"]?.cadence, .seconds(604_800))
    }

    func testSetCustomCadencePreservesPresetSibling() throws {
        let root = try tempRoot()
        let profile = "cad-custom-sib-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
            collect_cadence:
              preset: custom
            """,
            profile: profile, root: root
        )

        try ConfigService.setCustomCadence(
            profile: profile,
            perReport: ["overview": PerReportCadence(cadence: .seconds(3_600))],
            workspaceRoot: root
        )

        let cfg = try loadEngineConfig(profile: profile, root: root)
        XCTAssertEqual(cfg.collectCadence?.preset, .custom, "preset sibling preserved")
        XCTAssertEqual(cfg.collectCadence?.perReport?["overview"]?.cadence, .seconds(3_600))
    }

    func testSetCustomCadenceRoundTripsEveryReportKind() throws {
        // Mirror the realistic Custom-editor payload: one entry per known
        // collect kind. The write → read round trip must preserve all.
        let root = try tempRoot()
        let profile = "cad-custom-all-\(UUID().uuidString.lowercased())"
        var perReport: [String: PerReportCadence] = [:]
        for kind in ReportEngine.knownCollectKinds {
            perReport[kind] = PerReportCadence(cadence: .seconds(604_800))
        }
        try ConfigService.setCustomCadence(
            profile: profile, perReport: perReport, workspaceRoot: root
        )
        let cfg = try loadEngineConfig(profile: profile, root: root)
        XCTAssertEqual(cfg.collectCadence?.perReport?.count, ReportEngine.knownCollectKinds.count)
        for kind in ReportEngine.knownCollectKinds {
            XCTAssertEqual(cfg.collectCadence?.perReport?[kind]?.cadence, .seconds(604_800),
                           "\(kind) must round-trip")
        }
    }

    func testSetCustomCadenceReplacesPriorPerReport() throws {
        let root = try tempRoot()
        let profile = "cad-custom-rep-\(UUID().uuidString.lowercased())"
        try ConfigService.setCustomCadence(
            profile: profile,
            perReport: ["overview": PerReportCadence(cadence: .seconds(60))],
            workspaceRoot: root
        )
        // Second write with a different set — the prior entry must not linger.
        try ConfigService.setCustomCadence(
            profile: profile,
            perReport: ["security": PerReportCadence(cadence: .never)],
            workspaceRoot: root
        )
        let cfg = try loadEngineConfig(profile: profile, root: root)
        XCTAssertNil(cfg.collectCadence?.perReport?["overview"],
                     "per_report is replaced wholesale, not merged")
        XCTAssertEqual(cfg.collectCadence?.perReport?["security"]?.cadence, .never)
    }

    // MARK: - Migration banner data source (T-25)

    /// The Settings migration banner shows while `jamfCli.collectSkip` is
    /// non-empty in the decoded config and hides once a preset save removes
    /// the key. Pin that exact transition — the banner's whole condition.
    func testCollectSkipDecodedThenClearedByPresetSave() throws {
        let root = try tempRoot()
        let profile = "cad-banner-\(UUID().uuidString.lowercased())"
        try writeConfig(
            """
            jamf_cli:
              profile: tenant-a
              collect_skip:
                - update-status
            """,
            profile: profile, root: root
        )

        // Before: the banner's data source sees the legacy key.
        let before = try loadEngineConfig(profile: profile, root: root)
        XCTAssertEqual(before.jamfCli?.collectSkip?.isEmpty, false,
                       "collect_skip must decode while it's in the file — banner shows")

        try ConfigService.setCadencePreset(profile: profile, preset: .onPrem, workspaceRoot: root)

        // After: the key is gone, so the banner condition is false.
        let after = try loadEngineConfig(profile: profile, root: root)
        XCTAssertNil(after.jamfCli?.collectSkip,
                     "collect_skip removed by the preset save — banner hides")
    }

    // MARK: - Helpers

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JRCCadenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeConfig(_ text: String, profile: String, root: URL) throws {
        let url = try ConfigService.configURL(for: profile, workspaceRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func loadEngineConfig(profile: String, root: URL) throws -> ReportConfig {
        let url = try ConfigService.configURL(for: profile, workspaceRoot: root)
        return try ConfigLoader.load(from: url)
    }
}
