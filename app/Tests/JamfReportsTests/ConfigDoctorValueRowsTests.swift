import Foundation
import XCTest
@testable import JamfReports

/// Values the app replaced, clamped or ignored are stated by the Config Doctor, and the two
/// value-reading changes that go with them.
final class ConfigDoctorValueRowsTests: XCTestCase {

    // MARK: - Helpers

    private func rows(_ yaml: String, workspace: URL? = nil) throws -> [DoctorRow] {
        let config = try ConfigLoader.loadFromString(yaml)
        let raw = try ConfigLoader.rawMapping(fromYAML: yaml)
        return ConfigDoctorService.valueRows(config, raw: raw, workspace: workspace)
    }

    private func detail(_ rows: [DoctorRow], _ title: String) -> String? {
        rows.first { $0.title == title }?.detail
    }

    private func titles(_ rows: [DoctorRow]) -> [String] { rows.map(\.title) }

    // MARK: - notify.detail fails toward sending less

    func testAnUnrecognisedNotifyDetailResolvesToMinimal() throws {
        for typed in ["verbose", "", "ful", "everything"] {
            let notify = try XCTUnwrap(
                try ConfigLoader.loadFromString("notify:\n  detail: \"\(typed)\"\n").notify)
            XCTAssertEqual(notify.resolvedDetail, .minimal,
                           "\"\(typed)\" is neither full nor minimal, so it must send less")
        }
    }

    func testNotifyDetailIsReadCaseInsensitivelyAndAbsentStaysFull() throws {
        let upper = try XCTUnwrap(
            try ConfigLoader.loadFromString("notify:\n  detail: MINIMAL\n").notify)
        XCTAssertEqual(upper.resolvedDetail, .minimal)
        let mixed = try XCTUnwrap(
            try ConfigLoader.loadFromString("notify:\n  detail: Full\n").notify)
        XCTAssertEqual(mixed.resolvedDetail, .full)
        let absent = try XCTUnwrap(
            try ConfigLoader.loadFromString("notify:\n  enabled: false\n").notify)
        XCTAssertEqual(absent.resolvedDetail, .full, "no value typed: the documented default")
    }

    // MARK: - output.keep_latest_runs below 1 is 1

    func testAKeepLatestRunsBelowOneIsTreatedAsOne() throws {
        for typed in [0, -1, -50] {
            let output = try XCTUnwrap(
                try ConfigLoader.loadFromString("output:\n  keep_latest_runs: \(typed)\n").output)
            XCTAssertEqual(output.resolvedKeepLatestRuns, 1, "\(typed) must keep the newest run")
        }
        let five = try XCTUnwrap(
            try ConfigLoader.loadFromString("output:\n  keep_latest_runs: 5\n").output)
        XCTAssertEqual(five.resolvedKeepLatestRuns, 5)
        XCTAssertEqual(OutputConfig().resolvedKeepLatestRuns, 10, "absent: the documented default")
    }

    /// `generate` hands `resolvedKeepLatestRuns` to `archiveOldRuns` right after it writes the
    /// workbook, so a resolved 0 moved the report it had just written into the archive.
    func testKeepLatestRunsZeroLeavesTheReportJustWritten() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-keep-\(UUID().uuidString)", isDirectory: true)
        let reports = tmp.appendingPathComponent("reports", isDirectory: true)
        let archive = tmp.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for name in ["report_2026-10-01_080000.xlsx", "report_2026-10-02_080000.xlsx"] {
            try Data().write(to: reports.appendingPathComponent(name))
        }
        let config = try ConfigLoader.loadFromString("output:\n  keep_latest_runs: 0\n")
        let keep = try XCTUnwrap(config.output).resolvedKeepLatestRuns

        ReportEngine(config: config, dataDir: tmp).archiveOldRuns(
            outputDir: reports, archiveDir: archive, stem: "report", keep: keep)

        let left = try FileManager.default.contentsOfDirectory(atPath: reports.path)
        XCTAssertEqual(left, ["report_2026-10-02_080000.xlsx"],
                       "the newest run, the one just written, stays in the reports folder")
    }

    // MARK: - Settings the app replaced or clamped

    func testNotifyProviderAndDetailThatAreNotRecognisedNameWhatTheAppUses() throws {
        let found = try rows("notify:\n  provider: discord\n  detail: verbose\n")
        XCTAssertEqual(detail(found, "notify.provider"),
                       "\"discord\" is not one of teams, slack. The app uses teams.")
        XCTAssertEqual(detail(found, "notify.detail"),
                       "\"verbose\" is not one of full, minimal. The app uses minimal.")
        XCTAssertEqual(Set(found.map(\.severity)), [.warn],
                       "a typo must not turn a scheduled run red")
        XCTAssertEqual(Set(found.map(\.id)).count, found.count, "the list keys its rows by id")
        XCTAssertEqual(try rows("notify:\n  provider: Slack\n  detail: FULL\n"), [],
                       "both are read case-insensitively")
    }

    func testAnEnabledNotifyBlockWithoutAUsableURLSaysNothingIsSentAndNeverShowsTheURL() throws {
        let empty = try rows("notify:\n  enabled: true\n  url: \"\"\n")
        XCTAssertEqual(detail(empty, "notify.url"),
                       "notify.enabled is true but url is empty. The app sends no webhook.")
        let url = "http://hooks.example.com/services/T000/B000/abc123"
        let plain = try rows("notify:\n  enabled: true\n  url: \"\(url)\"\n")
        XCTAssertEqual(detail(plain, "notify.url"),
                       "notify.enabled is true but url does not start with https://. "
                       + "The app sends no webhook.")
        let shown = plain.map { $0.title + $0.detail + ($0.hint ?? "") }.joined()
        XCTAssertFalse(shown.contains("hooks.example.com"), "a webhook URL is a secret")
        let https = "notify:\n  enabled: true\n  url: \"https://hooks.example.com/x\"\n"
        XCTAssertEqual(try rows(https), [])
        XCTAssertEqual(try rows("notify:\n  enabled: false\n  url: \"\"\n"), [],
                       "off is a choice, not a mistake")
    }

    func testARetentionModeThatIsNotRecognisedNamesTheModeTheAppUses() throws {
        XCTAssertEqual(detail(try rows("retention:\n  mode: purge\n"), "retention.mode"),
                       "\"purge\" is not one of archive, delete. The app uses archive.")
        XCTAssertEqual(try rows("retention:\n  mode: Delete\n"), [])
    }

    func testRetentionEnabledWithNeitherHorizonSaysNothingWillBeRemoved() throws {
        let yaml = "retention:\n  enabled: true\n  snapshot_keep_days: 0\n"
        XCTAssertEqual(
            detail(try rows(yaml), "retention.enabled"),
            "retention.enabled is true but snapshot_keep_days is 0 and snapshot_keep_count "
                + "is 0, so no snapshot is ever archived or deleted.")
        XCTAssertEqual(try rows(yaml + "  snapshot_keep_count: 3\n"), [], "the count rule runs")
        XCTAssertEqual(try rows("retention:\n  enabled: true\n"), [], "the age default is 365")
        XCTAssertEqual(try rows("retention:\n  enabled: false\n  snapshot_keep_days: 0\n"), [])
    }

    func testARetentionArchiveDirOutsideTheWorkspacesFolderNamesTheFolderTheAppUses() throws {
        try withWorkspacesRoot { root, workspace in
            let outside = "/private/tmp/jrc-elsewhere"
            let found = try rows("retention:\n  archive_dir: \"\(outside)\"\n",
                                 workspace: workspace)
            XCTAssertEqual(
                detail(found, "retention.archive_dir"),
                "\"\(outside)\" is outside the workspaces folder. The app archives to _archive "
                    + "in the workspace instead.")
            let inside = workspace.appendingPathComponent("old").path
            XCTAssertEqual(try rows("retention:\n  archive_dir: \"\(inside)\"\n",
                                    workspace: workspace), [])
            XCTAssertEqual(try rows("retention:\n  archive_dir: \"old-snapshots\"\n",
                                    workspace: workspace), [], "a relative path is inside")
            XCTAssertEqual(try rows("retention:\n  archive_dir: \"\(outside)\"\n"), [],
                           "no workspace to judge it against")
        }
    }

    func testSharedWorkspaceValuesOutsideTheirClampsStateTypedAndUsed() throws {
        let found = try rows("""
        shared_workspace:
          claim_ttl_minutes: 1
          min_collect_interval_hours: -2
        """)
        XCTAssertEqual(detail(found, "shared_workspace.claim_ttl_minutes"),
                       "1 is outside 5 to 720. The app uses 5.")
        XCTAssertEqual(detail(found, "shared_workspace.min_collect_interval_hours"),
                       "-2 is outside 0 to 168. The app uses 0, which turns the freshness "
                       + "check off.")
        let high = try rows("shared_workspace:\n  claim_ttl_minutes: 1000\n"
                            + "  min_collect_interval_hours: 500\n")
        XCTAssertEqual(detail(high, "shared_workspace.claim_ttl_minutes"),
                       "1000 is outside 5 to 720. The app uses 720.")
        XCTAssertEqual(detail(high, "shared_workspace.min_collect_interval_hours"),
                       "500 is outside 0 to 168. The app uses 168.")
        XCTAssertEqual(try rows("shared_workspace:\n  claim_ttl_minutes: 45\n"
                                + "  min_collect_interval_hours: 12\n"), [])
    }

    func testCollectSkipEntriesThatAreNotSkippableKindsAreNamed() throws {
        let found = try rows("jamf_cli:\n  collect_skip: [update_status, computers, Foo]\n")
        XCTAssertEqual(
            detail(found, "jamf_cli.collect_skip"),
            "\"computers\", \"Foo\" cannot be skipped, so collect still runs them and the "
                + "stall guard does not apply.")
        XCTAssertTrue(found.first?.hint?.contains("patch-device-failures") == true,
                      "the hint lists what can be skipped")
        XCTAssertEqual(try rows("jamf_cli:\n  collect_skip: [update_status, Profile-Status]\n"), [])
    }

    func testAKeepLatestRunsBelowOneIsStatedAsOne() throws {
        let key = "output.keep_latest_runs"
        XCTAssertEqual(detail(try rows("output:\n  keep_latest_runs: 0\n"), key),
                       "0 is below 1. The app keeps the newest 1 report.")
        XCTAssertEqual(detail(try rows("output:\n  keep_latest_runs: -4\n"), key),
                       "-4 is below 1. The app keeps the newest 1 report.")
        XCTAssertEqual(try rows("output:\n  keep_latest_runs: 5\n"), [])
    }

    func testHTMLSectionLimitsOutsideTheirClampsStateTypedAndUsed() throws {
        let found = try rows("""
        html:
          section_limits:
            protect_alerts: 500
            insights_drift_snapshots: 0
        """)
        XCTAssertEqual(detail(found, "html.section_limits.protect_alerts"),
                       "500 is outside 1 to 200. The app uses 200.")
        XCTAssertEqual(detail(found, "html.section_limits.insights_drift_snapshots"),
                       "0 is outside 1 to 12. The app uses 1.")
        XCTAssertEqual(try rows("html:\n  section_limits:\n    protect_alerts: 25\n"), [])
    }

    func testAnUnknownAITierOrReasoningLevelNamesWhatTheAppUses() throws {
        let found = try rows("ai:\n  tier: pcc\n  reasoning_level: extreme\n")
        XCTAssertEqual(detail(found, "ai.tier"),
                       "\"pcc\" is not one of on_device, external. The app uses on_device.")
        XCTAssertEqual(detail(found, "ai.reasoning_level"),
                       "\"extreme\" is not one of light, moderate, deep. The app uses light.")
        XCTAssertEqual(try rows("ai:\n  tier: External\n  reasoning_level: Deep\n"), [])
    }

    func testAColourThatIsNotHexIsStatedWithTheColourTheAppUses() throws {
        let found = try rows("""
        branding:
          accent_color: red
        charts:
          compliance_trend:
            bands:
              - {label: Pass, min_failures: 0, max_failures: 0, color: "#4472C4"}
              - {label: Low, min_failures: 1, max_failures: 10, color: blue}
        """)
        XCTAssertEqual(
            titles(found),
            ["branding.accent_color", "charts.compliance_trend.bands[1].color"])
        XCTAssertEqual(
            detail(found, "branding.accent_color"),
            "\"red\" is not a hex colour such as #2D5EA2. The HTML report uses #2D5EA2 "
                + "instead; the Excel workbook writes the value as typed.")
        XCTAssertEqual(
            detail(found, "charts.compliance_trend.bands[1].color"),
            "\"blue\" is not a hex colour such as #4472C4. The chart uses its default "
                + "palette colour for this band.")
        XCTAssertEqual(try rows("branding:\n  accent_color: \"#2D5EA2\"\n"), [])
        XCTAssertEqual(try rows("charts:\n  compliance_trend:\n    bands:\n      - "
                                + "{label: A, min_failures: 0, max_failures: 0, color: FF00AA}\n"),
                       [], "the chart reader accepts six digits without the #")
    }

    func testTextTakenFromTheFileIsCappedAndStrippedBeforeItReachesARow() {
        var config = ReportConfig()
        config.notify = NotifyConfig(
            provider: "x\u{1B}[2J" + String(repeating: "y", count: 200))
        let found = ConfigDoctorService.valueRows(config, raw: [:])
        let text = found.map { $0.title + $0.detail + ($0.hint ?? "") }.joined()
        XCTAssertFalse(text.contains("\u{1B}"))
        XCTAssertLessThan(try XCTUnwrap(found.first).detail.count, 140)
        XCTAssertTrue(text.contains("…"))
    }

    func testTheProfileOverloadJudgesTheArchiveDirAgainstTheProfilesOwnWorkspace() throws {
        try withWorkspacesRoot { root, workspace in
            let yaml = "retention:\n  archive_dir: \"/private/tmp/jrc-elsewhere\"\n"
            try yaml.write(to: workspace.appendingPathComponent("config.yaml"),
                           atomically: true, encoding: .utf8)
            let found = ConfigDoctorService.valueRows(
                profile: "values", config: try ConfigLoader.loadFromString(yaml),
                workspaceRoot: root)
            XCTAssertEqual(titles(found), ["retention.archive_dir"])
        }
    }

    // MARK: Workspace for the rows that read a folder

    private func withWorkspacesRoot(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-values-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("values", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        try body(root, workspace)
    }
}
