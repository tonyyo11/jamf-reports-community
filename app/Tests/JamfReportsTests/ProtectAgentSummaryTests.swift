import XCTest
@testable import JamfReports

/// The Protect agent findings in the daily summary, its alert keys and its Trends series
/// (wave E). A share is recorded only for what this run landed, and never as 0 of 0.
final class ProtectAgentSummaryTests: XCTestCase {

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

    /// One Mac behind on all three, against baselines two and three days old.
    private func writeSnapshots() throws {
        _ = try GoldenFleetWorkspace.writeSnapshot(
            kind: "protect-computers", dataDir: dataDir, at: anchor,
            rows: [["hostname": "a", "signaturesVersion": 100, "version": "5.0",
                    "connectionStatus": "Disconnected",
                    "lastDisconnection": ISO8601Time.string(hoursBefore(30))]])
        _ = try GoldenFleetWorkspace.writeSnapshot(
            kind: ReportEngine.protectSignatureVersionsKind, dataDir: dataDir,
            at: hoursBefore(1),
            rows: [["id": "101", "created": ISO8601Time.string(hoursBefore(48))]])
        _ = try GoldenFleetWorkspace.writeSnapshot(
            kind: ReportEngine.protectInstallerKind, dataDir: dataDir, at: hoursBefore(72),
            rows: [["installerVersion": "5.1"]])
    }

    private func figures(landed: Set<String>) throws -> ProtectSummaryFigures? {
        ReportEngine.protectSummaryFigures(
            dataDir: dataDir, workspace: try WorkspaceID(validating: "agent-summary"),
            landed: landed, hasInventory: false)
    }

    private let one = MobileSummary.Share(met: 1, of: 1)

    // MARK: - What this run measured

    func testOnlyTheKindsThatLandedAreMeasured() throws {
        try writeSnapshots()
        let computersOnly = try XCTUnwrap(figures(landed: ["protect-computers"])?.agent)
        XCTAssertEqual(computersOnly.disconnected, .init(one))
        XCTAssertNil(computersOnly.signaturesBehind, "its list did not land this run")
        XCTAssertNil(computersOnly.agentBehind)

        let all = try XCTUnwrap(figures(landed: [
            "protect-computers", ReportEngine.protectSignatureVersionsKind,
            ReportEngine.protectInstallerKind,
        ])?.agent)
        XCTAssertEqual(all.signaturesBehind, .init(one))
        XCTAssertEqual(all.agentBehind, .init(one))
        XCTAssertNil(try figures(landed: [ReportEngine.protectInstallerKind])?.agent,
                     "nothing without the computers this run")
    }

    func testALandedListThatCannotBeReadIsMeasuredAsNotEvaluated() throws {
        try writeSnapshots()
        let folder = dataDir.appendingPathComponent(ReportEngine.protectSignatureVersionsKind)
        try Data("{broken".utf8).write(to: folder.appendingPathComponent(
            "\(ReportEngine.protectSignatureVersionsKind)_\(GoldenFleetClock.stamp(anchor)).json"))
        let agent = try XCTUnwrap(figures(landed: [
            "protect-computers", ReportEngine.protectSignatureVersionsKind,
        ])?.agent)
        XCTAssertNil(agent.signaturesBehind, "an unreadable list is not this run's measure")
    }

    func testNoMacJudgedIsAbsentNeverZero() {
        XCTAssertNil(ProtectSummaryFigures.Measured(.init(met: 0, of: 0)).share)
        XCTAssertEqual(ProtectSummaryFigures.Measured(.init(met: 0, of: 3)).share,
                       .init(met: 0, of: 3))
    }

    // MARK: - The summary file

    private func blank() -> DailySummary {
        DailySummary(date: "2026-11-25", totalDevices: 10, fileVaultPct: nil, compliancePct: nil,
                     staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
                     source: "jamf-cli")
    }

    func testAMeasuredFindingReplacesAndAnUnmeasuredOneKeepsTheEarlierValue() {
        let morning = blank().withEnvironment(products: nil, protect: .init(agent: .init(
            signaturesBehind: .init(.init(met: 2, of: 5)), agentBehind: .init(.init(met: 1, of: 5)),
            disconnected: .init(.init(met: 0, of: 5)))))
        let later = morning.withEnvironment(products: nil, protect: .init(agent: .init(
            signaturesBehind: nil, agentBehind: .init(nil),
            disconnected: .init(.init(met: 1, of: 5)))))
        XCTAssertEqual(later.protectSignaturesBehind, .init(met: 2, of: 5), "not measured: kept")
        XCTAssertNil(later.protectAgentBehind, "measured, not judged: replaced")
        XCTAssertEqual(later.protectDisconnected, .init(met: 1, of: 5))
    }

    func testTheFieldsRoundTripFillAndAreRangeChecked() throws {
        let summary = blank().withEnvironment(products: nil, protect: .init(agent: .init(
            signaturesBehind: .init(.init(met: 2, of: 5)), agentBehind: nil,
            disconnected: .init(.init(met: 1, of: 5)))))
        let decoded = try JSONDecoder().decode(
            DailySummary.self, from: try JSONEncoder().encode(summary))
        XCTAssertEqual(decoded.protectSignaturesBehind, .init(met: 2, of: 5))
        XCTAssertNil(decoded.protectAgentBehind)
        XCTAssertEqual(blank().filling(from: summary).protectDisconnected, .init(met: 1, of: 5))
        XCTAssertTrue(summary.numbersAreInRange)
        let broken = blank().withEnvironment(products: nil, protect: .init(agent: .init(
            signaturesBehind: .init(.init(met: 6, of: 5)), agentBehind: nil, disconnected: nil)))
        XCTAssertFalse(broken.numbersAreInRange)
        XCTAssertTrue(ReportEngine.freshSummaryIsBetter(existing: blank(), fresh: summary),
                      "a newly measured finding upgrades the day's summary")
    }

    // MARK: - Alerts and Trends

    func testAlertKeysReadMetAndNeverFireWhenAbsent() {
        let summary = blank().withEnvironment(products: nil, protect: .init(agent: .init(
            signaturesBehind: .init(.init(met: 0, of: 5)), agentBehind: nil,
            disconnected: .init(.init(met: 3, of: 5)))))
        XCTAssertEqual(AlertMetric.protectSignaturesBehindCount.value(in: summary), 0)
        XCTAssertNil(AlertMetric.protectAgentBehindCount.value(in: summary))
        XCTAssertEqual(AlertMetric.protectDisconnectedCount.value(in: summary), 3)
        XCTAssertFalse(AlertMetric.protectDisconnectedCount.isPercentage)
        XCTAssertEqual(
            AlertMetric(rawValue: "protect_agent_behind_count"), .protectAgentBehindCount)
        XCTAssertEqual(TrendStore.environmentValue(.protectDisconnected, in: summary), 3)
        XCTAssertNil(TrendStore.environmentValue(.protectAgentBehind, in: summary))
    }

    func testTheDemoHistoryEndsOnTheProtectScreensFigures() throws {
        let agent = try XCTUnwrap(DemoData.protectFigures(for: DemoData.org.profile)?.agent)
        XCTAssertEqual(agent.disconnected, .init(.init(met: 1, of: 12)))
    }
}
