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

    func testARetentionArchiveDirOutsideTheWorkspaceNamesTheFolderTheAppUses() throws {
        try withWorkspacesRoot { root, workspace in
            let outside = "/private/tmp/jrc-elsewhere"
            let found = try rows("retention:\n  archive_dir: \"\(outside)\"\n",
                                 workspace: workspace)
            XCTAssertEqual(
                detail(found, "retention.archive_dir"),
                "\"\(outside)\" is outside the workspace. The app archives to _archive in the "
                    + "workspace instead.")
            for typed in ["../outside", root.appendingPathComponent("shared").path] {
                XCTAssertEqual(titles(try rows("retention:\n  archive_dir: \"\(typed)\"\n",
                                               workspace: workspace)),
                               ["retention.archive_dir"], typed)
            }
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
            "\"computers\", \"Foo\" are not kinds collect can skip, so they skip nothing and "
                + "the stall guard does not apply to them.")
        XCTAssertEqual(
            detail(try rows("jamf_cli:\n  collect_skip: [computers]\n"), "jamf_cli.collect_skip"),
            "\"computers\" is not a kind collect can skip, so it skips nothing and the stall "
                + "guard does not apply to it.")
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
                       "\"pcc\" is not one of on_device. The app uses on_device.")
        XCTAssertEqual(detail(found, "ai.reasoning_level"),
                       "\"extreme\" is not one of light, moderate, deep. The app uses light.")
        // The external tier was removed before this track landed; a file still naming it
        // gets the same row as any other unknown tier.
        XCTAssertEqual(detail(try rows("ai:\n  tier: external\n"), "ai.tier"),
                       "\"external\" is not one of on_device. The app uses on_device.")
        XCTAssertEqual(try rows("ai:\n  tier: On_Device\n  reasoning_level: Deep\n"), [])
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
            "\"red\" is not a hex colour such as #2D5EA2. The workbook and the HTML report use "
                + "#2D5EA2 instead.")
        XCTAssertEqual(titles(try rows("branding:\n  accent_color: \"#2D5EA2FF\"\n")),
                       ["branding.accent_color"], "both reports take #RGB or #RRGGBB only")
        XCTAssertEqual(try rows("branding:\n  accent_color: \"#abc\"\n"), [])
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

    // MARK: - Values the app ignored

    func testSheetNamesThatMatchNoSheetAreNamedPerList() throws {
        let found = try rows("""
        custom_eas:
          - {name: Disk Use, column: Boot Drive, type: percentage}
        sheets:
          only: ["Patch Compliance", "Patch Complience", "disk use", "Device Inventory"]
          skip: [cover, Nonsense]
          order: ["Fleet Overview", "Fleet Overveiw"]
        """)
        XCTAssertEqual(titles(found), ["sheets.only", "sheets.skip", "sheets.order"])
        XCTAssertEqual(detail(found, "sheets.only"),
                       "\"Patch Complience\" matches no sheet, so the app ignores it.")
        XCTAssertEqual(detail(found, "sheets.skip"),
                       "\"Nonsense\" matches no sheet, so the app ignores it.")
        XCTAssertEqual(detail(found, "sheets.order"),
                       "\"Fleet Overveiw\" matches no sheet, so the app ignores it.")
    }

    func testTheSheetNamesTheDoctorKnowsAreTheNamesTheDashboardsCanWrite() throws {
        let core = CoreDashboard(
            config: ReportConfig(), dataDir: FileManager.default.temporaryDirectory,
            workbook: Workbook())
        XCTAssertEqual(Set(core.sheetPlan.map(\.name)), Set(SheetID.allCases.map(\.rawValue)))
        let computers = "Computer Name,Serial Number,Operating System Version,Last Check-in\n"
            + "Mac-001,C02,15.0,2026-01-01\n"
        let mobile = "Display Name,JSS Mobile Device ID,OS Version,Last Inventory Update,"
            + "Jailbreak Detected,Wi-Fi MAC Address,Battery Level,Lost Mode Enabled,"
            + "Device Ownership Type,Passcode Status\niPad-001,100,18.0,2026-01-01,false,"
            + "aa:bb:cc:dd:ee:ff,85%,false,Institutional,Compliant\n"
        var config = ReportConfig()
        config.compliance = ComplianceConfig(enabled: true)
        config.securityAgents = [
            SecurityAgentConfig(name: "Agent", column: "Agent Status", connectedValue: "Ok")]
        for csv in [computers, mobile] {
            let dashboard = try XCTUnwrap(CSVDashboard(
                config: config, csvData: Data(csv.utf8), workbook: Workbook()))
            let planned = Set(dashboard.sheetPlan.map(\.name))
            let known = Set(ConfigDoctorService.csvSheetNames)
            XCTAssertTrue(planned.isSubset(of: known), "\(planned.subtracting(known))")
        }
        let school = SchoolDashboard(
            config: ReportConfig(), dataDir: FileManager.default.temporaryDirectory,
            workbook: Workbook())
        XCTAssertEqual(school.sheetPlan.map(\.name), ConfigDoctorService.schoolSheetNames)
    }

    func testSheetNamesOnAJamfSchoolWorkspaceAreMatchedAgainstTheSchoolTabs() throws {
        let school = "school_cli:\n  enabled: true\n"
        let found = try rows(school + "sheets:\n  skip: [users, Fleet Overview]\n")
        XCTAssertEqual(titles(found), ["sheets.skip"])
        XCTAssertEqual(detail(found, "sheets.skip"),
                       "\"Fleet Overview\" matches no sheet, so the app ignores it.")
        XCTAssertEqual(try rows(school + "sheets:\n  order: [iBeacons, Stale Devices]\n"), [])
        XCTAssertEqual(try rows("sheets:\n  skip: [Cover, charts]\n"), [], "a Jamf Pro profile")
    }

    func testAnOnlyListThatMatchesNoSheetIsStatedAsIgnoredWhole() throws {
        XCTAssertEqual(
            detail(try rows("sheets:\n  only: [Patch Complience, Fleet Overveiw]\n"),
                   "sheets.only"),
            "\"Patch Complience\", \"Fleet Overveiw\" match no sheet, so the app ignores the "
                + "whole only list and says so in the run log.")
        XCTAssertEqual(
            detail(try rows("sheets:\n  only: [Covr]\n"), "sheets.only"),
            "\"Covr\" matches no sheet, so the app ignores the whole only list and says so in "
                + "the run log.")
        XCTAssertEqual(
            detail(try rows("sheets:\n  skip: [Covr]\n"), "sheets.skip"),
            "\"Covr\" matches no sheet, so the app ignores it.", "skip has no whole-list rule")
    }

    /// Pins the comment in config.example.yaml: skip is applied before only.
    func testASheetListedInBothOnlyAndSkipIsRemoved() {
        let sheets = SheetsConfig(only: ["A", "B"], skip: ["a"], order: nil)
        let plan: [(name: String, write: Int)] = [("A", 1), ("B", 2), ("C", 3)]
        XCTAssertEqual(sheets.applyTo(plan).map(\.name), ["B"])
    }

    func testAnExpiresDateThatIsNotYYYYMMDDIsNamedBecauseTheReportNeverMarksItExpired() throws {
        func exception(_ id: String, expires: String) -> String {
            "  - id: \(id)\n    description: d\n    signed_off_by: s\n"
                + "    signed_off_date: \"2026-01-01\"\n    expires_date: \"\(expires)\"\n"
        }
        let found = try rows("exceptions:\n"
            + exception("E-1", expires: "12/31/2026") + exception("E-2", expires: "2026-13-45")
            + exception("E-3", expires: "2026-12-31") + exception("E-4", expires: ""))
        XCTAssertEqual(titles(found),
                       ["exceptions[0].expires_date", "exceptions[1].expires_date"])
        XCTAssertEqual(found.first?.detail, "\"12/31/2026\" is not a yyyy-MM-dd date. The report "
                       + "never marks this exception expired.")
    }

    func testThresholdsAtOrBelowZeroAndAWarningAboveItsCriticalAreStated() throws {
        let found = try rows("""
        thresholds:
          stale_device_days: 0
          warning_disk_percent: 95
          critical_disk_percent: 90
          cert_warning_days: -1
          profile_error_warning: 0
        custom_eas:
          - {name: Disk, column: c, type: percentage, warning_threshold: 90, critical_threshold: 80}
        """)
        XCTAssertEqual(Set(titles(found)), [
            "thresholds.stale_device_days", "thresholds.cert_warning_days",
            "thresholds.profile_error_warning", "thresholds.warning_disk_percent",
            "custom_eas[0].warning_threshold",
        ])
        XCTAssertEqual(Set(found.map(\.id)).count, found.count)
        XCTAssertEqual(detail(found, "thresholds.stale_device_days"),
                       "0 is not above 0. The app uses it as written, so a Mac counts as stale "
                       + "as soon as a day passes without a check-in.")
        XCTAssertEqual(detail(found, "thresholds.warning_disk_percent"),
                       "warning_disk_percent (95) is above critical_disk_percent (90), so the "
                       + "warning band never applies.")
        XCTAssertEqual(detail(found, "custom_eas[0].warning_threshold"),
                       "warning_threshold (90) is above critical_threshold (80), so the "
                       + "warning band never applies.")
        XCTAssertEqual(try rows("thresholds:\n  warning_disk_percent: 80\n"
                                + "  critical_disk_percent: 90\n  stale_device_days: 30\n"), [])
    }

    func testACustomEAKeyThatDoesNotApplyToItsTypeIsNamed() throws {
        let found = try rows("""
        custom_eas:
          - name: A
            column: ca
            type: boolean
            true_value: "Yes"
            warning_threshold: 80
            current_versions: ["15"]
          - {name: B, column: cb, type: text, warning_days: 30, true_value: "x"}
          - {name: C, column: cc, type: percentage, warning_threshold: 70, critical_threshold: 90}
          - {name: D, column: cd, type: date, warning_days: 30, current_versions: []}
        """)
        XCTAssertEqual(titles(found), [
            "custom_eas[0].warning_threshold", "custom_eas[0].current_versions",
            "custom_eas[1].warning_days",
        ])
        XCTAssertEqual(found.first?.detail,
                       "warning_threshold applies to percentage extension attributes, and this "
                       + "one is boolean. The app ignores it.")
    }

    func testAlertRulesWithoutAnEnabledKeyAndANonNumericLookbackAreNamed() throws {
        let rules = """
          rules:
            - {metric: patch_pct, when: drops_more_than, threshold: 5, lookback_days: abc}
            - {metric: patch_pct, when: drops_more_than, threshold: 5, lookback_days: "14"}
            - {metric: patch_pct, when: below, threshold: 90, lookback_days: abc}
        """
        let found = try rows("alerts:\n" + rules)
        XCTAssertEqual(titles(found), ["alerts.enabled", "alerts.rules[0].lookback_days"])
        XCTAssertEqual(detail(found, "alerts.enabled"),
                       "alerts.rules lists 3 rules but alerts.enabled is not set. Alerts are off "
                       + "unless it is true, so no rule runs.")
        XCTAssertEqual(detail(found, "alerts.rules[0].lookback_days"),
                       "\"abc\" is not a whole number of days. The app uses 7.")
        XCTAssertEqual(titles(try rows("alerts:\n  enabled: false\n" + rules)),
                       ["alerts.rules[0].lookback_days"], "an explicit false is a choice")
    }

    /// The app writes these keys itself, so a file it wrote must say nothing about them.
    func testTheConfigScreensOwnSaveOfTheDefaultStateStatesNothing() throws {
        try withWorkspacesRoot { root, _ in
            _ = try ConfigService.save(
                profile: "values", state: ConfigState.defaultState, existingDocument: nil,
                workspaceRoot: root)
            let url = try ConfigService.configURL(for: "values", workspaceRoot: root)
            let config = try ConfigLoader.load(from: url)
            XCTAssertEqual(
                ConfigDoctorService.valueRows(profile: "values", config: config,
                                              workspaceRoot: root), [])
        }
    }

    func testEveryFileScaffoldWritesStatesNothing() throws {
        let result = ScaffoldService.ScaffoldResult(
            family: .computers, columns: ["computer_name": "Computer Name"],
            complianceColumns: [:], mobileColumns: [:])
        try withWorkspacesRoot { root, workspace in
            let url = workspace.appendingPathComponent("config.yaml")
            for write in [
                { try ScaffoldService.writeConfig(to: url, result: result, profile: "values") },
                { try ScaffoldService.writeMinimalConfig(to: url, profile: "values") },
            ] {
                try write()
                let config = try ConfigLoader.load(from: url)
                XCTAssertEqual(
                    ConfigDoctorService.valueRows(profile: "values", config: config,
                                                  workspaceRoot: root), [])
            }
        }
    }

    func testSchoolAndProtectBothEnabledStateWhichOneTheCollectUses() throws {
        let found = try rows("school_cli: {enabled: true}\nprotect: {enabled: true}\n")
        XCTAssertEqual(titles(found), ["school_cli.enabled"])
        XCTAssertEqual(found.first?.detail,
                       "school_cli.enabled and protect.enabled are both true. The app collects "
                       + "Jamf School only and never runs Protect for this profile.")
        XCTAssertEqual(try rows("school_cli: {enabled: true}\nprotect: {enabled: false}\n"), [])
        XCTAssertEqual(try rows("protect: {enabled: true}\n"), [])
    }

    func testNoRowIsAFailAndEveryIdIsUnique() throws {
        let found = try rows("""
        notify: {enabled: true, provider: x, detail: y}
        retention: {enabled: true, mode: z, snapshot_keep_days: 0}
        shared_workspace: {claim_ttl_minutes: 1}
        thresholds: {stale_device_days: 0, warning_disk_percent: 95, critical_disk_percent: 90}
        alerts:
          rules:
            - {metric: patch_pct, when: below, threshold: 90}
        school_cli: {enabled: true}
        protect: {enabled: true}
        """)
        XCTAssertGreaterThan(found.count, 8)
        XCTAssertFalse(found.contains { $0.severity == .fail },
                       "only .fail reaches Run History, and a typo must not turn a run red")
        XCTAssertEqual(Set(found.map(\.id)).count, found.count)
    }

    func testTheShippedExampleConfigStatesNothingItHasToReplace() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var example: URL?
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("config.example.yaml")
            if FileManager.default.fileExists(atPath: candidate.path) { example = candidate; break }
            dir = dir.deletingLastPathComponent()
        }
        guard let example else { throw XCTSkip("config.example.yaml not found") }
        XCTAssertEqual(try rows(String(contentsOf: example, encoding: .utf8)), [])
    }

    // MARK: Workspace for the rows that read a folder

    /// Under the home folder: the temp folder resolves under /private, which the path rules
    /// refuse for any absolute path, so an absolute path inside a temp workspace reads as outside.
    private func withWorkspacesRoot(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jrc-test-values-\(UUID().uuidString)", isDirectory: true)
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
