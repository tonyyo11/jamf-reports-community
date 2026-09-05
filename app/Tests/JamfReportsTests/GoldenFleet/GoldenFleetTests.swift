import Foundation
import XCTest
@testable import JamfReports

/// Ground-truth correctness harness. A declarative synthetic fleet with KNOWN
/// hand-computed outputs is written to a temp dir; the REAL engine/readers run
/// against it and every headline number is asserted against the arithmetic in
/// the spec (never re-derived by calling the code under test).
///
/// Determinism: all times derive from one local-noon anchor (see
/// `GoldenFleetClock`), so the suite passes in any timezone and in CI forever.
final class GoldenFleetTests: XCTestCase {

    private var tmpDirs: [URL] = []
    private var anchor: Date!

    override func setUp() {
        super.setUp()
        anchor = GoldenFleetClock.anchorNoon()
    }

    override func tearDown() {
        for dir in tmpDirs { try? FileManager.default.removeItem(at: dir) }
        tmpDirs.removeAll()
        super.tearDown()
    }

    private func makeRoot() -> URL {
        let root = GoldenFleetWorkspace.freshRoot()
        tmpDirs.append(root)
        return root
    }

    private func onlySummary(in dir: URL) throws -> DailySummary {
        let summaries = SummaryJSONParser.parseDirectory(dir)
        return try XCTUnwrap(summaries.first, "expected exactly one summary in \(dir.lastPathComponent)")
    }

    // MARK: - Case A — happy fleet headline metrics

    /// Fleet: 250 devices. FileVault 240, SIP 250, Firewall 245, Gatekeeper 248.
    /// Patch titles at 80/90/70%. All expected values hand-computed below.
    func testCaseA_HappyFleetHeadlineMetrics() throws {
        let root = makeRoot()
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let summariesDir = root.appendingPathComponent("summaries", isDirectory: true)

        // Security summary — no filevault_encrypted_pct so % is derived from counts.
        try GoldenFleetWorkspace.writeJSON(
            GoldenFleetWorkspace.securitySummaryPayload(
                total: 250, filevault: 240, sip: 250, firewall: 245, gatekeeper: 248),
            to: dataDir.appendingPathComponent("security", isDirectory: true)
                .appendingPathComponent("security_\(GoldenFleetClock.stamp(anchor)).json"))

        // Patch titles: compliance_pct 80, 90, 70 → mean 80.0.
        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: anchor, rows: [
            GoldenFleetWorkspace.patchRow(id: "1", title: "Firefox", onLatest: 80, total: 100),
            GoldenFleetWorkspace.patchRow(id: "2", title: "Chrome", onLatest: 90, total: 100),
            GoldenFleetWorkspace.patchRow(id: "3", title: "Zoom", onLatest: 70, total: 100),
        ])

        let engine = ReportEngine(config: ReportConfig(), dataDir: dataDir)
        engine.emitSummaryJSON(summariesDir: summariesDir)

        let s = try onlySummary(in: summariesDir)

        XCTAssertEqual(s.totalDevices, 250)
        // 240 / 250 * 100 = 96.0
        XCTAssertEqual(try XCTUnwrap(s.fileVaultPct), 96.0, accuracy: 0.001)
        // 250 / 250 * 100 = 100.0
        XCTAssertEqual(try XCTUnwrap(s.sipPct), 100.0, accuracy: 0.001)
        // 245 / 250 * 100 = 98.0
        XCTAssertEqual(try XCTUnwrap(s.firewallPct), 98.0, accuracy: 0.001)
        // 248 / 250 * 100 = 99.2
        XCTAssertEqual(try XCTUnwrap(s.gatekeeperPct), 99.2, accuracy: 0.001)
        // Only fileVault/sip/firewall present → weights 15/15/15 renormalize to a
        // plain mean of their pcts: (96.0 + 100.0 + 98.0) / 3 = 98.0
        XCTAssertEqual(try XCTUnwrap(s.securityScore), 98.0, accuracy: 0.001)
        // P0 = (250-240) + (250-250) + (250-245) = 10 + 0 + 5 = 15
        XCTAssertEqual(s.actionItemsP0, 15)
        // P1 = (250-248) = 2
        XCTAssertEqual(s.actionItemsP1, 2)
        // Unweighted mean of parseable compliance_pct: (80 + 90 + 70) / 3 = 80.0
        XCTAssertEqual(try XCTUnwrap(s.patchPct), 80.0, accuracy: 0.001)
        // No device rows and no compliance config → no proxy, no real mSCP.
        XCTAssertNil(s.compliancePct)
        XCTAssertNil(s.complianceIsProxy)
    }

    // MARK: - Case B — mSCP bands + crossCheck

    /// Universe of 14 devices across every band, with a rule_count violation and
    /// a no-row device both landing in No Data; a failures-list column drives the
    /// count-vs-list cross-check.
    func testCaseB_MSCPBandsAndCrossCheck() throws {
        let root = makeRoot()
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let col = "NIST Failures"
        let listCol = "NIST Failed List"

        var rows: [[String: Any]] = []
        // Pass (0): 6 devices
        for i in 1...6 { rows.append(GoldenFleetWorkspace.eaRow(device: "mac-00\(i)", ea: col, value: 0)) }
        // Low (1–10): 2 devices at 5
        rows.append(GoldenFleetWorkspace.eaRow(device: "mac-101", ea: col, value: 5))
        rows.append(GoldenFleetWorkspace.eaRow(device: "mac-102", ea: col, value: 5))
        // Med-Low (11–30): 2 devices at 20
        rows.append(GoldenFleetWorkspace.eaRow(device: "mac-201", ea: col, value: 20))
        rows.append(GoldenFleetWorkspace.eaRow(device: "mac-202", ea: col, value: 20))
        // Medium (31–50): 1 device at 40
        rows.append(GoldenFleetWorkspace.eaRow(device: "mac-301", ea: col, value: 40))
        // High (>50): 1 device at 70
        rows.append(GoldenFleetWorkspace.eaRow(device: "mac-401", ea: col, value: 70))
        // rule_count violation (150 > 100) → No Data
        rows.append(GoldenFleetWorkspace.eaRow(device: "mac-501", ea: col, value: 150))
        // Device present only via a DIFFERENT ea → in the universe, No Data here
        rows.append(GoldenFleetWorkspace.eaRow(device: "mac-601", ea: "Other EA", value: 1))
        // Failures-list column for 4 devices → 2 agree, 2 disagree
        rows.append(GoldenFleetWorkspace.eaRow(device: "mac-001", ea: listCol, value: ""))         // 0 vs 0 agree
        rows.append(GoldenFleetWorkspace.eaRow(device: "mac-101", ea: listCol, value: "a|b|c|d|e")) // 5 vs 5 agree
        rows.append(GoldenFleetWorkspace.eaRow(device: "mac-201", ea: listCol, value: "a|b|c"))     // 20 vs 3 disagree
        rows.append(GoldenFleetWorkspace.eaRow(device: "mac-301", ea: listCol, value: "a|b"))       // 40 vs 2 disagree

        let url = try GoldenFleetWorkspace.writeEAResults(dataDir: dataDir, at: anchor, rows: rows)

        let decoded = EAResultRow.decodeSnapshot(try Data(contentsOf: url))
        let eaRows = try XCTUnwrap(decoded.rows, "complete bare array must decode")
        XCTAssertEqual(decoded.reason, "array")

        let baseline = ComplianceBaselineConfig(
            name: "NIST", failuresCountColumn: col, failuresListColumn: listCol, ruleCount: 100)
        let results = MSCPComplianceService.evaluate(rows: eaRows, baselines: [baseline])
        let r = try XCTUnwrap(results.first)

        // Universe = 14 distinct devices. Bands: pass 6, low 2, medLow 2,
        // medium 1, high 1, noData 2 (mac-501 out-of-bound + mac-601 no row).
        XCTAssertEqual(r.totalDevices, 14)
        XCTAssertEqual(bandCount(r, "Pass"), 6)
        XCTAssertEqual(bandCount(r, "Low"), 2)
        XCTAssertEqual(bandCount(r, "Med-Low"), 2)
        XCTAssertEqual(bandCount(r, "Medium"), 1)
        XCTAssertEqual(bandCount(r, "High"), 1)
        XCTAssertEqual(r.noDataCount, 2)
        // devicesWithData = 14 - 2 = 12; pass = 6 → 6 / 12 * 100 = 50.0
        XCTAssertEqual(r.devicesWithData, 12)
        XCTAssertEqual(try XCTUnwrap(r.compliancePct), 50.0, accuracy: 0.001)

        let crossChecks = MSCPComplianceService.crossCheck(rows: eaRows, baselines: [baseline])
        let cc = try XCTUnwrap(crossChecks.first)
        XCTAssertEqual(cc.devicesCompared, 4)
        XCTAssertEqual(cc.disagreements, 2)
    }

    private func bandCount(_ result: MSCPComplianceService.BaselineResult, _ label: String) -> Int {
        result.bands.first { $0.label == label }?.count ?? -1
    }

    // MARK: - Case B' — chart series merges summaries + ea-results override

    /// Two summary days provide band history; an ea-results file on the newer day
    /// OVERRIDES that day's summary-derived point (ea-results wins per day).
    func testCaseBPrime_MSCPChartHistoryAndEAResultsOverride() throws {
        let root = makeRoot()
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let col = "NIST Failures"
        let baseline = ComplianceBaselineConfig(name: "NIST", failuresCountColumn: col)

        let day2 = GoldenFleetClock.timestamp(dayOffset: -2, hour: 12, minute: 0, relativeTo: anchor)
        let day1 = GoldenFleetClock.timestamp(dayOffset: -1, hour: 12, minute: 0, relativeTo: anchor)

        let s2 = summaryWithBands(date: day2, pass: 10)   // 10 devices, all pass
        let s1 = summaryWithBands(date: day1, pass: 20)   // 20 devices, all pass

        // Summaries-only: two points, one per day, ascending.
        let seriesA = MSCPChartDataBuilder.buildAllSeries(
            baselines: [baseline], dataDir: dataDir, summaries: [s2, s1])["NIST"] ?? []
        XCTAssertEqual(seriesA.count, 2)
        XCTAssertEqual(seriesA[0].counts.pass, 10)
        XCTAssertEqual(seriesA[1].counts.pass, 20)
        XCTAssertFalse(seriesA[0].isSalvaged)

        // Add ea-results on day1 with a DIFFERENT distribution (5 pass).
        var ea: [[String: Any]] = []
        for i in 0..<5 { ea.append(GoldenFleetWorkspace.eaRow(device: "d-\(i)", ea: col, value: 0)) }
        _ = try GoldenFleetWorkspace.writeEAResults(dataDir: dataDir, at: day1, rows: ea)

        let seriesB = MSCPChartDataBuilder.buildAllSeries(
            baselines: [baseline], dataDir: dataDir, summaries: [s2, s1])["NIST"] ?? []
        XCTAssertEqual(seriesB.count, 2)
        // day2 still from summary (10 pass); day1 overridden by ea-results (5 pass).
        XCTAssertEqual(seriesB[0].counts.pass, 10)
        XCTAssertEqual(seriesB[1].counts.pass, 5)
    }

    private func summaryWithBands(date: Date, pass: Int) -> DailySummary {
        DailySummary(
            date: GoldenFleetClock.daySummaryString(date),
            totalDevices: pass, fileVaultPct: nil, compliancePct: nil, staleCount: nil,
            osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil, source: "test",
            mscpBands: ["NIST": MSCPBandCounts(
                pass: pass, low: 0, medLow: 0, medium: 0, high: 0, noData: 0)])
    }

    // MARK: - Case C — patch adoption velocity

    /// Firefox crosses 50% at day-14 and 90% at day-8 (release day-20);
    /// Chrome starts above 50% (no crossing); Zoom has zero devices (excluded);
    /// Slack has no release date; a corrupt same-day file is skipped.
    func testCaseC_PatchVelocity() throws {
        let root = makeRoot()
        let dataDir = root.appendingPathComponent("data", isDirectory: true)

        func ts(_ off: Int, _ h: Int = 12, _ m: Int = 0) -> Date {
            GoldenFleetClock.timestamp(dayOffset: off, hour: h, minute: m, relativeTo: anchor)
        }

        // Firefox (id 1): 20% (day-18), 55% (day-14), 92% (day-8)
        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: ts(-18),
            rows: [GoldenFleetWorkspace.patchRow(id: "1", title: "Firefox", onLatest: 20, total: 100)])
        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: ts(-14),
            rows: [GoldenFleetWorkspace.patchRow(id: "1", title: "Firefox", onLatest: 55, total: 100)])
        // Corrupt file on the SAME day (later time) — must be skipped, leaving 55%.
        try GoldenFleetWorkspace.writePatchStatusRaw(dataDir: dataDir, at: ts(-14, 13),
            raw: "{{ this is not valid json")
        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: ts(-8),
            rows: [GoldenFleetWorkspace.patchRow(id: "1", title: "Firefox", onLatest: 92, total: 100)])

        // Chrome (id 2): 60% (day-9), 70% (day-5) — first sample already ≥ 50.
        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: ts(-9),
            rows: [GoldenFleetWorkspace.patchRow(id: "2", title: "Chrome", onLatest: 60, total: 100)])
        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: ts(-5),
            rows: [GoldenFleetWorkspace.patchRow(id: "2", title: "Chrome", onLatest: 70, total: 100)])

        // Zoom (id 3): zero devices → no denominator → excluded entirely.
        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: ts(-4),
            rows: [GoldenFleetWorkspace.patchRow(id: "3", title: "Zoom", onLatest: 0, total: 0)])

        // Slack (id 4): 30% (day-6), 40% (day-3) — no release date.
        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: ts(-6),
            rows: [GoldenFleetWorkspace.patchRow(id: "4", title: "Slack", onLatest: 30, total: 100)])
        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: ts(-3),
            rows: [GoldenFleetWorkspace.patchRow(id: "4", title: "Slack", onLatest: 40, total: 100)])

        let releases: [PatchReleaseDateService.Row] = [
            releaseRow(id: "1", title: "Firefox", offset: -20),
            releaseRow(id: "2", title: "Chrome", offset: -10),
        ]

        let velocities = PatchVelocityBuilder.compute(dataDir: dataDir, releaseRows: releases, now: anchor)

        // Zoom excluded → exactly 3 titles.
        XCTAssertEqual(velocities.count, 3)
        XCTAssertNil(velocities.first { $0.titleId == "3" }, "zero-device title must be excluded")

        let ff = try XCTUnwrap(velocities.first { $0.titleId == "1" })
        XCTAssertEqual(ff.series.count, 3, "corrupt same-day file skipped; three valid points remain")
        // crossing 50 at day-14: (-14) - (-20) = 6 days from release
        XCTAssertEqual(ff.daysTo50, 6)
        // crossing 90 at day-8: (-8) - (-20) = 12 days from release
        XCTAssertEqual(ff.daysTo90, 12)
        // newest sample 92% < 100 → daysBehind = now(0) - release(-20) = 20
        XCTAssertEqual(ff.daysBehind, 20)
        XCTAssertEqual(try XCTUnwrap(ff.adoptionPct), 92.0, accuracy: 0.001)

        let ch = try XCTUnwrap(velocities.first { $0.titleId == "2" })
        XCTAssertNil(ch.daysTo50, "series starts already ≥ 50% → crossing predates recording → nil")
        XCTAssertNil(ch.daysTo90, "never reaches 90% → nil")
        XCTAssertEqual(ch.daysBehind, 10)
        XCTAssertEqual(try XCTUnwrap(ch.adoptionPct), 70.0, accuracy: 0.001)

        let sl = try XCTUnwrap(velocities.first { $0.titleId == "4" })
        XCTAssertNil(sl.daysBehind, "no release date → nil daysBehind")
        XCTAssertNil(sl.daysTo50)
        XCTAssertNil(sl.daysTo90)
        XCTAssertEqual(try XCTUnwrap(sl.adoptionPct), 40.0, accuracy: 0.001)
    }

    private func releaseRow(id: String, title: String, offset: Int) -> PatchReleaseDateService.Row {
        let date = GoldenFleetClock.timestamp(dayOffset: offset, hour: 12, minute: 0, relativeTo: anchor)
        let json = """
        {"title_id":"\(id)","title":"\(title)","latest_version":"1.0","release_date":"\(GoldenFleetClock.isoLocal(date))"}
        """
        // Decode through the real Row decoder so the CodingKeys contract is exercised.
        return try! JSONDecoder().decode(PatchReleaseDateService.Row.self, from: Data(json.utf8))
    }

    // MARK: - Case D — salvage of a truncated ea-results file

    /// A ~24 KB bare array truncated mid-object recovers exactly its complete
    /// prefix, flags the reason "salvaged", and marks that day's band point.
    func testCaseD_SalvageTruncatedEAResults() throws {
        let root = makeRoot()
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let col = "NIST Failures"

        let n = try GoldenFleetWorkspace.writeTruncatedEAResults(
            dataDir: dataDir, at: anchor, column: col, completeObjects: 500)
        XCTAssertEqual(n, 500)

        let eaURL = dataDir.appendingPathComponent("ea-results", isDirectory: true)
            .appendingPathComponent("ea-results_\(GoldenFleetClock.stamp(anchor)).json")
        // The file must actually exceed the 16 KB truncation boundary it mimics.
        let byteCount = try Data(contentsOf: eaURL).count
        XCTAssertGreaterThan(byteCount, 16 * 1024)

        let decoded = EAResultRow.decodeSnapshot(try Data(contentsOf: eaURL))
        let rows = try XCTUnwrap(decoded.rows, "truncated array must salvage")
        XCTAssertEqual(rows.count, 500, "salvage recovers exactly the complete prefix")
        XCTAssertTrue(decoded.reason.hasPrefix("salvaged"), "reason: \(decoded.reason)")
        XCTAssertTrue(EAResultRow.isSalvageReason(decoded.reason))

        let baseline = ComplianceBaselineConfig(name: "NIST", failuresCountColumn: col)
        let series = MSCPChartDataBuilder.buildAllSeries(
            baselines: [baseline], dataDir: dataDir, summaries: [])["NIST"] ?? []
        let point = try XCTUnwrap(series.first, "salvaged day must chart a point")
        XCTAssertTrue(point.isSalvaged, "point from a salvaged file must be flagged")
        XCTAssertEqual(point.counts.pass, 500, "all 500 salvaged devices are value 0 → Pass")
    }

    // MARK: - Case E — max_cache_age_hours gate

    /// An over-age security snapshot is treated as ABSENT, so the digest cannot be
    /// built and no summary is written. A fresh control workspace proves the gate
    /// (not some other absence) is what suppressed the write.
    ///
    /// Age comes from the FILENAME timestamp (mtime fallback for non-canonical
    /// names) — the gate was aligned with the filename-ordered readers because
    /// synced storage re-stamps mtimes. Both sides are driven via the stamp.
    func testCaseE_OverAgeCacheTreatedAbsent() throws {
        // Over-age: filename stamped 2h ago, limit 1h → expired → absent → nil summary.
        let expiredRoot = makeRoot()
        let expiredData = expiredRoot.appendingPathComponent("data", isDirectory: true)
        let expiredSummaries = expiredRoot.appendingPathComponent("summaries", isDirectory: true)
        let expiredStamp = GoldenFleetClock.stamp(Date().addingTimeInterval(-2 * 3600))
        let expiredFile = expiredData.appendingPathComponent("security", isDirectory: true)
            .appendingPathComponent("security_\(expiredStamp).json")
        try GoldenFleetWorkspace.writeJSON(
            GoldenFleetWorkspace.securitySummaryPayload(
                total: 100, filevault: 100, sip: 100, firewall: 100, gatekeeper: 100),
            to: expiredFile)

        var cfg = ReportConfig()
        var jamf = JamfCLIConfig()
        jamf.maxCacheAgeHours = 1
        cfg.jamfCli = jamf

        ReportEngine(config: cfg, dataDir: expiredData).emitSummaryJSON(summariesDir: expiredSummaries)
        XCTAssertTrue(SummaryJSONParser.parseDirectory(expiredSummaries).isEmpty,
                      "over-age cache must yield no summary")

        // Control: identical config, filename stamped 10 min ago → summary IS written.
        let freshRoot = makeRoot()
        let freshData = freshRoot.appendingPathComponent("data", isDirectory: true)
        let freshSummaries = freshRoot.appendingPathComponent("summaries", isDirectory: true)
        let freshStamp = GoldenFleetClock.stamp(Date().addingTimeInterval(-600))
        let freshFile = freshData.appendingPathComponent("security", isDirectory: true)
            .appendingPathComponent("security_\(freshStamp).json")
        try GoldenFleetWorkspace.writeJSON(
            GoldenFleetWorkspace.securitySummaryPayload(
                total: 100, filevault: 100, sip: 100, firewall: 100, gatekeeper: 100),
            to: freshFile)

        ReportEngine(config: cfg, dataDir: freshData).emitSummaryJSON(summariesDir: freshSummaries)
        let s = try onlySummary(in: freshSummaries)
        XCTAssertEqual(s.totalDevices, 100, "fresh cache within the age limit yields a summary")
    }

    // MARK: - Case F — metric alerts end to end

    /// A rule set spanning below/above/drops_more_than: exactly two fire, with
    /// exact message values, and the proxy-flip guard suppresses a compliance drop.
    func testCaseF_MetricAlerts() throws {
        let current = DailySummary(
            date: "2026-06-02", totalDevices: 100,
            fileVaultPct: 85.0, compliancePct: 67.0, staleCount: 50,
            osCurrentPct: 60.0, crowdstrikePct: nil, patchPct: 70.0, source: "test",
            mscpScorePct: nil, complianceIsProxy: false)
        let prior = DailySummary(
            date: "2026-06-01", totalDevices: 100,
            fileVaultPct: 95.0, compliancePct: 96.0, staleCount: 40,
            osCurrentPct: nil, crowdstrikePct: nil, patchPct: 80.0, source: "test",
            mscpScorePct: 80.0, complianceIsProxy: true)

        let rules: [AlertRule] = [
            AlertRule(metric: "filevault_pct", when: "below", threshold: 90),       // fires
            AlertRule(metric: "stale_count", when: "above", threshold: 100),         // 50 > 100 false
            AlertRule(metric: "patch_pct", when: "drops_more_than", threshold: 5),   // 80→70 fires
            AlertRule(metric: "os_current_pct", when: "drops_more_than", threshold: 5), // prior nil → no
            AlertRule(metric: "compliance_pct", when: "drops_more_than", threshold: 5), // proxy flip → no
            AlertRule(metric: "mscp_score_pct", when: "below", threshold: 90),        // current nil → no
        ]

        let hits = MetricAlertEvaluator.evaluate(rules: rules, current: current, prior: prior)
        XCTAssertEqual(hits.count, 2, "only filevault-below and patch-drop fire")

        let fv = try XCTUnwrap(hits.first { $0.metricLabel == "FileVault" })
        XCTAssertEqual(fv.current, 85.0, accuracy: 0.001)
        XCTAssertEqual(fv.message, "85% — below threshold 90")

        let patch = try XCTUnwrap(hits.first { $0.metricLabel == "Patch" })
        XCTAssertEqual(patch.current, 70.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(patch.prior), 80.0, accuracy: 0.001)
        // 80 - 70 = 10 > 5, unit "pp", prior date carried verbatim.
        XCTAssertEqual(patch.message, "70% — dropped 10pp vs 2026-06-01 (80%)")

        XCTAssertNil(hits.first { $0.metricLabel == "Compliance" },
                     "compliance_pct drop must be suppressed across a complianceIsProxy flip")

        // Control: with the SAME proxy basis on both sides, the compliance drop DOES fire.
        let priorSameBasis = DailySummary(
            date: "2026-06-01", totalDevices: 100,
            fileVaultPct: 95.0, compliancePct: 96.0, staleCount: 40,
            osCurrentPct: nil, crowdstrikePct: nil, patchPct: 80.0, source: "test",
            mscpScorePct: 80.0, complianceIsProxy: false)
        let hits2 = MetricAlertEvaluator.evaluate(
            rules: [AlertRule(metric: "compliance_pct", when: "drops_more_than", threshold: 5)],
            current: current, prior: priorSameBasis)
        XCTAssertEqual(hits2.count, 1, "same-basis compliance drop (96→67) fires")
    }

    // MARK: - Case G — snapshot manifest verify / tamper / exclusion

    func testCaseG_ManifestVerifyTamperAndExclusion() throws {
        let root = makeRoot()
        let dir = root.appendingPathComponent("patch-status", isDirectory: true)
        let snapshotName = "patch-status_\(GoldenFleetClock.stamp(anchor)).json"
        let snapshot = dir.appendingPathComponent(snapshotName)
        let payload = try JSONSerialization.data(withJSONObject: [
            GoldenFleetWorkspace.patchRow(id: "1", title: "Firefox", onLatest: 90, total: 100)])
        // Write the exact payload bytes so the on-disk file and the recorded hash agree.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try payload.write(to: snapshot)

        try SnapshotManifest.record(snapshotFile: snapshot, data: payload)

        XCTAssertEqual(SnapshotManifest.verify(snapshot: snapshot, data: payload), .verified)

        let tampered = payload + Data([0x20])
        XCTAssertEqual(SnapshotManifest.verify(snapshot: snapshot, data: tampered), .mismatch)

        // manifest.json is present in the dir but must never be chosen as "data".
        let newest = try XCTUnwrap(FileManager.newestSnapshotFile(in: dir))
        XCTAssertEqual(newest.lastPathComponent, snapshotName,
                       "newest-file readers must exclude manifest.json")
    }

    // MARK: - Case H — FleetRollup device weighting

    /// 600 devices @ 90% and 200 @ 60% → device-weighted 82.5; a nil-metric
    /// profile is excluded from the denominator (no phantom zero).
    func testCaseH_FleetRollupDeviceWeighting() throws {
        let p1 = DailySummary(date: "2026-06-01", totalDevices: 600, fileVaultPct: 90.0,
                              compliancePct: nil, staleCount: nil, osCurrentPct: nil,
                              crowdstrikePct: nil, patchPct: nil, source: "test")
        let p2 = DailySummary(date: "2026-06-01", totalDevices: 200, fileVaultPct: 60.0,
                              compliancePct: nil, staleCount: nil, osCurrentPct: nil,
                              crowdstrikePct: nil, patchPct: nil, source: "test")
        // 100 devices but fileVaultPct nil → must NOT be counted as 0.
        let p3 = DailySummary(date: "2026-06-01", totalDevices: 100, fileVaultPct: nil,
                              compliancePct: nil, staleCount: nil, osCurrentPct: nil,
                              crowdstrikePct: nil, patchPct: nil, source: "test")

        let rollup = FleetRollup.compute(groupName: "G", current: [p1, p2, p3], previous: [])

        XCTAssertEqual(rollup.profileCount, 3)
        XCTAssertEqual(rollup.totalDevices, 900)

        let fv = try XCTUnwrap(rollup.metrics.first { $0.key == "fileVault" })
        let value = try XCTUnwrap(fv.value)
        // (90*600 + 60*200) / (600+200) = 66000 / 800 = 82.5
        // If p3 (nil) were coerced to 0 the answer would be 66000/900 = 73.33.
        XCTAssertEqual(value, 82.5, accuracy: 0.001)
    }

    // MARK: - Case I — day-boundary determinism

    /// Two snapshots at 00:30 and 23:30 of the SAME local day bucket to ONE day;
    /// the newest (23:30) wins.
    func testCaseI_DayBoundaryBucketsToOneDay() throws {
        let root = makeRoot()
        let dataDir = root.appendingPathComponent("data", isDirectory: true)

        let early = GoldenFleetClock.timestamp(dayOffset: -2, hour: 0, minute: 30, relativeTo: anchor)
        let late = GoldenFleetClock.timestamp(dayOffset: -2, hour: 23, minute: 30, relativeTo: anchor)

        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: early,
            rows: [GoldenFleetWorkspace.patchRow(id: "9", title: "Boundary", onLatest: 40, total: 100)])
        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: late,
            rows: [GoldenFleetWorkspace.patchRow(id: "9", title: "Boundary", onLatest: 60, total: 100)])

        let velocities = PatchVelocityBuilder.compute(dataDir: dataDir, releaseRows: [], now: anchor)
        let bnd = try XCTUnwrap(velocities.first { $0.titleId == "9" })
        XCTAssertEqual(bnd.series.count, 1, "same local day → one bucket")
        XCTAssertEqual(try XCTUnwrap(bnd.adoptionPct), 60.0, accuracy: 0.001,
                       "the newest (23:30) sample wins")
    }

    // MARK: - Case J — snapshot freshness with injected now

    func testCaseJ_SnapshotFreshness() throws {
        let now = Date()

        // Fresh: newest mtime 630s old, threshold 3600 → fresh, 10 minutes.
        let freshRoot = makeRoot()
        let freshFile = freshRoot.appendingPathComponent("security", isDirectory: true)
            .appendingPathComponent("s.json")
        try GoldenFleetWorkspace.writeRaw("[]", to: freshFile)
        try GoldenFleetWorkspace.setModificationDate(freshFile, to: now.addingTimeInterval(-630))
        if case let .fresh(ageMinutes) = SnapshotFreshness.evaluate(
            dataDir: freshRoot, threshold: 3600, now: now) {
            XCTAssertEqual(ageMinutes, 10)  // Int(630 / 60) = 10
        } else {
            XCTFail("expected .fresh")
        }

        // Stale: newest mtime 7250s old → stale, 120 minutes.
        let staleRoot = makeRoot()
        let staleFile = staleRoot.appendingPathComponent("security", isDirectory: true)
            .appendingPathComponent("s.json")
        try GoldenFleetWorkspace.writeRaw("[]", to: staleFile)
        try GoldenFleetWorkspace.setModificationDate(staleFile, to: now.addingTimeInterval(-7250))
        if case let .stale(ageMinutes) = SnapshotFreshness.evaluate(
            dataDir: staleRoot, threshold: 3600, now: now) {
            XCTAssertEqual(ageMinutes, 120)  // Int(7250 / 60) = 120
        } else {
            XCTFail("expected .stale")
        }

        // No snapshots: an empty dir.
        let emptyRoot = makeRoot()
        if case .noSnapshots = SnapshotFreshness.evaluate(
            dataDir: emptyRoot, threshold: 3600, now: now) {
            // expected
        } else {
            XCTFail("expected .noSnapshots")
        }
    }

    // MARK: - Case K — DDM per-device status header numbers

    /// One DDM-enabled Mac that reported, one that has not, one Mac without
    /// DDM. Header strip must read enabled 2 of 3, reported 1, failing 1.
    func testCaseK_DDMDeviceStatusHeaderNumbers() throws {
        let root = makeRoot()
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let stamp = GoldenFleetClock.stamp(anchor)
        try GoldenFleetWorkspace.writeJSON([
            ["id": "1", "general": ["name": "A", "managementId": "m1", "declarativeDeviceManagementEnabled": true]],
            ["id": "2", "general": ["name": "B", "managementId": "m2", "declarativeDeviceManagementEnabled": true]],
            ["id": "3", "general": ["name": "C", "managementId": "m3", "declarativeDeviceManagementEnabled": false]],
        ], to: dataDir.appendingPathComponent("computers", isDirectory: true)
            .appendingPathComponent("computers_\(stamp).json"))
        try GoldenFleetWorkspace.writeJSON([
            ["deviceId": "1", "name": "A", "managementId": "m1", "ddmReported": true,
             "declarations": [["identifier": "D-1", "active": false, "valid": true]],
             "softwareUpdate": [:]],
            ["deviceId": "2", "name": "B", "managementId": "m2", "ddmReported": false,
             "declarations": [], "softwareUpdate": [:]],
        ], to: dataDir.appendingPathComponent("ddm-device-status", isDirectory: true)
            .appendingPathComponent("ddm-device-status_\(stamp).json"))

        let counts = DDMDeviceStatusService.fleetDDMCounts(
            computersURL: FileManager.newestJSONFile(in: dataDir.appendingPathComponent("computers")))
        XCTAssertEqual(counts.enabled, 2); XCTAssertEqual(counts.total, 3)

        let s = DDMDeviceStatusService.load(
            url: FileManager.newestJSONFile(in: dataDir.appendingPathComponent("ddm-device-status")))
        XCTAssertEqual(s.ddmReportedCount, 1)
        XCTAssertEqual(s.failingDeclarationCount, 1)
        XCTAssertEqual(
            DDMBlueprintView.decideLockState(isDemoMode: false, experimentalOn: false, platformAvailable: false,
                                             hasPlatformData: false, hasDeviceData: !s.records.isEmpty,
                                             ddmEnabledCount: counts.enabled),
            .unlockedWithData, "an on-prem profile with a scan snapshot is unlocked")
    }
}
