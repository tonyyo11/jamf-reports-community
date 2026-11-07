import XCTest
@testable import JamfReports

/// The Jamf Protect Trends metrics and alert keys (environment model P9).
@MainActor
final class TrendStoreProtectMetricsTests: XCTestCase {

    private nonisolated(unsafe) var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-protect-metrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", tempRoot.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try super.tearDownWithError()
    }

    private func day(
        computers: Int? = nil, matched: Double? = nil, open: Int? = nil,
        counts: [String: Int]? = nil
    ) -> DailySummary {
        DailySummary(
            date: "2026-11-07", totalDevices: 10, fileVaultPct: 90, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli", protectComputerCount: computers, protectMatchedPct: matched,
            protectOpenAlerts: open, protectAlertCounts: counts)
    }

    func testRawValuesPolaritiesAndUnits() {
        let expected: [(TrendSeries.Metric, String, FleetInsightInput.Polarity, String, Bool)] = [
            (.protectComputers, "protectComputers", .neutral, "", true),
            (.protectMatched, "protectMatched", .higherIsBetter, "%", false),
            (.protectOpenAlerts, "protectOpenAlerts", .lowerIsBetter, "", true),
        ]
        XCTAssertEqual(TrendSeries.Metric.protectMetrics, expected.map(\.0))
        for (metric, raw, polarity, unit, isCount) in expected {
            XCTAssertEqual(metric.rawValue, raw)
            XCTAssertEqual(TrendSeries.Metric(rawValue: raw), metric)
            XCTAssertEqual(metric.polarity, polarity, raw)
            XCTAssertEqual(metric.unit, unit, raw)
            XCTAssertEqual(metric.isDeviceCount, isCount, raw)
            XCTAssertTrue(metric.displayLabel.contains("Jamf Protect"))
        }
        XCTAssertTrue(TrendSeries.Metric.allCases.allSatisfy { !$0.isProtect })
    }

    func testOfferedOnlyWhenASummaryCarriesTheField() {
        let store = TrendStore(summaries: [day(computers: 12, open: 0)])
        XCTAssertTrue(store.offers(.protectComputers))
        XCTAssertTrue(store.offers(.protectOpenAlerts))
        XCTAssertFalse(store.offers(.protectMatched))
        XCTAssertEqual(store.points(metric: .protectOpenAlerts).map(\.value), [0])
        XCTAssertFalse(TrendStore(summaries: [day()]).offers(.protectComputers))
    }

    func testNotOfferedWithoutProtectInTheEnvironment() throws {
        let workspace = tempRoot.appendingPathComponent("acme", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config = workspace.appendingPathComponent("config.yaml")
        try Data("jamf_cli:\n  profile: acme\n".utf8).write(to: config)
        let store = WorkspaceStore(demoMode: false)
        store.profile = "acme"
        store.refreshEnvironmentProducts()
        XCTAssertFalse(store.environmentProducts.has(.protect))
        XCTAssertTrue(TrendSeries.Metric.protectMetrics.allSatisfy { !store.isOffered($0) })
        XCTAssertTrue(Set(store.availableMetrics).isDisjoint(with: TrendSeries.Metric.protectMetrics))
        try Data("jamf_cli:\n  profile: acme\nprotect:\n  enabled: true\n  profile: p\n".utf8)
            .write(to: config)
        store.refreshEnvironmentProducts()
        XCTAssertTrue(TrendSeries.Metric.protectMetrics.allSatisfy { store.isOffered($0) })
        XCTAssertTrue(TrendSeries.Metric.protectMetrics.allSatisfy {
            store.availableMetrics.contains($0)
        })
    }

    func testASchoolWorkspaceOffersThemOnlyWithProtect() throws {
        let workspace = tempRoot.appendingPathComponent("campus", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config = workspace.appendingPathComponent("config.yaml")
        try Data("school_cli:\n  enabled: true\n".utf8).write(to: config)
        let store = WorkspaceStore(demoMode: false)
        store.profile = "campus"
        store.refreshEnvironmentProducts()
        XCTAssertTrue(store.isSchoolWorkspace)
        XCTAssertTrue(Set(store.availableMetrics).isDisjoint(with: TrendSeries.Metric.protectMetrics))
        XCTAssertTrue(TrendSeries.Metric.protectMetrics.allSatisfy { !store.isOffered($0) })
        try Data("school_cli:\n  enabled: true\nprotect:\n  enabled: true\n  profile: p\n".utf8)
            .write(to: config)
        store.refreshEnvironmentProducts()
        XCTAssertTrue(store.isSchoolWorkspace)
        XCTAssertTrue(TrendSeries.Metric.protectMetrics.allSatisfy {
            store.availableMetrics.contains($0) && store.isOffered($0)
        })
    }

    func testAlertKeysFireOnAValueAndNeverWhenTheFieldIsAbsent() {
        let current = day(computers: 40, matched: 30, open: 9, counts: ["high": 4])
        let cases: [(String, String, Double)] = [
            ("protect_computer_count", "above", 39),
            ("protect_matched_pct", "below", 50),
            ("protect_open_alert_count", "above", 5),
            ("protect_high_alert_count", "above", 3),
        ]
        for (key, when, threshold) in cases {
            let rule = AlertRule(metric: key, when: when, threshold: threshold, lookbackDays: nil)
            XCTAssertEqual(
                MetricAlertEvaluator.evaluate(rules: [rule], current: current, prior: nil).count,
                1, key)
            XCTAssertTrue(MetricAlertEvaluator.evaluate(
                rules: [rule], current: day(), prior: nil).isEmpty, key)
        }
    }

    func testHighAlertCountReadsZeroFromASnapshotWithNoOpenHighAlert() {
        let metric = AlertMetric.protectHighAlertCount
        XCTAssertEqual(metric.value(in: day(open: 3, counts: ["low": 3])), 0)
        XCTAssertEqual(metric.value(in: day(open: 0, counts: nil)), 0)
        XCTAssertNil(metric.value(in: day(open: nil, counts: nil)))
    }
}
