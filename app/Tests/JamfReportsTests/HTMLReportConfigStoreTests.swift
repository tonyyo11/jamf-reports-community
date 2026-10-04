import XCTest
@testable import JamfReports

/// The Customize screen's "Write the HTML report with every workbook" switch: the scoped
/// read and write of `html.with_workbook`, which must leave the rest of `html:` and the file as
/// typed.
final class HTMLReportConfigStoreTests: XCTestCase {

    private var root: URL!
    private let profile = "jrc-html-store-test"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-html-store-\(UUID().uuidString)", isDirectory: true)
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

    func testSaveThenLoadRoundTripsBothValues() throws {
        try write("html:\n  track_history: false\n")
        try HTMLReportConfigWriter.save(withWorkbook: true, profile: profile)
        XCTAssertTrue(HTMLReportConfigLoader.withWorkbook(profile: profile))
        try HTMLReportConfigWriter.save(withWorkbook: false, profile: profile)
        XCTAssertFalse(HTMLReportConfigLoader.withWorkbook(profile: profile))
        XCTAssertTrue(try readBack().contains("with_workbook: false"),
                      "turning it off where it was on writes false, it does not delete the key")
    }

    func testSaveCreatesTheConfigWhenAbsent() throws {
        try HTMLReportConfigWriter.save(withWorkbook: true, profile: profile)
        XCTAssertTrue(HTMLReportConfigLoader.withWorkbook(profile: profile))
    }

    // MARK: - What the write leaves alone

    /// `html:` also carries `track_history`, `history_file` and the `section_limits`
    /// sub-block; replacing the block would discard what this switch does not model.
    func testSavingKeepsTheOtherHTMLKeys() throws {
        try write("""
            html:
              track_history: true
              history_file: "history/html.json"
              section_limits:
                protect_alerts: 50
                insights_drift_snapshots: 4
            """)
        try HTMLReportConfigWriter.save(withWorkbook: true, profile: profile)

        let config = try ConfigLoader.load(from: try configURL())
        XCTAssertEqual(config.html?.writesWithWorkbook, true)
        XCTAssertEqual(config.html?.sectionLimits?.protectAlerts, 50)
        XCTAssertEqual(config.html?.sectionLimits?.insightsDriftSnapshots, 4)
        let text = try readBack()
        XCTAssertTrue(text.contains("track_history: true"))
        XCTAssertTrue(text.contains("history_file: \"history/html.json\"")
                      || text.contains("history_file: history/html.json"), text)
    }

    func testSavingKeepsEverythingOutsideTheHTMLBlock() throws {
        try write("""
            # team config
            columns:
              serial: "Serial Number"   # inventory export header
            thresholds:
              stale_device_days: 45

            html:
              track_history: true
            charts:
              enabled: true
            """)
        try HTMLReportConfigWriter.save(withWorkbook: true, profile: profile)

        let text = try readBack()
        for kept in ["# team config", "serial: \"Serial Number\"   # inventory export header",
                     "stale_device_days: 45", "charts:", "enabled: true"] {
            XCTAssertTrue(text.contains(kept), "lost \(kept):\n\(text)")
        }
    }

    /// Off where the file never set the key is the state it is already in.
    func testTurningItOffWhereItWasNeverSetWritesNothing() throws {
        let original = "columns:\n  serial: \"Serial Number\"\n"
        try write(original)
        let saved = try HTMLReportConfigWriter.save(withWorkbook: false, profile: profile)
        XCTAssertEqual(try readBack(), original, "no html: block is added")
        XCTAssertEqual(saved.report, ConfigSaveReport())

        try write("html:\n  track_history: true\n")
        try HTMLReportConfigWriter.save(withWorkbook: false, profile: profile)
        XCTAssertFalse(try readBack().contains("with_workbook"))
    }

    func testSettingTheSameValueAgainChangesNothing() throws {
        try write("html:\n  with_workbook: true\n")
        let before = try readBack()
        let saved = try HTMLReportConfigWriter.save(withWorkbook: true, profile: profile)
        XCTAssertEqual(try readBack(), before)
        XCTAssertEqual(saved.report, ConfigSaveReport())
    }

    func testAHTMLBlockTypedAsSomethingElseIsNotOverwritten() throws {
        try write("html: not a block\n")
        XCTAssertThrowsError(try HTMLReportConfigWriter.save(withWorkbook: true, profile: profile))
        XCTAssertEqual(try readBack(), "html: not a block\n")
    }

    // MARK: - Reading

    func testTheLoaderReadsOffForAMissingUnparseableOrMistypedConfig() throws {
        XCTAssertFalse(HTMLReportConfigLoader.withWorkbook(profile: "jrc-html-store-absent"))
        try write("html:\n  - this is not a mapping\n : : :\n")
        XCTAssertFalse(HTMLReportConfigLoader.withWorkbook(profile: profile))
        try write("html:\n  with_workbook: maybe\n")
        XCTAssertFalse(HTMLReportConfigLoader.withWorkbook(profile: profile))
        try write("html:\n  with_workbook: \"true\"\n")
        XCTAssertTrue(HTMLReportConfigLoader.withWorkbook(profile: profile))
    }

    func testTheWriterRejectsAnInvalidProfileName() {
        XCTAssertThrowsError(try HTMLReportConfigWriter.save(withWorkbook: true, profile: "bad\n"))
    }
}
