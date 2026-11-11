import XCTest
@testable import JamfReports

/// The report surfaces of a site-limited login: every one reads the collect's persisted
/// verdict and shows something only for `limited`.
final class SiteScopeReportTests: XCTestCase {
    private var root: URL!
    private let profile = "scoped"
    private let limited = SiteScope.limited(
        computers: .init(seen: 1, total: 2), mobileDevices: nil)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-SiteScopeReport-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func persist(_ scope: SiteScope, dataDir: URL? = nil) throws {
        let dir = try dataDir ?? WorkspacePaths.dataDir(for: profile)
        try SiteScopeRecord(scope: scope, collectedAt: Date(), profile: profile)
            .save(stateDir: dir.appendingPathComponent("state", isDirectory: true))
    }

    // MARK: - HTML

    private func needsAttention(_ scope: SiteScope) throws -> String {
        let dataDir = root.appendingPathComponent("html-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try persist(scope, dataDir: dataDir)
        let report = HtmlReport(config: try ConfigLoader.loadFromString(""), dataDir: dataDir)
        return report.buildNeedsAttention(report.loadInputs(for: []), shown: [])
    }

    func testTheHTMLReportLeadsNeedsAttentionWithTheScopeWithNoDailySummary() throws {
        let html = try needsAttention(
            .limited(computers: .init(seen: 0, total: 5), mobileDevices: .init(seen: 0, total: 1)))
        XCTAssertTrue(html.contains(
            "This report covers 0 of 5 managed computers, and 0 of 1 managed mobile device "
            + "in Jamf Pro: the login is limited to some sites."), html)
        XCTAssertFalse(html.contains("Nothing needs attention"))
    }

    func testTheScopeSentenceIsTheFirstItemEvenWithAnotherCondition() throws {
        let dataDir = root.appendingPathComponent("html-order", isDirectory: true)
        try persist(limited, dataDir: dataDir)
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "computers", dataDir: dataDir, at: GoldenFleetClock.anchorNoon(),
            rows: [["id": "1", "general": [
                "name": "Old", "lastCheckIn": "2020-01-01T00:00:00Z",
                "reportDate": "2020-01-01T00:00:00Z"], "hardware": ["serialNumber": "S1"]]])
        let report = HtmlReport(config: try ConfigLoader.loadFromString(""), dataDir: dataDir)
        let items = report.attentionItems(report.loadInputs(for: [.interventionList]), shown: [])
        XCTAssertGreaterThan(items.count, 1, "a stale Mac adds a second item")
        XCTAssertTrue(items[0].text.hasPrefix("This report covers"), "\(items.map(\.text))")
    }

    func testTheHTMLReportSaysNothingForAWholeOrUnknownLogin() throws {
        for scope in [SiteScope.whole, .unknown, .notApplicable] {
            XCTAssertFalse(try needsAttention(scope).contains("limited to some sites"))
        }
    }

    // MARK: - Workbook

    private func tabs(
        limited isLimited: Bool?
    ) async throws -> (tabs: [XLSXReader.Tab], folder: URL) {
        let dataDir = root.appendingPathComponent("wb-\(isLimited.map(String.init) ?? "none")")
            .appendingPathComponent("jamf-cli-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        for kind in ["overview", "security", "patch-status", "policy-status", "computers-list",
                     "classic-computer-groups", "mobile-devices-list"] {
            try TestFixtures.copyDir("jamf-cli-data/\(kind)",
                                     to: dataDir.appendingPathComponent(kind, isDirectory: true))
        }
        if let isLimited { try persist(isLimited ? limited : .whole, dataDir: dataDir) }
        let out = dataDir.deletingLastPathComponent().appendingPathComponent("out/report.xlsx")
        try await ReportEngine(config: try ConfigLoader.loadFromString(""), dataDir: dataDir)
            .generate(outputURL: out, csvFolder: true, locateJamfCLI: { nil })
        return (try XLSXReader.tabs(of: out), ReportEngine.csvFolderURL(besideWorkbook: out))
    }

    /// Tabs whose body varies run to run: the Cover holds a run ID and timestamps (compared as a
    /// set without them); Mobile Fleet Summary lists model rows that tie on count in a
    /// different order and members, so only its row count is compared.
    private let unstableTabs: Set<String> = ["Cover", "Mobile Fleet Summary"]

    func testALimitedLoginPutsTheSentenceInTheHeaderOfEveryTabAndMovesNothing() async throws {
        let plain = try await tabs(limited: nil).tabs
        let scoped = try await tabs(limited: true).tabs
        XCTAssertEqual(plain.map(\.name), scoped.map(\.name))
        let sentence = "This report covers 1 of 2 managed computers in Jamf Pro: "
            + "the login is limited to some sites."
        for (before, after) in zip(plain, scoped) {
            let noteRow = before.name == "Cover" ? 1 : 2
            XCTAssertEqual(before.rows.count, after.rows.count, before.name)
            guard after.rows.count > noteRow else { continue }
            if case .text(let text) = after.rows[noteRow][0] {
                XCTAssertTrue(text.hasPrefix(sentence), "\(before.name): \(text)")
            } else {
                XCTFail("\(before.name) row \(noteRow + 1) has no sentence")
            }
            func body(_ tab: XLSXReader.Tab) -> [String] {
                tab.rows.enumerated().filter { $0.offset != noteRow }.map { "\($0.element)" }
                    .filter { !$0.contains("Run ID") && !$0.contains("Generated") }
            }
            if before.name == "Mobile Fleet Summary" {
                continue  // only its row count is stable
            } else if unstableTabs.contains(before.name) {
                XCTAssertEqual(body(before).sorted(), body(after).sorted(), before.name)
            } else {
                // Row 2 holds a timestamp, so skip it; every other row stays where it was.
                let skip = { (tab: XLSXReader.Tab) in
                    body(tab).enumerated().filter { $0.offset != 1 }.map(\.element)
                }
                XCTAssertEqual(skip(before), skip(after), before.name)
            }
        }
    }

    func testAWholeLoginLeavesTheHeaderAsItWas() async throws {
        let plain = try await tabs(limited: nil).tabs
        let whole = try await tabs(limited: false).tabs
        for (before, after) in zip(plain, whole) {
            XCTAssertEqual(before.rows.count, after.rows.count, before.name)
            for r in 0..<min(3, before.rows.count) where before.name != "Cover" {
                if r == 1 { continue }  // the subtitle holds a timestamp
                XCTAssertEqual("\(before.rows[r])", "\(after.rows[r])", "\(before.name) \(r)")
            }
        }
    }

    /// The CSV folder serializes the same cells, so each CSV carries the sentence in its
    /// header rows when limited and none when whole.
    func testTheCSVFolderInheritsTheSentenceOnlyWhenLimited() async throws {
        func headerText(_ folder: URL) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: folder.path)
                .filter { $0.hasSuffix(".csv") }.sorted().map { name in
                    try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
                        .components(separatedBy: "\n").prefix(3).joined(separator: "\n")
                }
        }
        let limitedHeaders = try headerText(try await tabs(limited: true).folder)
        XCTAssertFalse(limitedHeaders.isEmpty)
        for header in limitedHeaders {
            XCTAssertTrue(header.contains("limited to some sites"), header)
        }
        for header in try headerText(try await tabs(limited: false).folder) {
            XCTAssertFalse(header.contains("limited to some sites"), header)
        }
    }

    func testFleetDriftKeepsItsLargeChangeNoteAfterTheScope() {
        let ws = Worksheet(name: "Fleet Drift")
        ws.siteScopeNote = "Scope."
        ws.writeSheetHeader(title: "t", subtitle: "s")
        ws.writeSiteScopeNote(row: 2, extra: "Large change: x")
        let cells = ws.cells.filter { $0.row == 2 && $0.col == 0 }
        XCTAssertEqual(cells.count, 1)
        guard case .string(let text) = cells[0].value else { return XCTFail("no text") }
        XCTAssertEqual(text, "Scope. Large change: x")
    }

    // MARK: - Webhooks

    func testTheScopeFactIsFullDetailOnly() {
        let hit = MetricAlertHit(
            metricLabel: "Stale Macs", ruleDescription: "above 10", current: 12, prior: nil,
            message: "12 is above 10")
        for detail in [NotifyConfig.Detail.full, .minimal] {
            let success = successFacts(
                detail: detail, profile: "p", mode: .snapshotOnly, artifact: nil,
                sheetFailures: 0, scope: "1 of 2 managed computers")
            let alert = alertFacts(
                detail: detail, profile: "p", hits: [hit], scope: "1 of 2 managed computers")
            for facts in [success, alert] {
                XCTAssertEqual(
                    facts.contains {
                        $0.label == "Scope" && $0.value == "1 of 2 managed computers"
                    },
                    detail == .full)
            }
        }
    }

    func testTheDigestReadsThePersistedVerdict() throws {
        try persist(limited)
        XCTAssertEqual(SiteScope.persisted(profile: profile).summary, "1 of 2 managed computers")
        try persist(.whole)
        XCTAssertNil(SiteScope.persisted(profile: profile).summary)
    }

    // MARK: - Report groups

    private func fleetModel() throws -> FleetWorkbookModel {
        let summary = DailySummary(
            date: "2026-06-06", totalDevices: 100, fileVaultPct: 90, compliancePct: nil,
            staleCount: 1, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil)
        return try XCTUnwrap(FleetWorkbookModel.build(
            groupName: "G", summariesByProfile: [(profile: "a", summaries: [summary])],
            lookbackDays: 7, timestamp: "2026-06-06"))
    }

    func testTheFleetNotesNameOnlyLimitedProfiles() throws {
        try persist(limited)
        let other = "fine"
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Jamf-Reports/\(other)"),
            withIntermediateDirectories: true)
        try persist(.whole, dataDir: try WorkspacePaths.dataDir(for: other))
        XCTAssertEqual(
            FleetReportEmitter.siteScopeNotes(profiles: [profile, other]),
            ["Note: scoped sees 1 of 2 managed computers (site-limited login)"])
    }

    func testTheFleetWorkbookNotesSitBelowTheMetricsAndMoveOnlyTheChart() throws {
        let model = try fleetModel()
        let plain = try XCTUnwrap(
            FleetWorkbookEmitter.workbook(for: model).sheet(named: "Fleet Summary"))
        let notes = ["Note: a sees 1 of 2 managed computers (site-limited login)", "Note: b"]
        let noted = try XCTUnwrap(
            FleetWorkbookEmitter.workbook(for: model, notes: notes).sheet(named: "Fleet Summary"))
        let lastMetricRow = 3 + model.universal.count
        func text(_ ws: Worksheet, _ row: Int) -> String? {
            ws.cells.first { $0.row == row && $0.col == 0 }.flatMap {
                if case .string(let value) = $0.value { return value }
                return nil
            }
        }
        for (i, note) in notes.enumerated() {
            XCTAssertEqual(text(noted, lastMetricRow + 2 + i), note)
            XCTAssertNil(text(plain, lastMetricRow + 2 + i))
        }
        let metricCells = { (ws: Worksheet) in
            ws.cells.filter { $0.row <= lastMetricRow }.map { "\($0.row),\($0.col),\($0.value)" }
        }
        XCTAssertEqual(metricCells(plain), metricCells(noted))
        let chart = try XCTUnwrap(plain.imageEmbeds.first?.row)
        XCTAssertEqual(noted.imageEmbeds.first?.row, chart + notes.count)
    }
}
