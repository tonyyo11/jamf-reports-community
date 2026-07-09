import Foundation
import XCTest
@testable import JamfReports

/// Adversarial-breaker regression pins. Each test locks the *now-correct* (or
/// deliberately accepted) behavior of a case an adversarial review proposed, so
/// a future refactor can't silently regress it. Every expected value is
/// hand-computed as a literal with the arithmetic shown inline; nothing is
/// re-derived by calling the code under test.
///
/// Determinism: all times derive from one local-noon anchor (see
/// `GoldenFleetClock`) so the suite is timezone-independent. Anything feeding
/// the digest cache-age gate uses filename stamps near `Date()` because that
/// gate reads the FILENAME timestamp, not mtime.
///
/// Sibling of `GoldenFleetTests`; reuses `GoldenFleetWorkspace`/`GoldenFleetClock`
/// helpers (never edits them).
final class AdversarialPinTests: XCTestCase {

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

    // MARK: - Local helpers

    private func makeRoot() -> URL {
        let root = GoldenFleetWorkspace.freshRoot()
        tmpDirs.append(root)
        return root
    }

    private func onlySummary(in dir: URL) throws -> DailySummary {
        let summaries = SummaryJSONParser.parseDirectory(dir)
        return try XCTUnwrap(summaries.first, "expected exactly one summary in \(dir.lastPathComponent)")
    }

    private func securityURL(_ dataDir: URL, stamp: String) -> URL {
        dataDir.appendingPathComponent("security", isDirectory: true)
            .appendingPathComponent("security_\(stamp).json")
    }

    /// A security summary whose per-control counts all equal `total` (no device
    /// sections → no proxy). Only `total_devices` matters for these pins.
    private func secPayload(total: Int) -> [[String: Any]] {
        GoldenFleetWorkspace.securitySummaryPayload(
            total: total, filevault: total, sip: total, firewall: total, gatekeeper: total)
    }

    /// Decode `[EAResultRow]` through the real `decodeSnapshot` bare-array path.
    private func decodeEARows(_ objs: [[String: Any]]) throws -> [EAResultRow] {
        let data = try JSONSerialization.data(withJSONObject: objs)
        let decoded = EAResultRow.decodeSnapshot(data)
        return try XCTUnwrap(decoded.rows, "bare array must decode; reason=\(decoded.reason)")
    }

    private func bandCount(_ result: MSCPComplianceService.BaselineResult, _ label: String) -> Int {
        result.bands.first { $0.label == label }?.count ?? -1
    }

    // MARK: - Pin 1 — duplicate title_id must not trap

    /// `releaseDateLookup` uses `uniquingKeysWith:` (first-writer-wins), NOT
    /// `uniqueKeysWithValues` which traps on a duplicate — a single duplicate
    /// disk row would otherwise take down the whole Patch screen.
    func testPin1_DuplicateTitleIdReleaseLookupKeepsFirstNoTrap() throws {
        let rows = [
            try decodeRow(id: "7", title: "Firefox", releaseDate: "2026-05-01T00:00:00Z"),
            try decodeRow(id: "7", title: "Firefox (dup)", releaseDate: "2026-06-09T00:00:00Z"),
        ]
        let lookup = PatchReleaseDateService.releaseDateLookup(from: rows)
        // Duplicate collapses to one entry; the FIRST writer's date wins.
        XCTAssertEqual(lookup.count, 1)
        XCTAssertEqual(lookup["7"], "2026-05-01T00:00:00Z")
    }

    private func decodeRow(id: String, title: String, releaseDate: String) throws
        -> PatchReleaseDateService.Row {
        let json = """
        {"title_id":"\(id)","title":"\(title)","latest_version":"1.0","release_date":"\(releaseDate)"}
        """
        return try JSONDecoder().decode(PatchReleaseDateService.Row.self, from: Data(json.utf8))
    }

    // MARK: - Pin 2 — filename beats mtime; age is by filename

    /// Two security snapshots whose FILENAME order and MTIME order DISAGREE. The
    /// digest picks the filename-newest (an mtime picker would pick the other),
    /// and the age gate also reads the filename, so an old-filename/fresh-mtime
    /// file is treated as expired.
    func testPin2_FilenameOverMtimePickAndAgeByFilename() throws {
        // --- Part A: which file wins the digest ---
        let root = makeRoot()
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let summariesDir = root.appendingPathComponent("summaries", isDirectory: true)

        // File A: NEWER filename (10 min ago), total 111, OLDER mtime (5h ago).
        let newerStamp = GoldenFleetClock.stamp(Date().addingTimeInterval(-600))
        let fileA = securityURL(dataDir, stamp: newerStamp)
        try GoldenFleetWorkspace.writeJSON(secPayload(total: 111), to: fileA)
        try GoldenFleetWorkspace.setModificationDate(fileA, to: Date().addingTimeInterval(-5 * 3600))

        // File B: OLDER filename (2h ago), total 222, NEWER mtime (now).
        let olderStamp = GoldenFleetClock.stamp(Date().addingTimeInterval(-2 * 3600))
        let fileB = securityURL(dataDir, stamp: olderStamp)
        try GoldenFleetWorkspace.writeJSON(secPayload(total: 222), to: fileB)
        try GoldenFleetWorkspace.setModificationDate(fileB, to: Date())

        ReportEngine(config: ReportConfig(), dataDir: dataDir)
            .emitSummaryJSON(summariesDir: summariesDir)
        let s = try onlySummary(in: summariesDir)
        // Filename-newest (A, total 111) wins. An mtime picker would return 222.
        XCTAssertEqual(s.totalDevices, 111,
                       "filename-newest snapshot wins despite its older mtime")

        // --- Part B: age is measured from the FILENAME, not mtime ---
        let ageRoot = makeRoot()
        let ageData = ageRoot.appendingPathComponent("data", isDirectory: true)
        let ageSummaries = ageRoot.appendingPathComponent("summaries", isDirectory: true)
        // Filename stamped 2h ago, but mtime freshly stamped NOW.
        let oldFilename = GoldenFleetClock.stamp(Date().addingTimeInterval(-2 * 3600))
        let ageFile = securityURL(ageData, stamp: oldFilename)
        try GoldenFleetWorkspace.writeJSON(secPayload(total: 100), to: ageFile)
        try GoldenFleetWorkspace.setModificationDate(ageFile, to: Date())

        var cfg = ReportConfig()
        var jamf = JamfCLIConfig()
        jamf.maxCacheAgeHours = 1          // 2h filename age > 1h limit → expired.
        cfg.jamfCli = jamf

        ReportEngine(config: cfg, dataDir: ageData).emitSummaryJSON(summariesDir: ageSummaries)
        XCTAssertTrue(SummaryJSONParser.parseDirectory(ageSummaries).isEmpty,
                      "age-by-filename (2h) exceeds max_cache_age_hours=1 → treated absent → no summary")
    }

    // MARK: - Pin 3 — string counts: "3.0" → 3 (Low), "3.9" → No Data

    /// `AnyCodable.intValue` accepts a whole-number Double string ("3.0" → 3) but
    /// rejects a fractional one ("3.9" → nil) rather than truncating to 3. The
    /// mSCP band derivation follows: the "3.0" device bands Low, the "3.9" device
    /// bands No Data — never a fabricated count of 3.
    func testPin3_StringMSCPCountBandsLowNotTruncated() throws {
        // Direct decode-layer pin.
        XCTAssertEqual(AnyCodable("3.0").intValue, 3, "whole-number string parses")
        XCTAssertNil(AnyCodable("3.9").intValue, "fractional string must NOT truncate to 3")

        // End-to-end band pin through the real evaluate path.
        let col = "NIST Failures"
        let rows = try decodeEARows([
            GoldenFleetWorkspace.eaRow(device: "mac-a", ea: col, value: "3.0"),
            GoldenFleetWorkspace.eaRow(device: "mac-b", ea: col, value: "3.9"),
        ])
        let baseline = ComplianceBaselineConfig(name: "NIST", failuresCountColumn: col)
        let r = try XCTUnwrap(
            MSCPComplianceService.evaluate(rows: rows, baselines: [baseline]).first)

        // Universe = 2 devices. mac-a (count 3) → Low; mac-b (unparseable) → No Data.
        XCTAssertEqual(r.totalDevices, 2)
        XCTAssertEqual(bandCount(r, "Low"), 1, "\"3.0\" → count 3 → Low band")
        XCTAssertEqual(bandCount(r, "Pass"), 0)
        XCTAssertEqual(bandCount(r, "High"), 0)
        XCTAssertEqual(r.noDataCount, 1, "\"3.9\" is unparseable → No Data, not banded as 3")
    }

    // MARK: - Pin 4 — patchPct excludes zero-device titles

    /// A 0-device patch title is dropped by the `total > 0` guard, so the
    /// unweighted mean is taken over the real title only.
    func testPin4_PatchPctZeroDeviceTitleExcluded() throws {
        let root = makeRoot()
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let summariesDir = root.appendingPathComponent("summaries", isDirectory: true)

        // Security snapshot so totalDevices > 0 (emit returns nil otherwise).
        try GoldenFleetWorkspace.writeJSON(
            secPayload(total: 100), to: securityURL(dataDir, stamp: GoldenFleetClock.stamp(anchor)))

        // Hand-built rows so the 0-device row carries the adversarial "0%" string.
        let patchRows: [[String: Any]] = [
            ["title": "A", "id": "1", "on_latest": 80, "on_other": 20,
             "total": 100, "latest": "1.0", "compliance_pct": "80.0"],
            ["title": "B", "id": "2", "on_latest": 0, "on_other": 0,
             "total": 0, "latest": "1.0", "compliance_pct": "0%"],
        ]
        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: anchor, rows: patchRows)

        ReportEngine(config: ReportConfig(), dataDir: dataDir)
            .emitSummaryJSON(summariesDir: summariesDir)
        let s = try onlySummary(in: summariesDir)

        // Only the total>0 title counts: mean over {80.0} = 80.0.
        // Without the guard, the "0%" title would drag it to (80 + 0) / 2 = 40.0.
        XCTAssertEqual(try XCTUnwrap(s.patchPct), 80.0, accuracy: 0.001)
    }

    // MARK: - Pin 5 — adoption clamps at 100

    /// jamf-cli can double-count devices across patch policies (on_latest > total).
    /// Adoption% is clamped at 100 — never charted above 100.
    func testPin5_AdoptionPctClampedAt100() throws {
        let root = makeRoot()
        let dataDir = root.appendingPathComponent("data", isDirectory: true)

        // on_latest 105 / total 100 → 105% raw → clamp 100.
        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: anchor,
            rows: [GoldenFleetWorkspace.patchRow(id: "1", title: "Firefox", onLatest: 105, total: 100)])

        let velocities = PatchVelocityBuilder.compute(dataDir: dataDir, releaseRows: [], now: anchor)
        let v = try XCTUnwrap(velocities.first { $0.titleId == "1" })
        // min(105/100 * 100, 100) = 100.0 — never 105.
        XCTAssertEqual(try XCTUnwrap(v.adoptionPct), 100.0, accuracy: 0.001)
        XCTAssertEqual(v.series.count, 1)
        XCTAssertEqual(v.series[0].adoptionPct, 100.0, accuracy: 0.001,
                       "series point is clamped, not 105")
    }

    // MARK: - Pin 6 — strict-inequality thresholds (accepted semantics)

    /// below/above/drops_more_than all use STRICT inequality: an exactly-equal
    /// value never fires.
    func testPin6_ThresholdStrictInequalityNoFireAtBoundary() throws {
        let current = DailySummary(
            date: "2026-06-02", totalDevices: 100,
            fileVaultPct: 90.0, compliancePct: nil, staleCount: 50,
            osCurrentPct: nil, crowdstrikePct: nil, patchPct: 75.0, source: "test")
        // patch drop = 80 - 75 = 5.0 exactly.
        let prior = DailySummary(
            date: "2026-06-01", totalDevices: 100,
            fileVaultPct: nil, compliancePct: nil, staleCount: nil,
            osCurrentPct: nil, crowdstrikePct: nil, patchPct: 80.0, source: "test")

        let rules: [AlertRule] = [
            AlertRule(metric: "filevault_pct", when: "below", threshold: 90),        // 90 < 90 false
            AlertRule(metric: "stale_count", when: "above", threshold: 50),           // 50 > 50 false
            AlertRule(metric: "patch_pct", when: "drops_more_than", threshold: 5),    // 5 > 5 false
        ]
        let hits = MetricAlertEvaluator.evaluate(rules: rules, current: current, prior: prior)
        XCTAssertTrue(hits.isEmpty, "exact-boundary values must NOT fire under strict inequality")
    }

    // MARK: - Pin 7 — rule_count validity boundary

    /// A count equal to `ruleCount` is valid (all rules failed → banded normally);
    /// a count of `ruleCount + 1` is garbage → No Data. `ruleCount` is chosen > 50
    /// so the valid boundary count lands in the High band.
    func testPin7_RuleCountBoundaryValidVsNoData() throws {
        let col = "NIST Failures"
        let ruleCount = 60
        let rows = try decodeEARows([
            GoldenFleetWorkspace.eaRow(device: "mac-a", ea: col, value: 60),   // == ruleCount → valid → High
            GoldenFleetWorkspace.eaRow(device: "mac-b", ea: col, value: 61),   // ruleCount+1 → invalid → No Data
        ])
        let baseline = ComplianceBaselineConfig(
            name: "NIST", failuresCountColumn: col, ruleCount: ruleCount)
        let r = try XCTUnwrap(
            MSCPComplianceService.evaluate(rows: rows, baselines: [baseline]).first)

        XCTAssertEqual(r.totalDevices, 2)
        XCTAssertEqual(bandCount(r, "High"), 1, "count == rule_count is valid → High (60 > 50)")
        XCTAssertEqual(r.noDataCount, 1, "count == rule_count + 1 is out-of-bound → No Data")
    }

    // MARK: - Pin 8 — band boundaries

    /// Exhaustive band-boundary map. Negative → No Data; then the inclusive ranges
    /// Pass(0)/Low(1–10)/Med-Low(11–30)/Medium(31–50)/High(>50).
    func testPin8_BandBoundaries() {
        typealias B = ComplianceBandingService.Band
        // failures : expected band label (edges + one-past each edge)
        let cases: [(Int, String)] = [
            (-1, "No Data"),
            (0,  "Pass"),
            (1,  "Low"),
            (10, "Low"),
            (11, "Med-Low"),
            (30, "Med-Low"),
            (31, "Medium"),
            (50, "Medium"),
            (51, "High"),
        ]
        for (failures, expected) in cases {
            XCTAssertEqual(B.from(failures: failures).label, expected,
                           "failures=\(failures) should band as \(expected)")
        }
    }

    // MARK: - Pin 9 — security-score clamp + renormalization

    /// A compliant count exceeding the device total contributes exactly 100
    /// (clamped, not 109); the score renormalizes over only the available metrics.
    func testPin9_SecurityScoreClampAndRenormalization() {
        // Clamp in isolation: 655 / 600 = 109.17% → clamped 100.
        // Single metric → score = (100 * 15) / 15 = 100.0 (an unclamped value
        // would surface 109.17).
        let clampOnly = SecurityScoreCalculator.score(
            input: .init(totalDevices: 600, compliantCounts: [.fileVault: 655]))
        XCTAssertEqual(clampOnly.value, 100.0, accuracy: 0.001,
                       "655/600 clamps to 100, not 109.17")
        XCTAssertEqual(clampOnly.available, [.fileVault])

        // Renormalization: fileVault (clamped 100, weight 15) + sip (50, weight 15).
        // score = (100*15 + 50*15) / (15 + 15) = 2250 / 30 = 75.0 over the two
        // AVAILABLE metrics only (the other six weights are dropped).
        let renorm = SecurityScoreCalculator.score(
            input: .init(totalDevices: 600, compliantCounts: [.fileVault: 655, .sip: 300]))
        XCTAssertEqual(renorm.value, 75.0, accuracy: 0.001)
        XCTAssertEqual(renorm.available.count, 2)
        XCTAssertEqual(renorm.missing.count, 6, "six metrics absent → dropped from the denominator")
    }

    // MARK: - Pin 10 — salvage byte-scanner adversarial fixtures

    /// (a) A valid element followed by a truncated object whose partial string
    /// contains a `}` and an escaped quote — the string/escape-aware scanner keeps
    /// exactly the one complete element.
    func testPin10a_SalvageIgnoresBraceAndEscapeInsideString() throws {
        // Raw string: `\"` is a literal backslash+quote (JSON escaped quote inside
        // the unterminated trailing string value).
        let raw = #"[{"device":"a","ea_name":"x","value":0},{"device":"b","ea_name":"note}h\"i"#
        let decoded = EAResultRow.decodeSnapshot(Data(raw.utf8))
        let rows = try XCTUnwrap(decoded.rows, "must salvage the one complete element")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.device, "a")
        XCTAssertTrue(decoded.reason.hasPrefix("salvaged"), "reason=\(decoded.reason)")
    }

    /// (b) Zero complete elements → nil (nothing to salvage).
    func testPin10b_SalvageZeroCompleteElementsIsNil() {
        let raw = #"[{"device":"a""#
        let decoded = EAResultRow.decodeSnapshot(Data(raw.utf8))
        XCTAssertNil(decoded.rows, "no depth-1 object closed → nothing to salvage")
    }

    /// (c) A complete element that itself contains a nested object AND array, then
    /// truncation — the nested element salvages intact.
    func testPin10c_SalvageKeepsNestedCompleteElement() throws {
        let raw = #"[{"device":"a","ea_name":"x","value":0,"meta":{"k":[1,2]}},{"device":"b""#
        let decoded = EAResultRow.decodeSnapshot(Data(raw.utf8))
        let rows = try XCTUnwrap(decoded.rows, "nested complete element must salvage")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.device, "a")
        XCTAssertTrue(decoded.reason.hasPrefix("salvaged"), "reason=\(decoded.reason)")
    }

    // MARK: - Pin 11 — envelope truncation is NOT salvaged (documented limit)

    /// Salvage is bare-array-only. A truncated `{"results":[...` envelope yields
    /// nil, not a partial recovery.
    func testPin11_TruncatedEnvelopeNotSalvaged() {
        let raw = #"{"results":[{"device":"a","ea_name":"x","value":0},{"device":"b""#
        let decoded = EAResultRow.decodeSnapshot(Data(raw.utf8))
        XCTAssertNil(decoded.rows, "salvage is bare-array-only; truncated envelopes are not recovered")
    }

    // MARK: - Pin 12 — daysTo50 is the first OBSERVED crossing (not interpolated)

    /// Snapshots exist only at day0 (20%) and day30 (95%), release at day0. The
    /// first sample at/above 50% is the day30 sample, so daysTo50 == 30 — the
    /// engine reports the observed crossing and deliberately does NOT interpolate
    /// an earlier ~day10 crossing.
    func testPin12_SparseSeriesDaysTo50IsObservedCrossing() throws {
        let root = makeRoot()
        let dataDir = root.appendingPathComponent("data", isDirectory: true)

        func ts(_ off: Int) -> Date {
            GoldenFleetClock.timestamp(dayOffset: off, hour: 12, minute: 0, relativeTo: anchor)
        }

        // Release at day-40; first snapshot on the release day (20%), next at day-10 (95%).
        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: ts(-40),
            rows: [GoldenFleetWorkspace.patchRow(id: "1", title: "Firefox", onLatest: 20, total: 100)])
        try GoldenFleetWorkspace.writePatchStatus(dataDir: dataDir, at: ts(-10),
            rows: [GoldenFleetWorkspace.patchRow(id: "1", title: "Firefox", onLatest: 95, total: 100)])

        let releaseISO = GoldenFleetClock.isoLocal(ts(-40))
        let release = try JSONDecoder().decode(
            PatchReleaseDateService.Row.self,
            from: Data(#"{"title_id":"1","title":"Firefox","latest_version":"1.0","release_date":"\#(releaseISO)"}"#.utf8))

        let velocities = PatchVelocityBuilder.compute(
            dataDir: dataDir, releaseRows: [release], now: anchor)
        let v = try XCTUnwrap(velocities.first { $0.titleId == "1" })

        // First >=50 sample is at day-10. Crossing - release = (-10) - (-40) = 30.
        XCTAssertEqual(v.daysTo50, 30,
                       "observed crossing at the day-10 sample, NOT an interpolated ~day-10-from-release value")
        // Same sample is the first >=90 too: (-10) - (-40) = 30.
        XCTAssertEqual(v.daysTo90, 30)
        XCTAssertEqual(try XCTUnwrap(v.adoptionPct), 95.0, accuracy: 0.001)
    }
}
