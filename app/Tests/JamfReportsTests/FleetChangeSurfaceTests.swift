import XCTest
@testable import JamfReports

/// Where the change counts show (wave B2a): the digest's `Changes` fact, the Overview's
/// "Since last collect" section and the demo fleet's figures.
@MainActor
final class FleetChangeSurfaceTests: XCTestCase {

    private func day(
        _ date: String, changes: FleetChangeSummary? = nil, agents: [String: Double]? = nil
    ) throws -> DailySummary {
        var json = #"{"date":"\#(date)","totalDevices":10,"source":"jamf-cli""#
        if let agents {
            let data = try JSONSerialization.data(withJSONObject: agents)
            json += #","securityAgentCoverage":"# + String(decoding: data, as: UTF8.self)
        }
        var summary = try SummaryJSONParser.decode(Data((json + "}").utf8))
        summary.changes = changes
        return summary
    }

    private let counts = FleetChangeSummary(computers: ComputerChanges(
        currentCount: 10, priorCount: 9, joined: 2, left: 1, osChanged: 0, becameStale: 0,
        noLongerStale: 0, fileVaultOff: 1, fileVaultStoppedReporting: 0))

    // MARK: - Digest

    func testChangesTextForms() {
        XCTAssertEqual(ScheduledRunSignals.changesText(counts),
                       "2 enrolled, 1 removed, 1 FileVault off")
        let none = FleetChangeSummary(computers: ComputerChanges(
            currentCount: 3, priorCount: 3, joined: 0, left: 0, becameStale: 0,
            noLongerStale: 0, fileVaultOff: 0, fileVaultStoppedReporting: 0))
        XCTAssertEqual(ScheduledRunSignals.changesText(none), "No changes")
        let unreadable = FleetChangeSummary(computers: ComputerChanges(baselineUnreadable: true))
        XCTAssertEqual(ScheduledRunSignals.changesText(unreadable), "Changes not measured")
        let rules = FleetChangeSummary(benchmarks: BenchmarkChanges(newlyFailing: 3))
        XCTAssertEqual(ScheduledRunSignals.changesText(rules), "3 benchmark rules newly failing")
        XCTAssertNil(ScheduledRunSignals.changesText(FleetChangeSummary()))
    }

    func testChangesFactFullDetailOnly() {
        let full = successFacts(detail: .full, profile: "p", mode: .snapshotOnly,
                                artifact: nil, sheetFailures: 0, changes: counts)
        XCTAssertEqual(full.last?.label, "Changes")
        let minimal = successFacts(detail: .minimal, profile: "p", mode: .snapshotOnly,
                                   artifact: nil, sheetFailures: 0, changes: counts)
        XCTAssertFalse(minimal.contains { $0.label == "Changes" })
    }

    func testDigestChangesOnlyWhenNewestIsToday() throws {
        let summaries = [try day("2026-11-01", changes: counts), try day("2026-11-02")]
        XCTAssertNil(ScheduledRunSignals.digestChanges(summaries: summaries, today: "2026-11-02"))
        XCTAssertNil(ScheduledRunSignals.digestChanges(summaries: summaries, today: "2026-11-03"))
        XCTAssertEqual(ScheduledRunSignals.digestChanges(
            summaries: [try day("2026-11-02", changes: counts)], today: "2026-11-02"), counts)
    }

    // MARK: - Overview

    func testOverviewChangesUsesNewestPartAndAgentShares() throws {
        let summaries = [
            try day("2026-10-31", agents: ["Falcon": 40, "Santa": 90, "Old": 10]),
            try day("2026-11-01", changes: counts),
            try day("2026-11-02", agents: ["Santa": 90.04, "Falcon": 43, "New": 70]),
        ]
        let built = try XCTUnwrap(OverviewChanges.build(summaries: summaries, format: .standard))
        XCTAssertEqual(built.day, "2026-11-01")
        XCTAssertEqual(built.computerRows.first?.value, "2")
        XCTAssertEqual(built.agents, [OverviewChanges.Row(label: "Falcon", value: "40.0% → 43.0%")],
                       "one-sided and unchanged agents are left out")
        XCTAssertNil(OverviewChanges.build(summaries: [try day("2026-11-02")], format: .standard))
    }

    func testOverviewRowsAndNotes() {
        let notMeasured = OverviewChanges(
            day: "d", computers: ComputerChanges(joined: 1, left: 0), benchmarks: nil, patch: nil, agents: [])
        XCTAssertTrue(notMeasured.computerRows.contains {
            $0.label == "Went stale" && $0.value == "Not measured" })
        let tooLarge = OverviewChanges(
            day: "d", computers: ComputerChanges(
                baselineUnreadable: true, baselineUnreadableReason: .tooLarge),
            benchmarks: nil, patch: nil, agents: [])
        XCTAssertTrue(tooLarge.computerRows.isEmpty)
        XCTAssertEqual(tooLarge.computerNote, "Could not be read: over the 256 MB limit")
        let undecodable = OverviewChanges(
            day: "d", computers: ComputerChanges(
                baselineUnreadable: true, baselineUnreadableReason: .undecodable),
            benchmarks: nil, patch: nil, agents: [])
        XCTAssertEqual(undecodable.computerNote, "Could not be read: the file did not decode")
    }

    func testChangesSectionPlacementAndAvailability() {
        XCTAssertEqual(OverviewSection.allCases.prefix(2), [.aiInsight, .changes])
        XCTAssertTrue(OverviewSection.changes.availability(in: .mixed).isShown)
        XCTAssertEqual(OverviewSection.changes.availability(in: .mixed, hasJamfPro: false).reason,
                       "Needs Jamf Pro.")
        XCTAssertFalse(OverviewSection.changes.availability(in: .mobileOnly).isShown)
    }

    func testSavedLayoutGetsChangesAtTheEnd() {
        let saved = OverviewSection.allCases.filter { $0 != .changes }
        XCTAssertEqual(OverviewLayout(order: saved).order.last, .changes)
    }

    // MARK: - Patch (B2b)

    private let patch = FleetChangeSummary(patch: PatchChanges(
        currentStamp: "20261101T060000", startedFailing: 2, stoppedFailing: 0,
        leftOut: 0, notInComputers: 0))

    func testPatchDigestText() {
        XCTAssertEqual(ScheduledRunSignals.changesText(patch), "2 started failing a patch policy")
        let quiet = FleetChangeSummary(patch: PatchChanges(startedFailing: 0, stoppedFailing: 0))
        XCTAssertNil(ScheduledRunSignals.changesText(quiet), "an all-zero part adds nothing")
    }

    /// Mac counts come every two days and patch scans weekly: each part is read from the
    /// newest summary that has it, in both directions.
    func testEachPartComesFromTheNewestSummaryThatHasIt() throws {
        let built = try XCTUnwrap(OverviewChanges.build(summaries: [
            try day("2026-11-01", changes: patch),
            try day("2026-11-02", changes: counts),
        ], format: .standard))
        XCTAssertEqual(built.day, "2026-11-02")
        XCTAssertEqual(built.patchRows.first?.value, "2")
        XCTAssertEqual(built.patchScanDay, "2026-11-01")

        let mirrored = try XCTUnwrap(OverviewChanges.build(summaries: [
            try day("2026-11-01", changes: counts),
            try day("2026-11-02", changes: patch),
        ], format: .standard))
        XCTAssertEqual(mirrored.day, "2026-11-01", "a patch-only day keeps the Mac rows")
        XCTAssertEqual(mirrored.computerRows.first?.value, "2")
    }

    func testOldPatchPartIsNotShown() throws {
        let built = try XCTUnwrap(OverviewChanges.build(summaries: [
            try day("2026-10-10", changes: patch),
            try day("2026-10-30", changes: counts),
        ], format: .standard))
        XCTAssertNil(built.patch)
        XCTAssertTrue(built.patchRows.isEmpty)
    }

    func testPatchAgeLimitBoundary() throws {
        func shows(_ patchDay: String) throws -> Bool {
            let built = try XCTUnwrap(OverviewChanges.build(summaries: [
                try day(patchDay, changes: patch), try day("2026-11-10", changes: counts),
            ], format: .standard))
            return built.patch != nil
        }
        XCTAssertTrue(try shows("2026-11-02"), "8 days is within the limit")
        XCTAssertFalse(try shows("2026-11-01"), "9 days is past it")
    }

    func testPatchRowsOnlyWithAPart() throws {
        let built = try XCTUnwrap(OverviewChanges.build(
            summaries: [try day("2026-11-02", changes: counts)], format: .standard))
        XCTAssertTrue(built.patchRows.isEmpty)
        XCTAssertNil(built.patchScanDay)
    }

    // MARK: - Demo

    func testDemoFleetChangesAgreeWithTheDemoFleet() throws {
        let computers = try XCTUnwrap(DemoData.fleetChanges.computers)
        let (now, before) = (try XCTUnwrap(computers.currentCount),
                             try XCTUnwrap(computers.priorCount))
        XCTAssertEqual(now, DemoData.totalDevices)
        XCTAssertEqual(now - before, (computers.joined ?? 0) - (computers.left ?? 0))
        let gaps = DemoData.securityControls.total - DemoData.securityControls.fileVault
        XCTAssertLessThanOrEqual(computers.fileVaultOff ?? 0, gaps)
        XCTAssertTrue(computers.isValid)
        XCTAssertTrue(DemoData.overviewChanges.agents.isEmpty)
        let demoPatch = try XCTUnwrap(DemoData.fleetChanges.patch)
        XCTAssertLessThanOrEqual(demoPatch.startedFailing ?? 0, DemoData.patchFailures.count)
        XCTAssertTrue(demoPatch.isValid)
        XCTAssertEqual(DemoData.overviewChanges.patchRows.count, 2)
        for stamp in [computers.currentStamp, computers.baselineStamp, demoPatch.currentStamp,
                      demoPatch.baselineStamp] {
            let date = try XCTUnwrap(stamp.flatMap(PatchReleaseDateService.stampDate))
            XCTAssertLessThanOrEqual(date, DemoData.referenceDate, "no demo date after reference")
        }
        XCTAssertNil(DemoData.overviewChanges.patchScanDay, "the demo scan is the same day")
    }
}
