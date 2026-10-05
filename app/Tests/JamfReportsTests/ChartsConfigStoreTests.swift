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

    // MARK: - Customize Apply

    /// Apply writes the charts block, then the html one. A failed html write keeps the note
    /// the charts write already made.
    func testApplyKeepsTheChartsNoteWhenTheHTMLWriteFails() throws {
        try write("charts:\n  # team note\n  save_png: true\nhtml: off\n")
        var notes: [ProfileSaveNote] = []

        XCTAssertThrowsError(try CustomizeView.writeOptions(
            ChartsOptions(savePNGs: false, perMajorCharts: true), withWorkbook: true,
            profile: profile) { notes.append($0) })

        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.profile, profile)
        XCTAssertTrue(notes.first?.line.contains("config.yaml.bak-") ?? false, "\(notes)")
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

    /// Same hazard one level deeper: a hand-typed sibling of per_major_charts stays.
    /// os_adoption.enabled, which nothing reads now, goes, and the save says so.
    func testSavingPreservesSiblingKeysInsideOSAdoptionAndDropsTheRetiredOne() throws {
        try write("""
        charts:
          os_adoption:
            enabled: true
            team_note: keep me
            per_major_charts: true
        """)
        let saved = try ChartsConfigWriter.save(
            ChartsOptions(savePNGs: true, perMajorCharts: false), profile: profile)

        let text = try readBack()
        XCTAssertTrue(text.contains("os_adoption"))
        XCTAssertTrue(text.contains("team_note: keep me"))
        XCTAssertFalse(text.contains("enabled"), "os_adoption.enabled is no longer read")
        XCTAssertFalse(ChartsConfigLoader.load(profile: profile).perMajorCharts)
        XCTAssertEqual(saved.report.removedRetiredKeys, ["charts.os_adoption.enabled"])
        XCTAssertEqual(saved.report.notes.count, 1)
        XCTAssertTrue(saved.report.notes[0].hasPrefix(
            "Settings the app no longer reads were removed from config.yaml: "
                + "charts.os_adoption.enabled (since 2.9)."))
    }

    /// The options are unchanged here; the retired key alone makes the block worth rewriting.
    func testApplyingTheSameOptionsStillRemovesTheRetiredKey() throws {
        try write("charts:\n  save_png: true\n  os_adoption:\n    enabled: false\n"
            + "    per_major_charts: true\n")
        try ChartsConfigWriter.save(ChartsOptions.defaults, profile: profile)
        XCTAssertFalse(try readBack().contains("enabled"))

        let again = try ChartsConfigWriter.save(ChartsOptions.defaults, profile: profile)
        XCTAssertEqual(again.report, ConfigSaveReport(), "nothing left to change writes nothing")
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
            try ChartsConfigWriter.save(.defaults, profile: "escape\n"))
    }

    /// Writing into a workspace with no config.yaml yet must create a usable one
    /// rather than fail — Customize can be opened before Config is ever saved.
    func testSaveCreatesConfigWhenAbsent() throws {
        try ChartsConfigWriter.save(
            ChartsOptions(savePNGs: false, perMajorCharts: false), profile: profile)
        XCTAssertFalse(ChartsConfigLoader.load(profile: profile).savePNGs)
    }
}
