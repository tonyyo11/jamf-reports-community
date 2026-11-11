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

    func testTheHTMLReportSaysNothingForAWholeOrUnknownLogin() throws {
        for scope in [SiteScope.whole, .unknown, .notApplicable] {
            XCTAssertFalse(try needsAttention(scope).contains("limited to some sites"))
        }
    }

    // MARK: - Workbook

    private func tabs(limited isLimited: Bool?) async throws -> [XLSXReader.Tab] {
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
        return try XLSXReader.tabs(of: out)
    }

    func testALimitedLoginPutsTheSentenceInTheHeaderOfEveryTabAndMovesNothing() async throws {
        let plain = try await tabs(limited: nil)
        let scoped = try await tabs(limited: true)
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
            // Equal-count ties and the run ID vary between runs, so compare the rows as a set.
            func body(_ tab: XLSXReader.Tab) -> [String] {
                tab.rows.enumerated().filter { $0.offset > 3 }.map { "\($0.element)" }
                    .filter { !$0.contains("Run ID") }.sorted()
            }
            // Its model rows tie on count and come out in a different order each run.
            if before.name != "Mobile Fleet Summary" {
                XCTAssertEqual(body(before), body(after), before.name)
            }
        }
    }

    func testAWholeLoginLeavesTheHeaderAsItWas() async throws {
        let plain = try await tabs(limited: nil)
        let whole = try await tabs(limited: false)
        for (before, after) in zip(plain, whole) {
            XCTAssertEqual(before.rows.count, after.rows.count, before.name)
            for r in 0..<min(3, before.rows.count) where before.name != "Cover" {
                if r == 1 { continue }  // the subtitle holds a timestamp
                XCTAssertEqual("\(before.rows[r])", "\(after.rows[r])", "\(before.name) \(r)")
            }
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

    func testTheFleetCSVAndWorkbookNameEachLimitedProfileAfterTheMetrics() throws {
        try persist(limited)
        let other = "fine"
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Jamf-Reports/\(other)"),
            withIntermediateDirectories: true)
        try persist(.whole, dataDir: try WorkspacePaths.dataDir(for: other))
        let notes = FleetReportEmitter.siteScopeNotes(profiles: [profile, other])
        XCTAssertEqual(
            notes, ["Note: scoped sees 1 of 2 managed computers (site-limited login)"])

        let rollup = FleetRollup.compute(
            groupName: "G",
            current: [DailySummary(
                date: "2026-06-06", totalDevices: 100, fileVaultPct: 90, compliancePct: nil,
                staleCount: 1, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil)],
            previous: [])
        let lines = FleetReportEmitter.csv(for: rollup, notes: notes)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "Metric,Current,Previous,Delta")
        XCTAssertEqual(
            lines.last, "# Note: scoped sees 1 of 2 managed computers (site-limited login)")
        XCTAssertEqual(
            lines.dropLast().filter { $0.hasPrefix("#") }.count, 0, "notes only after the metrics")
        XCTAssertEqual(
            FleetReportEmitter.csv(for: rollup).split(separator: "\n").count, lines.count - 1)
    }
}
