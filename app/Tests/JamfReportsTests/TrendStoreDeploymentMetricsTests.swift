import XCTest
@testable import JamfReports

/// The two deployment-health Trends series (wave C): offered only where a summary carries the
/// group, compared within one judging basis, and never Overview score cards.
@MainActor
final class TrendStoreDeploymentMetricsTests: XCTestCase {

    private nonisolated(unsafe) var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-deploy-metrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", tempRoot.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try super.tearDownWithError()
    }

    private func group(_ warning: Int, _ critical: Int, levels: (Int, Int) = (10, 25))
        -> DeploymentSummaryGroup {
        DeploymentSummaryGroup(
            figures: .init(judged: 20, atWarning: warning, atCritical: critical),
            levels: .init(warning: levels.0, critical: levels.1))
    }

    private func day(_ date: String, patch: DeploymentSummaryGroup? = nil) -> DailySummary {
        let base = DailySummary(
            date: date, totalDevices: 10, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli")
        guard let patch else { return base }
        return base.withEnvironment(products: nil, protect: nil, deployments: [.patchPolicy: patch])
    }

    func testTheMetricsAreTrendsSeriesOnly() {
        let metric = TrendSeries.Metric.patchPoliciesAtLevel
        XCTAssertTrue(metric.isDeployment)
        XCTAssertTrue(TrendSeries.Metric.appInstallersAtLevel.isDeployment)
        XCTAssertFalse(TrendSeries.Metric.allCases.contains { $0.isDeployment })
        XCTAssertEqual(TrendSeries.Metric(rawValue: metric.rawValue), metric)
        XCTAssertEqual(metric.polarity, .lowerIsBetter)
        XCTAssertTrue(metric.isDeviceCount)
        XCTAssertEqual(metric.minY, 0)
        XCTAssertEqual(metric.maxY, 60)
    }

    func testOfferedOnlyWhenASummaryCarriesTheGroupAndTheValueIsAtLevel() {
        let store = TrendStore(summaries: [day("2026-11-20", patch: group(2, 3))])
        XCTAssertTrue(store.offers(.patchPoliciesAtLevel))
        XCTAssertFalse(store.offers(.appInstallersAtLevel))
        XCTAssertEqual(store.points(metric: .patchPoliciesAtLevel).map(\.value), [5])
        XCTAssertFalse(TrendStore(summaries: [day("2026-11-20")]).offers(.patchPoliciesAtLevel))
    }

    func testAChangeIsMeasuredWithinOneBasisOnly() {
        let summaries = [
            day("2026-11-18", patch: group(1, 0)),
            day("2026-11-19", patch: group(4, 0)),
            day("2026-11-20", patch: group(2, 1, levels: (5, 25))),
            day("2026-11-21", patch: group(3, 1, levels: (5, 25))),
        ]
        XCTAssertEqual(
            TrendStore.comparableValues(of: .patchPoliciesAtLevel, in: summaries), [3, 4])
    }

    func testTheNoteNamesTheNewestChangeAndSkipsGapDays() throws {
        let same = [day("2026-11-18", patch: group(1, 0)), day("2026-11-19", patch: group(1, 0))]
        XCTAssertNil(TrendStore.deploymentLevelsNote(of: .patchPoliciesAtLevel, in: same))
        // A day without the group is skipped, not read as a change.
        let gap = [day("2026-11-18", patch: group(1, 0)), day("2026-11-19"),
                   day("2026-11-20", patch: group(1, 0))]
        XCTAssertNil(TrendStore.deploymentLevelsNote(of: .patchPoliciesAtLevel, in: gap))
        let level = gap + [day("2026-11-21", patch: group(1, 0, levels: (5, 30)))]
        let note = try XCTUnwrap(
            TrendStore.deploymentLevelsNote(of: .patchPoliciesAtLevel, in: level))
        XCTAssertTrue(note.contains("2026-11-21") && note.contains("5%") && note.contains("30%"))
        // A flip back to the first levels is itself the newest change.
        let back = level + [day("2026-11-22", patch: group(1, 0))]
        let backNote = try XCTUnwrap(
            TrendStore.deploymentLevelsNote(of: .patchPoliciesAtLevel, in: back))
        XCTAssertTrue(backNote.contains("2026-11-22") && backNote.contains("10%"))
        // A floor change alone is a basis change too.
        var floor = group(1, 0)
        floor.minimumInScope = 20
        let floorNote = try XCTUnwrap(TrendStore.deploymentLevelsNote(
            of: .patchPoliciesAtLevel, in: same + [day("2026-11-20", patch: floor)]))
        XCTAssertTrue(floorNote.contains("20 Macs"))
        XCTAssertNil(TrendStore.deploymentLevelsNote(of: .appInstallersAtLevel, in: level))
    }

    func testOfferedOnAJamfProWorkspaceNeverAsAScoreCardOrOnSchoolOrDemo() throws {
        let workspace = tempRoot.appendingPathComponent("acme", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config = workspace.appendingPathComponent("config.yaml")
        try Data("jamf_cli:\n  profile: acme\n".utf8).write(to: config)
        let store = WorkspaceStore(demoMode: false)
        store.profile = "acme"
        store.refreshEnvironmentProducts()
        let metrics = TrendSeries.Metric.deploymentMetrics
        XCTAssertTrue(metrics.allSatisfy { store.availableMetrics.contains($0) })
        XCTAssertTrue(metrics.allSatisfy { !store.isOffered($0) }, "never a score card")
        XCTAssertTrue(Set(store.scoreCardExtraMetrics).isDisjoint(with: metrics))
        try Data("school_cli:\n  enabled: true\n".utf8).write(to: config)
        store.refreshEnvironmentProducts()
        XCTAssertTrue(Set(store.availableMetrics).isDisjoint(with: metrics))
        XCTAssertTrue(Set(WorkspaceStore(demoMode: true).availableMetrics).isDisjoint(with: metrics))
    }
}
