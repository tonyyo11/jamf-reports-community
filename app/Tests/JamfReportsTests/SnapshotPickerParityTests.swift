import Foundation
import XCTest
@testable import JamfReports

/// Every reader must resolve "newest snapshot" the same way, or the workbook,
/// the HTML report and the Devices screen report different days from one
/// workspace with no error shown.
///
/// The fixture is the synced-storage failure verbatim: the real newest snapshot
/// (`…20260902T060000.json`) carries the OLDEST mtime, while a superseded
/// snapshot and a provider's conflict copy both carry fresh mtimes — which is
/// exactly what a file provider produces when it materializes files in an order
/// unrelated to when they were collected.
final class SnapshotPickerParityTests: XCTestCase {

    private var root: URL!
    private let profile = "pickerparity"

    /// The one file every picker must choose.
    private let newestStamp = "20260902T060000"
    private let olderStamp = "20260901T060000"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jrc-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: true
        )
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)

        try seedKind("groups", body: groupsJSON)
        try seedKind("computers", body: computersJSON)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private var workspace: URL {
        root.appendingPathComponent(profile, isDirectory: true)
    }

    private var dataDir: URL {
        workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
    }

    // MARK: - Fixture

    /// Writes the three-file trap into `<dataDir>/<kind>/`.
    /// `body(marker)` renders that kind's payload carrying a marker string, so a
    /// test can name which file a picker actually read.
    private func seedKind(_ kind: String, body: (String) -> String) throws {
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        try write(body("NEWEST"),
                  to: dir.appendingPathComponent("\(kind)_\(newestStamp).json"),
                  modified: now.addingTimeInterval(-3600))
        try write(body("OLDER"),
                  to: dir.appendingPathComponent("\(kind)_\(olderStamp).json"),
                  modified: now.addingTimeInterval(-10))
        // OneDrive/Finder conflict copy of the newest file: same stem plus " 2".
        try write(body("CONFLICT"),
                  to: dir.appendingPathComponent("\(kind)_\(newestStamp) 2.json"),
                  modified: now)
    }

    private func write(_ text: String, to url: URL, modified: Date) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: url.path
        )
    }

    private func groupsJSON(marker: String) -> String {
        """
        [{"groupName": "\(marker)", "groupType": "Smart", \
        "groupJamfProId": "1", "membershipCount": 0}]
        """
    }

    private func computersJSON(marker: String) -> String {
        """
        [{"general": {"name": "\(marker)", "id": "1"}, \
        "hardware": {"serialNumber": "\(marker)"}}]
        """
    }

    // MARK: - The three readers

    /// `CoreDashboard.loadLatestJSONData` feeds every xlsx sheet.
    func testWorkbookReadsTheFilenameNewestSnapshot() throws {
        let workbook = Workbook()
        let dash = CoreDashboard(config: ReportConfig(), dataDir: dataDir, workbook: workbook)
        try dash.writeGroupHygiene()

        let sheet = try XCTUnwrap(workbook.sheet(named: "Group Hygiene"))
        let text = sheet.dedupedCells.compactMap { cell -> String? in
            guard case let .string(s) = cell.value else { return nil }
            return s
        }
        XCTAssertTrue(text.contains("NEWEST"),
                      "the workbook must read the filename-newest snapshot")
        XCTAssertFalse(text.contains("OLDER"), "a fresher mtime must not promote an older day")
        XCTAssertFalse(text.contains("CONFLICT"), "a sync conflict copy is never data")
    }

    /// `HtmlReport.loadJSONList` feeds every HTML section.
    func testHTMLReportReadsTheFilenameNewestSnapshot() {
        let report = HtmlReport(config: ReportConfig().withDefaults(), dataDir: dataDir)
        let rows = report.loadJSONList(kinds: ["groups"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["groupName"] as? String, "NEWEST")
    }

    /// `DeviceInventoryService.load` feeds the Devices and Outreach screens.
    func testDevicesScreenReadsTheFilenameNewestSnapshot() {
        let snapshot = DeviceInventoryService.load(profile: profile, demoMode: false)
        XCTAssertEqual(snapshot.devices.count, 1)
        XCTAssertEqual(snapshot.devices.first?.serial, "NEWEST")
    }

    /// The point of the parity test: all three agree on one file. Asserted
    /// together so a future change that fixes one picker and not the others
    /// fails here even if each test above is read in isolation.
    func testAllThreeReadersAgree() throws {
        let workbook = Workbook()
        try CoreDashboard(config: ReportConfig(), dataDir: dataDir, workbook: workbook)
            .writeGroupHygiene()
        let sheetNames = try XCTUnwrap(workbook.sheet(named: "Group Hygiene"))
            .dedupedCells.compactMap { cell -> String? in
                guard case let .string(s) = cell.value else { return nil }
                return ["NEWEST", "OLDER", "CONFLICT"].contains(s) ? s : nil
            }
        let htmlName = HtmlReport(config: ReportConfig().withDefaults(), dataDir: dataDir)
            .loadJSONList(kinds: ["groups"]).first?["groupName"] as? String
        let deviceName = DeviceInventoryService.load(profile: profile, demoMode: false)
            .devices.first?.serial

        XCTAssertEqual(sheetNames, ["NEWEST"])
        XCTAssertEqual(htmlName, "NEWEST")
        XCTAssertEqual(deviceName, "NEWEST")
    }

    // MARK: - csv-inbox is hand-fed, so a rejection there must be explained

    /// The conflict-copy filter is correct for JSON snapshots, but csv-inbox is
    /// a folder the operator drops files into — and Finder names a second
    /// download "Computers 2.csv". Rejecting that silently leaves the screen
    /// with no CSV source and nothing to act on, so it has to be named the way
    /// the age bound names an expired export.
    func testConflictNamedInboxCSVIsNamedInAWarningNotSilentlyDropped() throws {
        let inbox = workspace.appendingPathComponent("csv-inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try write("""
        Computer Name,Serial Number
        Mac-1,INBOX001
        """, to: inbox.appendingPathComponent("Computers 2.csv"), modified: Date())

        let snapshot = DeviceInventoryService.load(profile: profile, demoMode: false)
        let warning = snapshot.warnings.first { $0.contains("Computers 2.csv") }
        let text = try XCTUnwrap(warning, "a rejected inbox CSV must be reported, not dropped")
        XCTAssertTrue(text.lowercased().contains("rename"),
                      "the warning must say how to make the file readable")
        XCTAssertFalse(
            snapshot.sourceFiles.contains { $0.contains("Computers 2.csv") },
            "the file is still not read — the warning is the remedy, not a load"
        )
    }

    /// A normally-named inbox CSV is unaffected by the filter.
    func testNormallyNamedInboxCSVLoadsWithNoWarning() throws {
        let inbox = workspace.appendingPathComponent("csv-inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try write("""
        Computer Name,Serial Number
        Mac-1,INBOX001
        """, to: inbox.appendingPathComponent("Computers.csv"), modified: Date())

        let snapshot = DeviceInventoryService.load(profile: profile, demoMode: false)
        XCTAssertTrue(snapshot.sourceFiles.contains { $0.contains("Computers.csv") })
        XCTAssertFalse(snapshot.warnings.contains { $0.contains("Computers.csv") })
    }

    // MARK: - Per-kind freshness dates

    /// `sourceDates` feeds the freshness chips, so it must date a snapshot by
    /// the collect that produced it, not by the sync that downloaded it.
    func testSourceDatesUseTheFilenameStampForSnapshotKinds() throws {
        let dir = dataDir.appendingPathComponent("device-compliance", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        try write("[]",
                  to: dir.appendingPathComponent("device-compliance_20240102T030000.json"),
                  modified: now)

        let dates = DeviceInventoryService.sourceDates(profile: profile, demoMode: false)
        let resolved = try XCTUnwrap(dates["device-compliance"])
        XCTAssertLessThan(resolved, now.addingTimeInterval(-86_400),
                          "a 2024-01-02 stamp must not be reported as today's mtime")
    }

    // MARK: - The rule itself

    /// Guards against the exclusion being widened into "anything with a digit
    /// suffix": an unstamped file is still selectable when nothing better
    /// exists, which is what keeps the inventory CSV path working.
    func testUnstampedFileIsStillChosenWhenItIsTheOnlyCandidate() throws {
        let dir = root.appendingPathComponent("unstamped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let only = dir.appendingPathComponent("inventory.json")
        try write("[]", to: only, modified: Date())

        XCTAssertEqual(FileManager.newestSnapshot(among: [only])?.lastPathComponent,
                       "inventory.json")
    }

    /// Among unstamped files only, mtime still decides — the pre-2.7.0
    /// behaviour for non-snapshot directories has to survive.
    func testMTimeStillOrdersFilesThatCarryNoStamp() throws {
        let dir = root.appendingPathComponent("mtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("a.json")
        let new = dir.appendingPathComponent("b.json")
        try write("[]", to: old, modified: Date().addingTimeInterval(-3600))
        try write("[]", to: new, modified: Date())

        XCTAssertEqual(FileManager.newestSnapshot(among: [old, new])?.lastPathComponent, "b.json")
    }

    /// `manifest.json` is written after the snapshot it describes, so it is the
    /// newest `.json` in every kind directory by mtime.
    func testManifestIsNeverSelectable() throws {
        let dir = root.appendingPathComponent("manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let snapshot = dir.appendingPathComponent("groups_\(newestStamp).json")
        let manifest = dir.appendingPathComponent("manifest.json")
        try write("[]", to: snapshot, modified: Date().addingTimeInterval(-600))
        try write("{}", to: manifest, modified: Date())

        XCTAssertEqual(FileManager.newestJSONFile(in: dir)?.lastPathComponent,
                       "groups_\(newestStamp).json")
        XCTAssertEqual(FileManager.newestSnapshotFile(in: dir)?.lastPathComponent,
                       "groups_\(newestStamp).json")
    }

    /// The two public names must not be allowed to drift apart again.
    func testBothDirectoryHelpersReturnTheSameFile() {
        let kindDir = dataDir.appendingPathComponent("groups", isDirectory: true)
        XCTAssertEqual(FileManager.newestJSONFile(in: kindDir),
                       FileManager.newestSnapshotFile(in: kindDir))
        XCTAssertEqual(FileManager.newestJSONFile(in: kindDir)?.lastPathComponent,
                       "groups_\(newestStamp).json")
    }

    /// A caption reading mtime would report the sync download, not the collect.
    func testSnapshotDatePrefersTheFilenameStampOverMTime() throws {
        let dir = root.appendingPathComponent("date-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A deliberately long-past stamp so "today's mtime" cannot coincide with it.
        let stamped = dir.appendingPathComponent("groups_20240102T030000.json")
        let restamped = Date()
        try write("[]", to: stamped, modified: restamped)

        let resolved = try XCTUnwrap(FileManager.snapshotDate(of: stamped))
        XCTAssertLessThan(resolved, restamped.addingTimeInterval(-86_400),
                          "a 2024-01-02 stamp must not resolve to today's mtime")
    }

    // MARK: - The two readers the parity table did not name

    /// `ReportEngine.loadLatestSnapshotData` feeds `buildSummaryFromCLI`, i.e.
    /// the day's `summary.json` — Trends and the freshness banner. It excluded
    /// `manifest.json` and nothing else, and a conflict copy carries the SAME
    /// filename stamp as its original, so the tie fell to enumeration order.
    func testDailySummaryReadsTheFilenameNewestSnapshot() throws {
        try seedSecurityTrap()
        let summaries = root.appendingPathComponent("summaries", isDirectory: true)

        let outcome = ReportEngine(config: ReportConfig(), dataDir: dataDir)
            .emitSummaryJSON(summariesDir: summaries)
        XCTAssertEqual(outcome, .wrote)

        let written = try FileManager.default.contentsOfDirectory(
            at: summaries, includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(written.first { $0.lastPathComponent.hasPrefix("summary_") })
        XCTAssertEqual(try SummaryJSONParser.parse(file).totalDevices, 100,
                       "the digest must read the filename-newest security snapshot")
    }

    /// `HtmlReport.loadProtectInsightSnapshots` ordered the whole series by raw
    /// mtime with no exclusions, so on a synced volume the drift table could be
    /// mis-ordered and count a conflict copy as an extra day of drift.
    func testProtectInsightSeriesOrdersByStampAndDropsConflictCopies() throws {
        let protectDir = root.appendingPathComponent("protect", isDirectory: true)
        let insights = protectDir.appendingPathComponent("insights", isDirectory: true)
        try FileManager.default.createDirectory(at: insights, withIntermediateDirectories: true)
        let now = Date()
        try write(#"{"marker": "NEWEST"}"#,
                  to: insights.appendingPathComponent("insights_\(newestStamp).json"),
                  modified: now.addingTimeInterval(-3600))
        try write(#"{"marker": "OLDER"}"#,
                  to: insights.appendingPathComponent("insights_\(olderStamp).json"),
                  modified: now.addingTimeInterval(-10))
        try write(#"{"marker": "CONFLICT"}"#,
                  to: insights.appendingPathComponent("insights_\(newestStamp) 2.json"),
                  modified: now)

        let html = HtmlReport(config: ReportConfig().withDefaults(), dataDir: dataDir)
            .buildInsightsDrift(protectDataDir: protectDir)

        XCTAssertFalse(html.contains("CONFLICT"), "a sync conflict copy is never a snapshot")
        let older = try XCTUnwrap(html.range(of: "OLDER"))
        let newest = try XCTUnwrap(html.range(of: "NEWEST"))
        XCTAssertLessThan(older.lowerBound, newest.lowerBound,
                          "the filename-newest snapshot belongs in the Current column")
    }

    /// The same three-file trap in the shape of a security snapshot, so the
    /// device total names which file the digest actually read.
    ///
    /// Stamps are relative to now, not the fixed 2026 pair above: this reader
    /// applies `max_cache_age_hours` (default 168), so a hard-coded stamp would
    /// expire the test a week after it was written.
    private func seedSecurityTrap() throws {
        let dir = dataDir.appendingPathComponent("security", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        let newest = stamp(now.addingTimeInterval(-3600))
        let older = stamp(now.addingTimeInterval(-90_000))
        try write(securityJSON(total: 100),
                  to: dir.appendingPathComponent("security_\(newest).json"),
                  modified: now.addingTimeInterval(-3600))
        try write(securityJSON(total: 50),
                  to: dir.appendingPathComponent("security_\(older).json"),
                  modified: now.addingTimeInterval(-10))
        try write(securityJSON(total: 7),
                  to: dir.appendingPathComponent("security_\(newest) 2.json"),
                  modified: now)
    }

    /// Canonical snapshot stamp, configured exactly as `CloudStorage` parses it.
    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        return formatter.string(from: date)
    }

    private func securityJSON(total: Int) -> String {
        """
        [{"section": "summary", "data": {"total_devices": \(total), \
        "filevault_encrypted": \(total), "gatekeeper_enabled": \(total), \
        "sip_enabled": \(total), "firewall_enabled": \(total)}}]
        """
    }
}
