import XCTest
@testable import JamfReports

/// Pure-logic coverage for the extracted scheduled-run trust signals: the
/// metric-aware strict-prior selection (shared by the scheduled path and the
/// CLI) and the included-CLI signal seams (label construction + alert gating).
/// No live webhook or process is exercised.
final class ScheduledRunSignalsTests: XCTestCase {

    // MARK: - Helpers

    /// A summary on `date` (yyyy-MM-dd) with an optional `patch_pct` — the metric
    /// used to exercise the metric-aware branch. All other metrics stay nil.
    private func summary(_ date: String, patchPct: Double?) -> DailySummary {
        DailySummary(
            date: date, totalDevices: 100,
            fileVaultPct: nil, compliancePct: nil, staleCount: nil,
            osCurrentPct: nil, crowdstrikePct: nil, patchPct: patchPct
        )
    }

    // MARK: - strictPrior

    func testStrictPriorPrefersOlderSummaryCarryingTheMetric() throws {
        // Both candidates are age-eligible (<= lookback old); the NEWER one lacks
        // the metric, the OLDER one carries it — metric-aware picks the older.
        let current = summary("2026-07-10", patchPct: 70)
        let candidates = [
            summary("2026-07-03", patchPct: 80),   // eligible, has patch
            summary("2026-07-05", patchPct: nil),  // eligible, no patch (newest eligible)
        ]
        let prior = ScheduledRunSignals.strictPrior(
            candidates: candidates, current: current,
            metrics: [.patchPct], lookbackDays: 5
        )
        XCTAssertEqual(try XCTUnwrap(prior).date, "2026-07-03")
    }

    func testStrictPriorFallsBackToNewestEligibleWhenMetricAbsentEverywhere() throws {
        // No eligible candidate carries the metric → plain age-filtered newest.
        let current = summary("2026-07-10", patchPct: 70)
        let candidates = [
            summary("2026-07-03", patchPct: nil),
            summary("2026-07-05", patchPct: nil),  // newest eligible
        ]
        let prior = ScheduledRunSignals.strictPrior(
            candidates: candidates, current: current,
            metrics: [.patchPct], lookbackDays: 5
        )
        XCTAssertEqual(try XCTUnwrap(prior).date, "2026-07-05")
    }

    func testStrictPriorNeverSelectsAYoungerSummaryEvenIfItCarriesTheMetric() throws {
        // The metric-carrying summary is INSIDE the lookback window (too young);
        // only the older nil-metric summary is eligible. Must not fall forward.
        let current = summary("2026-07-10", patchPct: 70)
        let candidates = [
            summary("2026-07-03", patchPct: nil),  // eligible (7d old), no patch
            summary("2026-07-08", patchPct: 90),   // too young (2d old), has patch
        ]
        let prior = ScheduledRunSignals.strictPrior(
            candidates: candidates, current: current,
            metrics: [.patchPct], lookbackDays: 5
        )
        XCTAssertEqual(try XCTUnwrap(prior).date, "2026-07-03")
    }

    func testStrictPriorWithNoDropMetricsReturnsNewestEligible() throws {
        // Empty metric set (a below/above-only group) → identical to the plain
        // age-filtered pick, preserving pre-refinement behavior.
        let current = summary("2026-07-10", patchPct: 70)
        let candidates = [
            summary("2026-07-01", patchPct: 80),
            summary("2026-07-04", patchPct: nil),  // newest eligible
        ]
        let prior = ScheduledRunSignals.strictPrior(
            candidates: candidates, current: current,
            metrics: [], lookbackDays: 5
        )
        XCTAssertEqual(try XCTUnwrap(prior).date, "2026-07-04")
    }

    func testStrictPriorReturnsNilWhenNoSummaryIsOldEnough() {
        let current = summary("2026-07-10", patchPct: 70)
        let candidates = [summary("2026-07-08", patchPct: 80)]  // only 2d old
        let prior = ScheduledRunSignals.strictPrior(
            candidates: candidates, current: current,
            metrics: [.patchPct], lookbackDays: 5
        )
        XCTAssertNil(prior)
    }

    // MARK: - evaluateHits (metric-aware prior feeding a drops_more_than rule)

    func testDropRuleFiresAgainstOlderSummaryThatCarriesTheMetric() throws {
        // The immediate prior lacks patch_pct; the older one has 90. A 20pp fall
        // to 70 must be measured against the older 90, not skipped for the nil day.
        let current = summary("2026-07-10", patchPct: 70)
        let history = [
            summary("2026-07-03", patchPct: 90),   // eligible, carries the metric
            summary("2026-07-05", patchPct: nil),  // eligible, missing the metric
            current,
        ]
        let rule = AlertRule(
            metric: "patch_pct", when: "drops_more_than", threshold: 10, lookbackDays: 5)
        let hits = ScheduledRunSignals.evaluateHits(
            rules: [rule], current: current, history: history)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(try XCTUnwrap(hits.first?.prior), 90)
    }

    // MARK: - CLIRunSignals seams

    func testCLILabelsAreDistinctAndValid() {
        let collect = CLIRunSignals.cliLabel(profile: "prod", kind: .collect)
        let generate = CLIRunSignals.cliLabel(profile: "prod", kind: .generate)
        XCTAssertEqual(collect, "\(LaunchAgentWriter.labelPrefix).prod.cli-collect")
        XCTAssertEqual(generate, "\(LaunchAgentWriter.labelPrefix).prod.cli-generate")
        // Distinct labels so Run History never conflates the two run kinds, and
        // both must pass the recorder's label-prefix validation (otherwise the
        // recorder silently rejects them and the run stays invisible).
        XCTAssertNotEqual(collect, generate)
        XCTAssertTrue(LaunchAgentWriter.isValidLabel(collect))
        XCTAssertTrue(LaunchAgentWriter.isValidLabel(generate))
    }

    func testOnlyCollectEvaluatesAlerts() {
        XCTAssertTrue(CLIRunSignals.evaluatesAlerts(for: .collect))
        XCTAssertFalse(CLIRunSignals.evaluatesAlerts(for: .generate))
    }

    func testCLIRunModeMirrorsScheduledSemantics() {
        // collect → snapshot-only (produces a fresh summary, evaluates alerts);
        // generate → jamf-cli-only (from cache, no alerts).
        XCTAssertEqual(CLIRunSignals.mode(for: .collect), .snapshotOnly)
        XCTAssertEqual(CLIRunSignals.mode(for: .generate), .jamfCLIOnly)
    }

    // MARK: - partialRunMarker

    func testPartialRunMarkerMatchesScheduledPathFormat() {
        // Kept byte-identical to main.swift's scheduledRunSingle marker so
        // RunHistoryService.isPartialRun's "[partial]" scan recognizes both.
        XCTAssertEqual(
            partialRunMarker(sheetFailures: 3),
            "[partial] 3 sheet failure(s) — see lines above"
        )
    }

    func testPartialRunMarkerContainsThePartialTagRunHistoryScansFor() {
        XCTAssertTrue(partialRunMarker(sheetFailures: 1).contains("[partial]"))
    }
}
