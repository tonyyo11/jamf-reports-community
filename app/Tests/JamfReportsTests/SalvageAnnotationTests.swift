import Foundation
import XCTest
@testable import JamfReports

/// Covers the 2.6 accuracy-track guarantee: a SALVAGED day (recovered from a
/// 16KB-truncated ea-results file by `EAResultRow.decodeSnapshot`'s salvage
/// path) must never silently read as fleet change.
///
///  A. `MSCPChartDataBuilder.BandPoint.isSalvaged` flags salvaged days so
///     `TrendsView` can annotate them.
///  B. `EAParseHealthService.coverageDrift` excludes a salvaged day from the
///     two-newest-days comparison — a truncated day fabricates drift.
final class SalvageAnnotationTests: XCTestCase {

    #if DEBUG

    nonisolated(unsafe) private var testRoot: URL!
    nonisolated(unsafe) private var workspacesRoot: URL!
    nonisolated(unsafe) private var workspace: URL!
    nonisolated(unsafe) private var dataDir: URL!
    nonisolated(unsafe) private var eaResultsDir: URL!
    private let profileSlug = "salvage-annotation-test"

    override func setUpWithError() throws {
        try super.setUpWithError()
        testRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SalvageAnnotation-\(UUID().uuidString)", isDirectory: true)
        workspacesRoot = testRoot.appendingPathComponent("Jamf-Reports", isDirectory: true)
        workspace = workspacesRoot.appendingPathComponent(profileSlug, isDirectory: true)
        dataDir = workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
        eaResultsDir = dataDir.appendingPathComponent("ea-results", isDirectory: true)
        try FileManager.default.createDirectory(at: eaResultsDir, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        if let root = testRoot {
            try? FileManager.default.removeItem(at: root)
        }
        testRoot = nil
        workspacesRoot = nil
        workspace = nil
        dataDir = nil
        eaResultsDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixture builders

    /// A valid bare-array `[EAResultRow]` payload for `count` devices, all
    /// carrying `ea_name: column` with `value: 0` (Pass band).
    private func intactPayload(column: String, count: Int) -> Data {
        let rows = (0..<count).map { i in
            #"{"device":"mac-\#(i)","ea_name":"\#(column)","value":0}"#
        }
        let json = "[" + rows.joined(separator: ",") + "]"
        return Data(json.utf8)
    }

    /// Truncate a valid bare-array payload mid-record: cut after the LAST
    /// complete top-level object (dropping the closing `]` and any bytes of a
    /// following partial object), mirroring the real 16KB pipe-boundary bug.
    private func truncateMidRecord(_ intact: Data, keepRecords: Int) -> Data {
        // Re-derive the byte offset of the `keepRecords`-th object's closing
        // brace by re-serializing just that many objects, then appending a
        // few garbage bytes of a partial next record (no closing brace/bracket)
        // to faithfully reproduce "cut mid-element", not "cut cleanly".
        let json = String(data: intact, encoding: .utf8)!
        // Find the end of the `keepRecords`-th `}` at nesting depth 1.
        var depth = 0
        var closeIndices: [String.Index] = []
        var idx = json.startIndex
        while idx < json.endIndex {
            let ch = json[idx]
            if ch == "[" || ch == "{" { depth += 1 }
            if ch == "]" || ch == "}" {
                depth -= 1
                if ch == "}" && depth == 1 { closeIndices.append(idx) }
            }
            idx = json.index(after: idx)
        }
        precondition(closeIndices.count >= keepRecords, "fixture must have enough records")
        let cutAfter = closeIndices[keepRecords - 1]
        let kept = String(json[json.startIndex...cutAfter])
        // Append a comma + a partial (unterminated) next object — no closing
        // `}` or `]` — so the payload is a genuinely truncated bare array.
        return Data((kept + #","{"device":"mac-cut"#).utf8)
    }

    private func writeFile(_ data: Data, name: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name))
    }

    // MARK: - A0: prove the fixture actually salvages (guards the whole suite)

    func testTruncatedFixtureActuallyTriggersSalvagePath() throws {
        let intact = intactPayload(column: "EA - Failures", count: 5)
        let truncated = truncateMidRecord(intact, keepRecords: 3)

        let decoded = EAResultRow.decodeSnapshot(truncated)
        let rows = try XCTUnwrap(decoded.rows, "salvage must recover the 3 complete records")
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(
            EAResultRow.isSalvageReason(decoded.reason),
            "reason '\(decoded.reason)' must be classified as a salvage"
        )

        // Sanity: the INTACT payload must NOT be flagged as salvaged.
        let intactDecoded = EAResultRow.decodeSnapshot(intact)
        XCTAssertEqual(intactDecoded.rows?.count, 5)
        XCTAssertFalse(EAResultRow.isSalvageReason(intactDecoded.reason))
    }

    // MARK: - A: BandPoint.isSalvaged

    func testBandPointFlaggedSalvagedForTruncatedFileAndCleanForIntactFile() throws {
        let column = "EA - Failures"
        let baseline = ComplianceBaselineConfig(name: column, failuresCountColumn: column, ruleCount: nil)

        // Intact day: 20240101.
        let intact = intactPayload(column: column, count: 5)
        try writeFile(intact, name: "ea-results_20240101T080000.json", in: eaResultsDir)

        // Salvaged (truncated) day: 20240102.
        let truncated = truncateMidRecord(intactPayload(column: column, count: 6), keepRecords: 4)
        try writeFile(truncated, name: "ea-results_20240102T080000.json", in: eaResultsDir)

        let points = MSCPChartDataBuilder.buildSeries(
            baseline: baseline, dataDir: dataDir, summaries: [])

        XCTAssertEqual(points.count, 2)
        let intactPoint = try XCTUnwrap(points.first)
        let salvagedPoint = try XCTUnwrap(points.last)
        XCTAssertFalse(intactPoint.isSalvaged, "the intact day's point must not be flagged")
        XCTAssertTrue(salvagedPoint.isSalvaged, "the truncated/salvaged day's point must be flagged")

        // salvagedDates() surfaces exactly the salvaged day.
        let salvagedDates = MSCPChartDataBuilder.salvagedDates(in: points)
        XCTAssertEqual(salvagedDates, [salvagedPoint.date])
    }

    func testTrendStoreSurfacesSalvagedDateThroughFileBasedAPI() throws {
        let column = "mSCP Failures"

        // Seed summaries carrying mscpBands so `fallbackBaselines` discovers
        // this baseline name (no config.yaml needed — computeSnapshot degrades
        // to the summary-derived fallback baseline list).
        //
        // `salvagedBandDates` / `mscpStackedSeries()` range-filter band points
        // to `filteredSummaries.first.parsedDate ... last.parsedDate` — the
        // actual summary-date SPAN, not `Date()`-relative. Two constraints
        // this fixture must satisfy, both confirmed against the real
        // formatters (SummaryJSONParser.dateFormatter / CloudStorage's
        // snapshot stamp formatter — neither pins an explicit time zone, both
        // resolve "yyyy-MM-dd" to LOCAL midnight):
        //   1. A single summary date collapses the range to one instant,
        //      filtering out any ea-results point on a DIFFERENT calendar
        //      day — so summaries must span every day an ea-results file
        //      is dated (2024-01-01 AND 2024-01-02).
        //   2. Each ea-results snapshot filename carries a time-of-day
        //      (08:00:00 here); a summary dated exactly on the LATEST
        //      ea-results day only brackets up to that day's local midnight
        //      (00:00:00), which is BEFORE 08:00:00 and would still filter
        //      the point out. The summary span must extend one calendar day
        //      PAST the last ea-results file (2024-01-03) so `rangeEnd`
        //      (that day's midnight) falls after every same-day timestamp.
        let summariesDir = workspace
            .appendingPathComponent("snapshots/summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)
        let bands = MSCPBandCounts(pass: 5, low: 0, medLow: 0, medium: 0, high: 0, noData: 0)
        for date in ["2024-01-01", "2024-01-02", "2024-01-03"] {
            let summary = DailySummary(
                date: date, totalDevices: 5,
                fileVaultPct: nil, compliancePct: nil, staleCount: 0,
                osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
                source: "jamf-cli", mscpBands: [column: bands]
            )
            let summaryData = try JSONEncoder().encode(summary)
            try summaryData.write(to: summariesDir.appendingPathComponent("summary_\(date).json"))
        }

        // Intact day (2024-01-01) + a salvaged day (2024-01-02) — both now
        // strictly inside the filtered-summaries date span
        // [2024-01-01T00:00, 2024-01-03T00:00].
        try writeFile(intactPayload(column: column, count: 5),
                      name: "ea-results_20240101T080000.json", in: eaResultsDir)
        let truncated = truncateMidRecord(intactPayload(column: column, count: 6), keepRecords: 4)
        try writeFile(truncated, name: "ea-results_20240102T080000.json", in: eaResultsDir)

        let snapshot = TrendStore.computeSnapshot(profile: profileSlug)
        XCTAssertTrue(snapshot.baselineNames.contains(column))

        let series = try XCTUnwrap(snapshot.bandSeries[column])
        let salvagedDates = MSCPChartDataBuilder.salvagedDates(in: series)
        XCTAssertEqual(salvagedDates.count, 1, "exactly the truncated day must be flagged")

        // Drive it through the TrendStore instance surface too (apply/salvagedBandDates).
        let store = TrendStore()
        let generation = store.beginLoading()
        store.apply(snapshot, profile: profileSlug, range: .all, generation: generation)
        store.selectMSCPBaseline(column)
        XCTAssertEqual(store.salvagedBandDates, salvagedDates)
    }

    // MARK: - B: coverageDrift skips a salvaged newest day

    func testCoverageDriftSkipsSalvagedNewestDay() throws {
        // Three dated files: old (intact, FileVault 100% of 2), mid (intact,
        // FileVault 50% of 2 — a real coverage drop), newest (salvaged, would
        // read as FileVault 100% of a DIFFERENT device set if it were allowed
        // to participate). Drift must compare old vs mid only — if the
        // salvaged newest day leaked in as "current", FileVault would read
        // 100% (its intact rows are all non-empty) instead of mid's real 50%.
        let oldPayload = Data(
            #"[{"device":"Mac1","ea_name":"FileVault","value":"Encrypted"},{"device":"Mac2","ea_name":"FileVault","value":"Encrypted"}]"#.utf8
        )
        try writeFile(oldPayload, name: "ea-results_20260601T080000.json", in: eaResultsDir)

        let midPayload = Data(
            #"[{"device":"Mac1","ea_name":"FileVault","value":"Encrypted"},{"device":"Mac2","ea_name":"FileVault","value":""}]"#.utf8
        )
        try writeFile(midPayload, name: "ea-results_20260602T080000.json", in: eaResultsDir)

        // Newest day: build a valid multi-row payload then truncate mid-record
        // so it decodes ONLY via the salvage path. Every recovered row is
        // non-empty FileVault, so a leak would show up as 100% current.
        let newestIntact = intactPayload(column: "FileVault", count: 6)
        let newestSalvaged = truncateMidRecord(newestIntact, keepRecords: 4)
        // Confirm precondition: this file salvages, not decodes cleanly.
        let precheck = EAResultRow.decodeSnapshot(newestSalvaged)
        XCTAssertTrue(EAResultRow.isSalvageReason(precheck.reason))
        try writeFile(newestSalvaged, name: "ea-results_20260603T080000.json", in: eaResultsDir)

        let drift = EAParseHealthService.coverageDrift(dataDir: dataDir)
        let byName = Dictionary(uniqueKeysWithValues: drift.map { ($0.eaName, $0) })

        // old (100%) vs mid (50%) — the salvaged newest day must never surface
        // as "current" (which would read 100%, masking the real drop).
        let fv = try XCTUnwrap(byName["FileVault"])
        XCTAssertEqual(fv.previousPct, 100, accuracy: 0.001, "must compare OLD (previous), not the salvaged newest day")
        XCTAssertEqual(fv.currentPct, 50, accuracy: 0.001, "must compare MID (current), not the salvaged newest day")
    }

    func testCoverageDriftReturnsEmptyWhenOnlyTwoDaysAndNewestIsSalvaged() throws {
        // Only two distinct days exist; the newest is salvaged, so after
        // skipping it only ONE decodable day remains -> fewer than two -> [].
        let oldPayload = Data(
            #"[{"device":"Mac1","ea_name":"FileVault","value":"Encrypted"}]"#.utf8
        )
        try writeFile(oldPayload, name: "ea-results_20260601T080000.json", in: eaResultsDir)

        let newestIntact = intactPayload(column: "FileVault", count: 6)
        let newestSalvaged = truncateMidRecord(newestIntact, keepRecords: 4)
        try writeFile(newestSalvaged, name: "ea-results_20260602T080000.json", in: eaResultsDir)

        XCTAssertEqual(EAParseHealthService.coverageDrift(dataDir: dataDir), [])
    }

    #endif
}
