import XCTest
@testable import JamfReports

/// Before 2.7.0 the Customize screen's "Save PNGs alongside xlsx" and
/// "Per-major-version charts" switches were plain view state: never read from
/// config.yaml, never written back, and in the PNG case governing a key
/// (`charts.save_png`) that no code consumed. These pin the wiring.
final class ChartsConfigStoreTests: XCTestCase {

    private var root: URL!
    private let profile = "jrc-charts-test"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-charts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func configURL() throws -> URL {
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        return ws.appendingPathComponent("config.yaml")
    }

    private func write(_ yaml: String) throws {
        try yaml.write(to: try configURL(), atomically: true, encoding: .utf8)
    }

    private func readBack() throws -> String {
        try String(contentsOf: try configURL(), encoding: .utf8)
    }

    // MARK: - Round trip

    func testSaveThenLoadRoundTripsBothOptions() throws {
        try write("charts:\n  enabled: true\n")
        try ChartsConfigWriter.save(
            ChartsOptions(savePNGs: false, perMajorCharts: false), profile: profile)

        let loaded = ChartsConfigLoader.load(profile: profile)
        XCTAssertFalse(loaded.savePNGs, "save_png must survive a write/read cycle")
        XCTAssertFalse(loaded.perMajorCharts, "per_major_charts must survive too")
    }

    func testBothOptionsPersistIndependently() throws {
        try write("charts:\n  enabled: true\n")
        try ChartsConfigWriter.save(
            ChartsOptions(savePNGs: false, perMajorCharts: true), profile: profile)
        let loaded = ChartsConfigLoader.load(profile: profile)
        XCTAssertFalse(loaded.savePNGs)
        XCTAssertTrue(loaded.perMajorCharts, "one switch must not drag the other with it")
    }

    // MARK: - The hazard: charts: is a nested block

    /// `charts:` carries historical_csv_dir, the compliance-trend bands list and
    /// three sub-blocks. Replacing the block instead of setting individual keys
    /// would discard everything this screen does not model — silent data loss in
    /// the user's own config file.
    func testSavingDoesNotDiscardTheRestOfTheChartsBlock() throws {
        try write("""
        charts:
          enabled: true
          embed_in_xlsx: true
          historical_csv_dir: "snapshots"
          archive_current_csv: true
          compliance_trend:
            enabled: true
            bands:
              - {label: "Pass", min_failures: 0, max_failures: 0, color: "#4472C4"}
          device_state_trend:
            enabled: true
        """)
        try ChartsConfigWriter.save(
            ChartsOptions(savePNGs: false, perMajorCharts: false), profile: profile)

        let text = try readBack()
        for survivor in ["historical_csv_dir", "archive_current_csv", "compliance_trend",
                         "device_state_trend", "bands", "Pass", "#4472C4", "embed_in_xlsx"] {
            XCTAssertTrue(text.contains(survivor),
                          "writing chart options must not drop \(survivor)")
        }
    }

    /// Same hazard one level deeper: os_adoption has its own sibling keys.
    func testSavingPreservesSiblingKeysInsideOSAdoption() throws {
        try write("""
        charts:
          os_adoption:
            enabled: true
            per_major_charts: true
        """)
        try ChartsConfigWriter.save(
            ChartsOptions(savePNGs: true, perMajorCharts: false), profile: profile)

        let text = try readBack()
        XCTAssertTrue(text.contains("os_adoption"))
        XCTAssertTrue(text.contains("enabled"),
                      "os_adoption.enabled must survive a per_major_charts write")
        XCTAssertFalse(ChartsConfigLoader.load(profile: profile).perMajorCharts)
    }

    /// Unrelated top-level blocks must be untouched — the same guarantee
    /// NotifyConfigWriter gives.
    func testSavingPreservesUnrelatedTopLevelKeys() throws {
        try write("""
        columns:
          serial: "Serial Number"
        charts:
          enabled: true
        thresholds:
          stale_device_days: 45
        """)
        try ChartsConfigWriter.save(
            ChartsOptions(savePNGs: false, perMajorCharts: false), profile: profile)

        let text = try readBack()
        XCTAssertTrue(text.contains("Serial Number"))
        XCTAssertTrue(text.contains("stale_device_days"))
    }

    // MARK: - Defaults

    /// A workspace with no charts: block must behave as it always has — PNGs
    /// written. Defaulting to false would silently stop producing files that
    /// every existing install currently gets.
    func testAbsentChartsBlockDefaultsToPreviousBehaviour() throws {
        try write("columns:\n  serial: \"Serial Number\"\n")
        let loaded = ChartsConfigLoader.load(profile: profile)
        XCTAssertTrue(loaded.savePNGs, "absent config must keep writing PNGs")
        XCTAssertTrue(loaded.perMajorCharts)
    }

    func testMissingConfigFileDegradesToDefaultsRatherThanThrowing() {
        let loaded = ChartsConfigLoader.load(profile: "jrc-charts-absent")
        XCTAssertEqual(loaded, ChartsOptions.defaults)
    }

    func testUnparseableConfigDegradesToDefaults() throws {
        try write("charts:\n  - this is not a mapping\n : : :\n")
        XCTAssertEqual(ChartsConfigLoader.load(profile: profile), ChartsOptions.defaults)
    }

    func testWriterRejectsAnInvalidProfileName() {
        XCTAssertThrowsError(
            try ChartsConfigWriter.save(.defaults, profile: "../escape"))
    }

    /// Writing into a workspace with no config.yaml yet must create a usable one
    /// rather than fail — Customize can be opened before Config is ever saved.
    func testSaveCreatesConfigWhenAbsent() throws {
        try ChartsConfigWriter.save(
            ChartsOptions(savePNGs: false, perMajorCharts: false), profile: profile)
        XCTAssertFalse(ChartsConfigLoader.load(profile: profile).savePNGs)
    }
}
