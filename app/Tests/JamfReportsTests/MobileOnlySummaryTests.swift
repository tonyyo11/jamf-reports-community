import XCTest
@testable import JamfReports

/// A fleet with iPads and iPhones and no Macs gets its daily summary, with every Mac figure
/// unmeasured (nil, never 0). A Mac fleet's summary is unchanged. Every device is invented.
final class MobileOnlySummaryTests: XCTestCase {

    private var root: URL!
    private var dataDir: URL!
    private var summariesDir: URL!
    private var engine: ReportEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = GoldenFleetWorkspace.freshRoot()
        dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        summariesDir = root.appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        engine = ReportEngine(config: ReportConfig(), dataDir: dataDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    private var now: Date { Date().addingTimeInterval(-3_600) }

    private func writeMobile(count: Int) throws {
        let rows: [[String: Any]] = (0..<count).map { index in
            ["id": "\(index)", "name": "Device \(index)", "serialNumber": "MSER\(index)",
             "deviceType": "iOS", "hardware": ["model": "iPad Air"]]
        }
        try GoldenFleetWorkspace.writeSnapshot(
            kind: MobileFleetService.deviceKind, dataDir: dataDir, at: now, rows: rows)
    }

    private func writeSecurity(total: Int) throws {
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "security", dataDir: dataDir, at: now,
            rows: GoldenFleetWorkspace.securitySummaryPayload(
                total: total, filevault: total, sip: total, firewall: total, gatekeeper: total))
    }

    private var todayFile: URL {
        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        return summariesDir.appendingPathComponent("summary_\(today).json")
    }

    @discardableResult
    private func emit(_ live: Set<String>? = nil) -> ReportEngine.SummaryEmitOutcome {
        engine.emitSummaryJSON(summariesDir: summariesDir, liveKinds: live)
    }

    private func summary() throws -> DailySummary {
        try XCTUnwrap(SummaryJSONParser.parseDirectory(summariesDir).first)
    }

    private func assertNoMacFigure(_ s: DailySummary, file: StaticString = #filePath,
                                   line: UInt = #line) {
        XCTAssertEqual(s.totalDevices, 0, file: file, line: line)
        let figures: [Double?] = [
            s.fileVaultPct, s.compliancePct, s.osCurrentPct, s.crowdstrikePct, s.patchPct,
            s.sipPct, s.firewallPct, s.gatekeeperPct, s.secureBootPct, s.bootstrapPct,
            s.xprotectPct, s.cvePct, s.mscpScorePct, s.securityScore,
        ]
        XCTAssertTrue(figures.allSatisfy { $0 == nil }, "\(figures)", file: file, line: line)
        XCTAssertNil(s.staleCount, file: file, line: line)
        XCTAssertNil(s.actionItemsP0, file: file, line: line)
        XCTAssertNil(s.actionItemsP1, file: file, line: line)
        XCTAssertNil(s.securityAgentCoverage, file: file, line: line)
        XCTAssertNil(s.mscpBands, file: file, line: line)
        XCTAssertNil(s.complianceIsProxy, file: file, line: line)
        XCTAssertNil(s.stabilityIndex, file: file, line: line)
        XCTAssertNil(s.activeDeviceCount, file: file, line: line)
    }

    // MARK: - The writer

    func testMobileOnlyFleetWithNoComputerSnapshotsWritesASummary() throws {
        try writeMobile(count: 5)

        XCTAssertEqual(emit(["mobile-devices-list"]), .wrote)

        let written = try summary()
        assertNoMacFigure(written)
        XCTAssertEqual(written.mobileDeviceCount, 5)
        XCTAssertEqual(written.source, "jamf-cli")
        XCTAssertEqual(written.collectionSources?[MobileFleetService.deviceKind], "live")
        XCTAssertEqual(written.collectionSources?["security"], "absent")
    }

    func testMobileOnlyFleetWithAnEmptySecurityReportWritesNoPercentOverZero() throws {
        try writeSecurity(total: 0)
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "inventory-summary", dataDir: dataDir, at: now, rows: [])
        try writeMobile(count: 3)

        XCTAssertEqual(emit(), .wrote)

        assertNoMacFigure(try summary())
        XCTAssertEqual(try summary().mobileDeviceCount, 3)
        let json = try String(contentsOf: todayFile, encoding: .utf8)
        XCTAssertFalse(json.contains("nan") || json.contains("inf"), json)
    }

    func testMobileOnlyWriteIsNotAPartialCollectOutcome() throws {
        try writeMobile(count: 2)
        let outcome = emit()
        XCTAssertEqual(outcome, .wrote)
        XCTAssertNil(outcome.partialReason, "no `[partial] summary not written` line")
    }

    func testNeitherMacsNorMobileWritesNothingAndKeepsThePartialReason() throws {
        try writeSecurity(total: 0)
        XCTAssertEqual(emit(), .nothingToSummarize)
        XCTAssertFalse(FileManager.default.fileExists(atPath: todayFile.path))
        XCTAssertNotNil(ReportEngine.SummaryEmitOutcome.nothingToSummarize.partialReason)

        // A mobile list that names no device is no fleet either.
        try writeMobile(count: 0)
        XCTAssertEqual(emit(), .nothingToSummarize)
        XCTAssertFalse(FileManager.default.fileExists(atPath: todayFile.path))
    }

    func testAMobileOnlyDayRebuildsWhenMacsAppear() throws {
        try writeMobile(count: 4)
        XCTAssertEqual(emit(["mobile-devices-list"]), .wrote)
        try writeSecurity(total: 10)
        XCTAssertEqual(emit(["security"]), .wrote)

        let rebuilt = try summary()
        XCTAssertEqual(rebuilt.totalDevices, 10)
        XCTAssertEqual(rebuilt.fileVaultPct, 100)
        XCTAssertEqual(rebuilt.mobileDeviceCount, 4)
    }

    func testARunThatReadNoMacsDoesNotReplaceADayThatCountedThem() throws {
        try writeSecurity(total: 10)
        try writeMobile(count: 4)
        XCTAssertEqual(emit(["security", "mobile-devices-list"]), .wrote)

        // The Mac sources can no longer be read this run; mobile landed.
        try FileManager.default.removeItem(at: dataDir.appendingPathComponent("security"))
        try writeMobile(count: 5)
        XCTAssertEqual(emit(["mobile-devices-list"]), .keptExisting)

        let kept = try summary()
        XCTAssertEqual(kept.totalDevices, 10)
        XCTAssertEqual(kept.mobileDeviceCount, 4)
    }

    func testFreshSummaryIsBetterRefusesAMacLessReplacementOnly() {
        func day(_ macs: Int, live: Bool = true) -> DailySummary {
            DailySummary(
                date: "2026-10-13", totalDevices: macs, fileVaultPct: nil, compliancePct: nil,
                staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
                collectionSources: live ? ["mobile-devices-list": "live"] : nil,
                mobileDeviceCount: 4)
        }
        XCTAssertFalse(ReportEngine.freshSummaryIsBetter(existing: day(10), fresh: day(0)))
        XCTAssertTrue(ReportEngine.freshSummaryIsBetter(existing: day(0), fresh: day(10)))
        XCTAssertTrue(ReportEngine.freshSummaryIsBetter(existing: day(0), fresh: day(0)),
                      "a later mobile-only run that landed a source still rebuilds")
    }

    // MARK: - A Mac fleet is unchanged

    /// The summary of a Mac fleet that also manages two iPads, as the previous build wrote it
    /// (captured before the writer learned of mobile-only fleets), with the date replaced.
    private static let macFleetGolden = """
    {
      "actionItemsP0" : 3,
      "actionItemsP1" : 0,
      "collectionSources" : {
        "computers" : "absent",
        "device-compliance" : "absent",
        "inventory-summary" : "absent",
        "mobile-devices-list" : "live",
        "patch-status" : "live",
        "security" : "live"
      },
      "date" : "DATE",
      "fileVaultPct" : 90,
      "firewallPct" : 80,
      "gatekeeperPct" : 100,
      "mobileDeviceCount" : 2,
      "patchPct" : 60,
      "patchPctBasis" : "device",
      "securityScore" : 85,
      "securityScoreBasis" : "filevault=15,sip=10,firewall=10,gatekeeper=5,patch_compliance=10",
      "sipPct" : 100,
      "source" : "jamf-cli",
      "totalDevices" : 10
    }
    """

    func testAMacFleetSummaryIsByteForByteWhatItWas() throws {
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "security", dataDir: dataDir, at: now,
            rows: GoldenFleetWorkspace.securitySummaryPayload(
                total: 10, filevault: 9, sip: 10, firewall: 8, gatekeeper: 10))
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "patch-status", dataDir: dataDir, at: now,
            rows: [GoldenFleetWorkspace.patchRow(
                id: "1", title: "Browser", onLatest: 60, total: 100)])
        try writeMobile(count: 2)

        XCTAssertEqual(
            emit(["security", "patch-status", "mobile-devices-list", "ea-results"]), .wrote)

        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        let json = try String(contentsOf: todayFile, encoding: .utf8)
        XCTAssertEqual(
            json, Self.macFleetGolden.replacingOccurrences(of: "DATE", with: today))
    }
}

/// What reads a summary that has no Macs: nil is "not measured", never 0, and never a division
/// by 0.
final class MobileOnlySummaryReaderTests: XCTestCase {

    private func day(_ date: String, macs: Int, mobile: Int? = 6, fileVault: Double? = nil,
                     stale: Int? = nil) -> DailySummary {
        DailySummary(
            date: date, totalDevices: macs, fileVaultPct: fileVault, compliancePct: nil,
            staleCount: stale, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli", mobileDeviceCount: mobile)
    }

    // MARK: - Fleet rollup and workbook

    func testRollupWithAZeroMacProfileDividesByNothingAndKeepsTheOthersFigures() throws {
        let rollup = FleetRollup.compute(
            groupName: "g",
            current: [day("2026-10-13", macs: 0), day("2026-10-13", macs: 50, fileVault: 80)],
            previous: [day("2026-10-12", macs: 0)])
        XCTAssertEqual(rollup.totalDevices, 50)
        XCTAssertEqual(rollup.metrics.first { $0.key == "devices" }?.label, "Macs")
        XCTAssertEqual(rollup.metrics.first { $0.key == "stale" }?.label, "Stale Macs")
        XCTAssertEqual(rollup.metrics.first { $0.key == "fileVault" }?.value, 80)
        XCTAssertNil(rollup.metrics.first { $0.key == "fileVault" }?.previous)
    }

    func testRollupOfOnlyMobileProfilesHasNoPercentAtAll() {
        let rollup = FleetRollup.compute(
            groupName: "g", current: [day("2026-10-13", macs: 0), day("2026-10-13", macs: 0)],
            previous: [])
        XCTAssertEqual(rollup.totalDevices, 0)
        for metric in rollup.metrics where metric.unit == .percent {
            XCTAssertNil(metric.value, metric.key)
        }
        XCTAssertNil(rollup.metrics.first { $0.key == "stale" }?.value)
    }

    func testFleetWorkbookModelCarriesAMobileOnlyProfileAsZeroMacsWithDashes() throws {
        let model = try XCTUnwrap(FleetWorkbookModel.build(
            groupName: "g",
            summariesByProfile: [
                ("ipads", [day("2026-10-13", macs: 0)]),
                ("macs", [day("2026-10-13", macs: 40, fileVault: 90, stale: 2)]),
            ],
            lookbackDays: 7, timestamp: "t"))
        let ipads = try XCTUnwrap(model.perProfile.first { $0.profile == "ipads" })
        XCTAssertEqual(ipads.devices, 0)
        XCTAssertNil(ipads.fileVaultPct)
        XCTAssertNil(ipads.staleCount)
        XCTAssertEqual(model.universal.first { $0.key == "fileVault" }?.value, 90,
                       "the 0-Mac profile weighs nothing")
        XCTAssertEqual(model.trend.first?.devices, 40)
    }

    // MARK: - Alerts, period report, trends, library

    func testATotalMacsRuleNeverFiresOnADayWithNoMacs() {
        let below = AlertRule(metric: "total_devices", when: "below", threshold: 100,
                              lookbackDays: nil)
        let drops = AlertRule(metric: "total_devices", when: "drops_more_than", threshold: 5,
                              lookbackDays: nil)
        let hits = MetricAlertEvaluator.evaluate(
            rules: [below, drops], current: day("2026-10-13", macs: 0),
            prior: day("2026-10-12", macs: 500))
        XCTAssertTrue(hits.isEmpty, "\(hits)")
        XCTAssertEqual(
            MetricAlertEvaluator.evaluate(
                rules: [below], current: day("2026-10-13", macs: 40), prior: nil).count, 1)
    }

    func testPeriodReportReadsNoMacCountForADayWithNone() {
        XCTAssertNil(PeriodReportModel.fleetValue("totalDevices", day("2026-10-13", macs: 0)))
        XCTAssertEqual(
            PeriodReportModel.fleetValue("totalDevices", day("2026-10-13", macs: 7)), 7)
        XCTAssertEqual(
            PeriodMetricCatalog.fleetMetrics(in: []).first { $0.id == "totalDevices" }?.label,
            "Managed Macs")
    }

    func testTheComputersLineHasAGapNotAZeroOnAMobileOnlyDay() {
        let store = TrendStore(
            summaries: [
                day("2026-10-11", macs: 0, mobile: 5),
                day("2026-10-12", macs: 20, mobile: 5),
                day("2026-10-13", macs: 0, mobile: 6),
            ], range: .all)
        let series = store.managedDeviceSeries()
        XCTAssertEqual(series.first { $0.label == "Computers" }?.points.map(\.value), [20])
        XCTAssertEqual(series.first { $0.label == "Mobile devices" }?.points.map(\.value),
                       [5, 5, 6])

        let mobileOnly = TrendStore(summaries: [day("2026-10-13", macs: 0, mobile: 6)], range: .all)
        XCTAssertEqual(mobileOnly.managedDeviceSeries().map(\.label), ["Mobile devices"])
    }

    func testAMobileOnlyDayHasNoStabilityIndexOrActiveDeviceCount() {
        let summary = day("2026-10-13", macs: 0)
        XCTAssertNil(summary.stabilityIndex)
        XCTAssertNil(summary.activeDeviceCount)
        XCTAssertNil(TrendSeries.stabilityIndex(
            compliancePct: nil, patchPct: nil, staleCount: nil, totalDevices: 0))
        XCTAssertEqual(TrendSeries.stabilityIndex(
            compliancePct: 80, patchPct: nil, staleCount: 0, totalDevices: 0), 80,
            "a stale share over 0 Macs is dropped, not divided")
    }

    func testTheReportLibraryShowsNoMacCountForAMobileOnlyDay() throws {
        let dir = GoldenFleetWorkspace.freshRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        try GoldenFleetWorkspace.writeJSON(
            ["date": "2026-10-13", "totalDevices": 0, "source": "jamf-cli"],
            to: dir.appendingPathComponent("summary_2026-10-13.json"))
        let count = ReportLibrary().deviceCount(
            forReportURL: URL(fileURLWithPath: "report_p_2026-10-13_060000.xlsx"),
            summariesDir: dir)
        XCTAssertNil(count)
    }

    // MARK: - Wording

    func testTheInsightCallsTheMacCountMacsAndLeavesItOutForAFleetWithNone() {
        let withMacs = FleetInsightInput.fleet(current: day("2026-10-13", macs: 12), previous: nil)
        XCTAssertEqual(withMacs.facts.first?.label, "Managed Macs")

        let mobileOnly = FleetInsightInput.fleet(
            current: day("2026-10-13", macs: 0, mobile: 6),
            previous: day("2026-10-12", macs: 0, mobile: 4))
        XCTAssertEqual(mobileOnly.facts.count, 1)
        let fact = mobileOnly.facts[0]
        XCTAssertTrue(fact.label.contains("mobile devices"), fact.label)
        XCTAssertEqual(fact.value, .count(6))
        XCTAssertEqual(fact.prior, .count(4))
        XCTAssertFalse(mobileOnly.promptContext().contains("Total managed devices"))
    }

    func testTheHTMLGlanceSaysWhyItHasNoFiguresForAFleetWithNoMacs() throws {
        let root = GoldenFleetWorkspace.freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let summary = day("2026-10-13", macs: 0)
        try GoldenFleetWorkspace.writeJSON(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)),
            to: root.appendingPathComponent("snapshots/summaries/summary_2026-10-13.json"))
        let dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let report = HtmlReport(config: try ConfigLoader.loadFromString(""), dataDir: dataDir)

        let glance = report.buildAtAGlance(report.loadInputs(for: [.atAGlance]))
        XCTAssertEqual(glance.omission, "the fleet has no Macs, and the six figures are Mac figures")
        XCTAssertTrue(glance.html.isEmpty)
    }
}
