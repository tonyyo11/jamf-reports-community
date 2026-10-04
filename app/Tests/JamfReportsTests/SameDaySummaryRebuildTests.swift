import Foundation
import XCTest
@testable import JamfReports

/// A collect that landed a source rebuilds today's summary; one that landed nothing leaves
/// it; and a rebuild never turns a value the morning's summary had into nil.
///
/// Fleet, invented: ten Macs, FileVault on 9, SIP on 10, Firewall on 8 (security report);
/// patch-status with one title at 20 of 100 in the morning and 60 of 100 later.
final class SameDaySummaryRebuildTests: XCTestCase {

    private var root: URL!
    private var dataDir: URL!
    private var summariesDir: URL!
    private var engine: ReportEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-SameDay-\(UUID().uuidString)", isDirectory: true)
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

    private func hoursAgo(_ hours: Double) -> Date { Date().addingTimeInterval(-hours * 3600) }

    private func writeSecurity(at when: Date) throws {
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "security", dataDir: dataDir, at: when,
            rows: GoldenFleetWorkspace.securitySummaryPayload(
                total: 10, filevault: 9, sip: 10, firewall: 8, gatekeeper: 10))
    }

    private func writePatch(onLatest: Int, at when: Date) throws {
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "patch-status", dataDir: dataDir, at: when,
            rows: [GoldenFleetWorkspace.patchRow(
                id: "1", title: "Browser", onLatest: onLatest, total: 100)])
    }

    private func summary() throws -> DailySummary {
        try XCTUnwrap(SummaryJSONParser.parseDirectory(summariesDir).first)
    }

    private var todayFile: URL {
        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        return summariesDir.appendingPathComponent("summary_\(today).json")
    }

    @discardableResult
    private func collect(landed: Set<String>) -> ReportEngine.SummaryEmitOutcome {
        engine.emitSummaryJSON(summariesDir: summariesDir, liveKinds: landed)
    }

    // MARK: - A run that landed a source rebuilds the day

    func testASecondCollectWithANewPatchFigureRewritesTheSummary() throws {
        try writeSecurity(at: hoursAgo(4))
        try writePatch(onLatest: 20, at: hoursAgo(4))
        XCTAssertEqual(collect(landed: ["security", "patch-status"]), .wrote)
        XCTAssertEqual(try summary().patchPct, 20.0)

        try writePatch(onLatest: 60, at: hoursAgo(1))
        XCTAssertEqual(collect(landed: ["patch-status"]), .wrote)

        let rebuilt = try summary()
        XCTAssertEqual(rebuilt.patchPct, 60.0, "the newest patch snapshot, not the morning's")
        XCTAssertEqual(rebuilt.fileVaultPct, 90.0)
        XCTAssertEqual(rebuilt.collectionSources?["patch-status"], "live")
        XCTAssertEqual(rebuilt.collectionSources?["security"], "live",
                       "the morning's live source is not relabelled as cache")
    }

    func testAnInventoryOnlyRunKeepsTheMorningsSecurityValues() throws {
        try writeSecurity(at: hoursAgo(4))
        try writePatch(onLatest: 20, at: hoursAgo(4))
        collect(landed: ["security", "patch-status"])
        let morning = try summary()
        XCTAssertNotNil(morning.securityScore)

        // The afternoon run fetched inventory only, and the morning's security and patch
        // snapshots can no longer be read.
        try FileManager.default.removeItem(at: dataDir.appendingPathComponent("security"))
        try FileManager.default.removeItem(at: dataDir.appendingPathComponent("patch-status"))
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "inventory-summary", dataDir: dataDir, at: hoursAgo(1),
            rows: [["os_version": "15.4.1", "count": 12]])
        XCTAssertEqual(collect(landed: ["inventory-summary"]), .wrote)

        let afternoon = try summary()
        XCTAssertEqual(afternoon.totalDevices, 12, "this run's fleet size")
        XCTAssertEqual(afternoon.fileVaultPct, morning.fileVaultPct)
        XCTAssertEqual(afternoon.sipPct, morning.sipPct)
        XCTAssertEqual(afternoon.firewallPct, morning.firewallPct)
        XCTAssertEqual(afternoon.patchPct, morning.patchPct)
        XCTAssertEqual(afternoon.patchPctBasis, morning.patchPctBasis)
        XCTAssertEqual(afternoon.securityScore, morning.securityScore)
        XCTAssertEqual(afternoon.securityScoreBasis, morning.securityScoreBasis)
        XCTAssertEqual(afternoon.actionItemsP0, morning.actionItemsP0)
        XCTAssertEqual(afternoon.collectionSources?["inventory-summary"], "live")
        XCTAssertEqual(afternoon.collectionSources?["security"], "live",
                       "its values are still the morning's live ones")
    }

    // MARK: - A run that landed nothing leaves the file alone

    func testARunThatLandedNothingLeavesTheFileUntouched() throws {
        try writeSecurity(at: hoursAgo(4))
        try writePatch(onLatest: 20, at: hoursAgo(4))
        collect(landed: ["security", "patch-status"])
        let before = try Data(contentsOf: todayFile)

        // A newer patch snapshot exists, but this run fetched nothing.
        try writePatch(onLatest: 60, at: hoursAgo(1))
        XCTAssertEqual(collect(landed: []), .keptExisting)

        XCTAssertEqual(try Data(contentsOf: todayFile), before)
        XCTAssertEqual(try summary().patchPct, 20.0)
    }

    // MARK: - What a rebuild keeps

    private func make(
        compliance: Double?, proxy: Bool?, patch: Double?, score: Double?,
        sources: [String: String]? = nil
    ) -> DailySummary {
        DailySummary(
            date: "2026-10-04", totalDevices: 10, fileVaultPct: nil, compliancePct: compliance,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: patch,
            source: "jamf-cli", securityScore: score, complianceIsProxy: proxy,
            collectionSources: sources,
            patchPctBasis: patch == nil ? nil : "device",
            securityScoreBasis: score == nil ? nil : "fileVault,sip")
    }

    func testFillingNeverReplacesRealComplianceWithTheProxy() {
        let morning = make(compliance: 67.0, proxy: false, patch: nil, score: nil)
        let proxyRun = make(compliance: 96.0, proxy: true, patch: nil, score: nil)
        let rebuilt = proxyRun.filling(from: morning)
        XCTAssertEqual(rebuilt.compliancePct, 67.0)
        XCTAssertEqual(rebuilt.complianceIsProxy, false)
    }

    func testFillingMovesAFigureWithItsBasis() {
        let morning = make(compliance: nil, proxy: nil, patch: 55.0, score: 88.0)
        let run = make(compliance: nil, proxy: nil, patch: nil, score: nil)
        let rebuilt = run.filling(from: morning)
        XCTAssertEqual(rebuilt.patchPct, 55.0)
        XCTAssertEqual(rebuilt.patchPctBasis, "device")
        XCTAssertEqual(rebuilt.securityScore, 88.0)
        XCTAssertEqual(rebuilt.securityScoreBasis, "fileVault,sip")
    }

    func testFillingNeverOverridesAValueThisRunMeasured() {
        let morning = make(compliance: 67.0, proxy: false, patch: 55.0, score: 88.0)
        let run = make(compliance: 70.0, proxy: false, patch: 60.0, score: 80.0)
        let rebuilt = run.filling(from: morning)
        XCTAssertEqual([rebuilt.compliancePct, rebuilt.patchPct, rebuilt.securityScore],
                       [70.0, 60.0, 80.0])
    }

    func testMergedSourcesKeepsAnEarlierStatusForASourceThisRunCannotRead() {
        let merged = ReportEngine.mergedSources(
            existing: ["security": "live", "patch-status": "cache", "sofa": "absent"],
            fresh: ["security": "absent", "patch-status": "absent", "sofa": "absent",
                    "inventory-summary": "live"])
        XCTAssertEqual(merged, [
            "security": "live", "patch-status": "cache", "sofa": "absent",
            "inventory-summary": "live",
        ])
    }
}
