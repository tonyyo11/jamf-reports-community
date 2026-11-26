import XCTest
@testable import JamfReports

/// The Protect agents findings in the workbook (three Protect Computers columns, a block on
/// Protect Overview) and the HTML report (a section and Needs attention sentences).
final class ProtectAgentReportTests: XCTestCase {

    private var root: URL!
    private var dataDir: URL!
    private let anchor = GoldenFleetClock.anchorNoon()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = GoldenFleetWorkspace.freshRoot()
        dataDir = root.appendingPathComponent("data", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func hoursBefore(_ hours: Double) -> Date { anchor.addingTimeInterval(-hours * 3_600) }

    /// Published 101 two days before the computers snapshot, installer 5.1 three days before.
    private func writeBaselines() throws {
        _ = try GoldenFleetWorkspace.writeSnapshot(
            kind: ReportEngine.protectSignatureVersionsKind, dataDir: dataDir,
            at: hoursBefore(1),
            rows: [["id": "101", "created": ISO8601Time.string(hoursBefore(48))]])
        _ = try GoldenFleetWorkspace.writeSnapshot(
            kind: ReportEngine.protectInstallerKind, dataDir: dataDir, at: hoursBefore(72),
            rows: [["installerVersion": "5.1"]])
    }

    private func computer(
        _ host: String, signatures: Int, version: String, connected: Bool
    ) -> [String: Any] {
        var row: [String: Any] = [
            "hostname": host, "signaturesVersion": signatures, "version": version,
            "connectionStatus": connected ? "Connected" : "Disconnected",
        ]
        if !connected { row["lastDisconnection"] = ISO8601Time.string(hoursBefore(30)) }
        return row
    }

    private func cells(_ dash: CoreDashboard, _ sheet: String) throws -> [Int: [Int: String]] {
        let cells = try XCTUnwrap(dash.workbook.sheet(named: sheet)?.dedupedCells)
        var grid: [Int: [Int: String]] = [:]
        for cell in cells {
            switch cell.value {
            case .string(let text): grid[cell.row, default: [:]][cell.col] = text
            case .int(let number): grid[cell.row, default: [:]][cell.col] = String(number)
            default: break
            }
        }
        return grid
    }

    // MARK: - Workbook

    func testProtectComputersEndsWithTheThreeFindings() throws {
        try writeBaselines()
        _ = try GoldenFleetWorkspace.writeSnapshot(
            kind: "protect-computers", dataDir: dataDir, at: anchor,
            rows: [computer("behind", signatures: 100, version: "5.0", connected: false),
                   computer("current", signatures: 101, version: "5.1", connected: true),
                   ["hostname": "bare"]])
        let dash = CoreDashboard(config: ReportConfig(), dataDir: dataDir, workbook: Workbook())
        try dash.writeProtectComputers()
        let grid = try cells(dash, "Protect Computers")
        XCTAssertEqual(grid[3]?[9], "Last Disconnection Reason", "existing columns stay put")
        XCTAssertEqual([grid[3]?[10], grid[3]?[11], grid[3]?[12]],
                       ["Signatures Behind", "Agent Behind", "Disconnected Over 24 h"])
        XCTAssertEqual([grid[4]?[10], grid[4]?[11], grid[4]?[12]], ["Yes", "Yes", "Yes"])
        XCTAssertEqual([grid[5]?[10], grid[5]?[11], grid[5]?[12]], ["No", "No", "No"])
        XCTAssertEqual([grid[6]?[10], grid[6]?[11], grid[6]?[12]], ["", "", ""],
                       "a Mac that reports nothing is blank, not No")
    }

    /// The tab reads a flat `protect-computers_<stamp>.json` beside the folder when it is newer;
    /// the findings must be measured on that same file, never paired with another one's rows.
    func testTheFindingsComeFromTheFileTheTabWrites() throws {
        try writeBaselines()
        _ = try GoldenFleetWorkspace.writeSnapshot(
            kind: "protect-computers", dataDir: dataDir, at: hoursBefore(5),
            rows: [computer("old", signatures: 101, version: "5.1", connected: true)])
        let flat = dataDir.appendingPathComponent(
            "protect-computers_\(GoldenFleetClock.stamp(anchor)).json")
        try JSONSerialization.data(withJSONObject: [
            computer("new", signatures: 100, version: "5.0", connected: true),
        ]).write(to: flat)
        let dash = CoreDashboard(config: ReportConfig(), dataDir: dataDir, workbook: Workbook())
        try dash.writeProtectComputers()
        let grid = try cells(dash, "Protect Computers")
        XCTAssertEqual(grid[4]?[0], "new")
        XCTAssertEqual(grid[4]?[10], "Yes", "measured on the flat file's own row")
    }

    func testProtectOverviewCarriesTheBlockEvenWithNoOverviewRows() throws {
        try writeBaselines()
        _ = try GoldenFleetWorkspace.writeSnapshot(
            kind: "protect-computers", dataDir: dataDir, at: anchor,
            rows: [computer("behind", signatures: 100, version: "5.0", connected: false)])
        let dash = CoreDashboard(config: ReportConfig(), dataDir: dataDir, workbook: Workbook())
        try dash.writeProtectOverview()
        let texts = try cells(dash, "Protect Overview").values.flatMap(\.values)
        XCTAssertTrue(texts.contains("Protect agents"))
        XCTAssertTrue(texts.contains("Signatures behind"))
        XCTAssertTrue(texts.contains("1 of 1"))
        XCTAssertTrue(texts.contains(ProtectAgentHealth.heldBackNote))
    }

    func testProtectOverviewWithNeitherSnapshotIsStillSkipped() {
        let dash = CoreDashboard(config: ReportConfig(), dataDir: dataDir, workbook: Workbook())
        XCTAssertThrowsError(try dash.writeProtectOverview())
    }

    // MARK: - HTML

    private func report() -> HtmlReport {
        HtmlReport(config: ReportConfig().withDefaults(), dataDir: dataDir)
    }

    func testTheSectionSaysWhyItIsLeftOut() {
        XCTAssertEqual(report().buildProtectAgents(.notConfigured).omission,
                       "not configured: protect.enabled is off in config.yaml")
        XCTAssertEqual(report().buildProtectAgents(.unreadable).omission,
                       "the newest protect-computers file could not be read")
        XCTAssertEqual(report().buildProtectAgents(.notCollected).omission,
                       "no protect-computers snapshot collected")
        XCTAssertEqual(report().loadProtectAgents().health, nil, "Protect is off by default")
    }

    func testTheSectionListsEachFindingAndEscapesProtectText() throws {
        let gone = ISO8601Time.string(hoursBefore(30))
        let rows = try JSONDecoder().decode([ProtectComputerRow].self, from: Data("""
        [{"connectionStatus":"Disconnected","lastDisconnection":"\(gone)",
          "lastDisconnectionReason":"<b>x</b>"}]
        """.utf8))
        let health = ProtectAgentHealth.evaluate(
            computers: rows, published: .unavailable(.noPublishedVersions),
            installer: .unavailable(.noInstallerVersion), now: anchor)
        let html = report().buildProtectAgents(.health(health)).html
        XCTAssertTrue(html.contains("id=\"protect-agents\""))
        XCTAssertTrue(html.contains("Protect published no signature versions"))
        XCTAssertTrue(html.contains("1 of 1"))
        XCTAssertTrue(html.contains("&lt;b&gt;x&lt;/b&gt;: 1"))
        XCTAssertFalse(html.contains("<b>x</b>"))
        XCTAssertFalse(html.contains(ProtectAgentHealth.heldBackNote),
                       "the held-back note explains a measured agent finding only")
    }

    func testNeedsAttentionHasOneSentencePerFindingAboveZero() {
        let health = ProtectAgentHealth(
            macs: [], signaturesBehind: .init(share: .init(met: 2, of: 5), baseline: nil,
                                              notEvaluated: nil),
            agentBehind: .init(share: .init(met: 0, of: 5), baseline: nil, notEvaluated: nil),
            disconnected: .unavailable(.noCollectionTime), disconnectedReasons: [],
            distinctReasons: 0, disconnectedTimeUnknown: 0)
        XCTAssertEqual(HtmlReport.protectAgentSentences(health),
                       ["2 Macs hold Protect signatures older than the newest published version."])
        XCTAssertEqual(HtmlReport.protectAgentSentences(nil), [])
    }

    func testTheTemplatesThatShowProtectAlertsShowProtectAgents() {
        for template in [FullInstanceTemplate() as any ReportTemplate, SecurityPostureTemplate()] {
            XCTAssertTrue(template.htmlSections.contains(.protectAgents), "\(template)")
        }
        XCTAssertEqual(HtmlDetailGroup.security.members.filter { $0 == .protectAgents }.count, 1)
    }
}
