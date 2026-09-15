import XCTest
@testable import JamfReports

@MainActor
final class ProtectDashboardServiceTests: XCTestCase {

    /// Writes `json` to a uniquely named temp file; the caller removes it.
    private func writeTemp(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("protect-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testViewInstantiationInDemoMode() throws {
        let workspace = WorkspaceStore()
        workspace.demoMode = true
        _ = ProtectView().environment(workspace)
        // No crash = success
    }

    func testViewInstantiationInProductionMode() throws {
        let workspace = WorkspaceStore()
        workspace.demoMode = false
        workspace.profile = "test"
        _ = ProtectView().environment(workspace)
        // No crash = success
    }

    func testLoadWithAllNilURLsReturnsEmpty() throws {
        let snapshot = ProtectDashboardService.load(
            overviewURL: nil,
            alertsURL: nil,
            computersURL: nil,
            insightsURL: nil
        )

        XCTAssertFalse(snapshot.isDetected)
        XCTAssertTrue(snapshot.overviewItems.isEmpty)
        XCTAssertTrue(snapshot.alerts.isEmpty)
        XCTAssertTrue(snapshot.computers.isEmpty)
        XCTAssertTrue(snapshot.insights.isEmpty)
        XCTAssertEqual(snapshot.totalComputers, 0)
        XCTAssertEqual(snapshot.webProtectionActiveCount, 0)
        XCTAssertEqual(snapshot.fullDiskAccessCount, 0)
        XCTAssertEqual(snapshot.connectedCount, 0)
        XCTAssertEqual(snapshot.criticalAlerts, 0)
        XCTAssertEqual(snapshot.highAlerts, 0)
        XCTAssertEqual(snapshot.mediumAlerts, 0)
        XCTAssertEqual(snapshot.lowAlerts, 0)
        XCTAssertEqual(snapshot.failingInsights, 0)
        XCTAssertNil(snapshot.sourceFile)
        XCTAssertNil(snapshot.snapshotDate)
    }

    func testLoadPlansDecodesArrayShapeAndMarksDetected() throws {
        let url = try writeTemp("""
        [{"actionConfig":"Default Actions","autoUpdate":true,"logLevel":"INFO",
          "name":"Standard","telemetry":"Standard Telemetry","unifiedLoggingFilterSets":""}]
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = ProtectDashboardService.load(
            overviewURL: nil, alertsURL: nil, computersURL: nil, insightsURL: nil, plansURL: url)

        XCTAssertTrue(snapshot.isDetected, "a decoded plans file should mark Protect detected")
        XCTAssertEqual(snapshot.plans.count, 1)
        XCTAssertEqual(snapshot.plans.first?.name, "Standard")
        XCTAssertEqual(snapshot.plans.first?.telemetry, "Standard Telemetry")
        XCTAssertEqual(snapshot.plans.first?.autoUpdate, true)
    }

    func testLoadsJamfCLIFixturesIntoAggregates() throws {
        // The fixtures are jamf-cli flatten rows: enum fullDiskAccess, Connected or Disconnected,
        // one alert with no computer and one plan with no telemetry.
        let fixtures = TestFixtures.dir("jamf-cli-data")
        let snapshot = ProtectDashboardService.load(
            overviewURL: nil,
            alertsURL: fixtures.appendingPathComponent("protect-alerts/alerts_happy.json"),
            computersURL: fixtures.appendingPathComponent("protect-computers/computers_happy.json"),
            insightsURL: fixtures.appendingPathComponent("protect-insights/insights_happy.json"),
            plansURL: fixtures.appendingPathComponent("protect-plans/plans_happy.json")
        )

        XCTAssertTrue(snapshot.isDetected)
        XCTAssertEqual(snapshot.alerts.count, 4)
        XCTAssertEqual(snapshot.computers.count, 3)
        XCTAssertEqual(snapshot.insights.count, 3)
        XCTAssertEqual(snapshot.plans.count, 3)
        XCTAssertEqual(snapshot.webProtectionActiveCount, 1)
        XCTAssertEqual(snapshot.fullDiskAccessCount, 1, "only Authorized counts as granted")
        XCTAssertEqual(snapshot.connectedCount, 2, "Disconnected must not count as connected")
        XCTAssertEqual(snapshot.highAlerts, 1)
        XCTAssertEqual(snapshot.mediumAlerts, 1)
        XCTAssertEqual(snapshot.lowAlerts, 1)
        XCTAssertEqual(snapshot.failingInsights, 2)
        XCTAssertNotNil(snapshot.sourceFile)
        XCTAssertNotNil(snapshot.snapshotDate)
    }

    func testOddFieldTypeCostsTheFieldNotTheList() throws {
        // Each odd value is the shape the old decoders expected; the other rows must still load.
        let alerts = try writeTemp("""
        [{"computer":{"hostName":"old-shape.example"},"severity":"High","uuid":"a1"},
         {"computer":"lab-mac-01.example","severity":"Low","uuid":"a2"}]
        """)
        let computers = try writeTemp("""
        [{"fullDiskAccess":true,"hostname":"old-shape.example","uuid":"c1"},
         {"fullDiskAccess":"Authorized","hostname":"lab-mac-01.example","uuid":"c2"}]
        """)
        let plans = try writeTemp("""
        [{"autoUpdate":true,"logLevel":"INFO","name":"Alpha","telemetry":true,
          "unifiedLoggingFilterSets":""},
         {"autoUpdate":false,"logLevel":"INFO","name":"Beta","telemetry":"Standard Telemetry",
          "unifiedLoggingFilterSets":""}]
        """)
        defer {
            for url in [alerts, computers, plans] { try? FileManager.default.removeItem(at: url) }
        }

        let snapshot = ProtectDashboardService.load(
            overviewURL: nil, alertsURL: alerts, computersURL: computers,
            insightsURL: nil, plansURL: plans)

        XCTAssertEqual(snapshot.alerts.map(\.hostName), [nil, "lab-mac-01.example"])
        XCTAssertEqual(snapshot.alerts.map(\.severity), ["High", "Low"])
        XCTAssertEqual(snapshot.computers.map(\.hostName),
                       ["old-shape.example", "lab-mac-01.example"])
        XCTAssertEqual(snapshot.computers.map(\.fullDiskAccess), [nil, true])
        XCTAssertEqual(snapshot.plans.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(snapshot.plans.map(\.telemetry), [nil, "Standard Telemetry"])
    }

    func testConnectionPredicateCaseInsensitivity() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let computersFile = tempDir.appendingPathComponent("computers-connection-test.json")

        // jamf-cli prints Protect's Connected or Disconnected status
        let computersJSON = """
        [
            {
                "uuid": "1",
                "hostname": "mac-1.example",
                "connectionStatus": "Connected"
            },
            {
                "uuid": "2",
                "hostname": "mac-2.example",
                "connectionStatus": "connected"
            },
            {
                "uuid": "3",
                "hostname": "mac-3.example",
                "connectionStatus": "CONNECTED"
            },
            {
                "uuid": "4",
                "hostname": "mac-4.example",
                "connectionStatus": "Disconnected"
            },
            {
                "uuid": "5",
                "hostname": "mac-5.example"
            }
        ]
        """

        try computersJSON.write(to: computersFile, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: computersFile)
        }

        let snapshot = ProtectDashboardService.load(
            overviewURL: nil,
            alertsURL: nil,
            computersURL: computersFile,
            insightsURL: nil
        )

        // Connected counts in any case; Disconnected and a missing status do not.
        XCTAssertEqual(snapshot.connectedCount, 3, "Should recognize 'Connected' in any case")
        XCTAssertEqual(snapshot.totalComputers, 5)
    }

    func testIsConnectedMatchesProtectConnectionStatus() {
        XCTAssertTrue(ProtectDashboardService.isConnected("Connected"))
        XCTAssertFalse(ProtectDashboardService.isConnected("Disconnected"))
        XCTAssertFalse(ProtectDashboardService.isConnected(nil))
    }

    func testEmptyInputArraysWithDetectedTrue() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let emptyFile = tempDir.appendingPathComponent("empty-test.json")

        // Empty but valid JSON array
        let emptyJSON = "[]"
        try emptyJSON.write(to: emptyFile, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: emptyFile)
        }

        let snapshot = ProtectDashboardService.load(
            overviewURL: emptyFile,
            alertsURL: nil,
            computersURL: nil,
            insightsURL: nil
        )

        // File was readable, so isDetected should be true, but counts are 0
        XCTAssertTrue(snapshot.isDetected, "Should be detected when file exists even if empty")
        XCTAssertTrue(snapshot.overviewItems.isEmpty)
        XCTAssertEqual(snapshot.totalComputers, 0)
        XCTAssertEqual(snapshot.webProtectionActiveCount, 0)
        XCTAssertEqual(snapshot.fullDiskAccessCount, 0)
        XCTAssertEqual(snapshot.connectedCount, 0)
        XCTAssertEqual(snapshot.criticalAlerts, 0)
        XCTAssertEqual(snapshot.failingInsights, 0)
        XCTAssertNotNil(snapshot.sourceFile)
        XCTAssertNotNil(snapshot.snapshotDate)
    }

    func testInsightsFailingCount() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let insightsFile = tempDir.appendingPathComponent("insights-test.json")

        // flattenInsight rows with mixed pass/fail counts
        let insightsJSON = """
        [
            {"cisIDs": "1.1.1", "enabled": true, "label": "Test1", "section": "Sharing",
             "totalFail": 0, "totalNone": 0, "totalPass": 10},
            {"cisIDs": "1.1.2", "enabled": true, "label": "Test2", "section": "Sharing",
             "totalFail": 2, "totalNone": 0, "totalPass": 8},
            {"cisIDs": "1.1.3", "enabled": true, "label": "Test3", "section": "Network",
             "totalFail": 5, "totalNone": 0, "totalPass": 5},
            {"cisIDs": "", "enabled": false, "label": "Test4", "section": "Network",
             "totalFail": 0, "totalNone": 0, "totalPass": 0}
        ]
        """

        try insightsJSON.write(to: insightsFile, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: insightsFile)
        }

        let snapshot = ProtectDashboardService.load(
            overviewURL: nil,
            alertsURL: nil,
            computersURL: nil,
            insightsURL: insightsFile
        )

        XCTAssertEqual(snapshot.failingInsights, 2,
                       "Should count insights with totalFail > 0 (Test2 and Test3)")
        XCTAssertEqual(snapshot.insights.count, 4)
    }

    // MARK: - CacheSource derivation

    func testCacheSourceWithNilSnapshotDate() {
        let snapshot = ProtectDashboardService.Snapshot(
            isDetected: false,
            overviewItems: [],
            alerts: [],
            computers: [],
            insights: [],
            plans: [],
            totalComputers: 0,
            webProtectionActiveCount: 0,
            fullDiskAccessCount: 0,
            connectedCount: 0,
            criticalAlerts: 0,
            highAlerts: 0,
            mediumAlerts: 0,
            lowAlerts: 0,
            failingInsights: 0,
            sourceFile: nil,
            snapshotDate: nil
        )
        XCTAssertEqual(snapshot.cacheSource, .neverFetchedLive)
    }

    func testCacheSourceWithFreshSnapshotDate() {
        let recent = Date(timeIntervalSinceNow: -1800) // 30 minutes ago
        let snapshot = ProtectDashboardService.Snapshot(
            isDetected: true,
            overviewItems: [],
            alerts: [],
            computers: [],
            insights: [],
            plans: [],
            totalComputers: 0,
            webProtectionActiveCount: 0,
            fullDiskAccessCount: 0,
            connectedCount: 0,
            criticalAlerts: 0,
            highAlerts: 0,
            mediumAlerts: 0,
            lowAlerts: 0,
            failingInsights: 0,
            sourceFile: nil,
            snapshotDate: recent
        )
        XCTAssertEqual(snapshot.cacheSource, .fresh)
    }

    func testCacheSourceWithStaleSnapshotDate() {
        let stale = Date(timeIntervalSinceNow: -48 * 3600) // 48 hours ago
        let snapshot = ProtectDashboardService.Snapshot(
            isDetected: true,
            overviewItems: [],
            alerts: [],
            computers: [],
            insights: [],
            plans: [],
            totalComputers: 0,
            webProtectionActiveCount: 0,
            fullDiskAccessCount: 0,
            connectedCount: 0,
            criticalAlerts: 0,
            highAlerts: 0,
            mediumAlerts: 0,
            lowAlerts: 0,
            failingInsights: 0,
            sourceFile: nil,
            snapshotDate: stale
        )
        XCTAssertEqual(snapshot.cacheSource, .stale(at: stale))
    }

    // MARK: - Kill-chain bucketing (v2.1.0 deep-dive)

    func testKillChainBucketsGroupsAlertsByEventType() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let alertsFile = tempDir.appendingPathComponent("alerts-kc-test.json")
        let alertsJSON = """
        [
          {"created": "2026-05-01T08:00:00.000Z", "eventType": "GPProcessEvent",
           "received": "2026-05-01T08:00:01.000Z", "severity": "High", "status": "New",
           "uuid": "a1"},
          {"created": "2026-05-01T09:00:00.000Z", "eventType": "GPProcessEvent",
           "received": "2026-05-01T09:00:01.000Z", "severity": "High", "status": "New",
           "uuid": "a2"},
          {"created": "2026-05-01T10:00:00.000Z", "eventType": "GPFSEvent",
           "received": "2026-05-01T10:00:01.000Z", "severity": "Medium", "status": "New",
           "uuid": "a3"},
          {"created": "2026-05-01T11:00:00.000Z", "eventType": "GPUSBEvent",
           "received": "2026-05-01T11:00:01.000Z", "severity": "Low", "status": "New",
           "uuid": "a4"},
          {"created": "2026-05-01T12:00:00.000Z", "eventType": "",
           "received": "2026-05-01T12:00:01.000Z", "severity": "Low", "status": "New",
           "uuid": "a5"}
        ]
        """
        try alertsJSON.write(to: alertsFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: alertsFile) }

        let snapshot = ProtectDashboardService.load(
            overviewURL: nil, alertsURL: alertsFile, computersURL: nil, insightsURL: nil
        )
        let buckets = ProtectDashboardService.killChainBuckets(snapshot.alerts)
        XCTAssertEqual(buckets.count, 4)
        XCTAssertEqual(buckets[0].stage, "GPProcessEvent")
        XCTAssertEqual(buckets[0].count, 2)
        let unknown = buckets.first { $0.stage == "Unknown" }
        XCTAssertEqual(unknown?.count, 1)
    }

    func testKillChainBucketsEmptyAlerts() {
        XCTAssertTrue(ProtectDashboardService.killChainBuckets([]).isEmpty)
    }

    // MARK: - Agent version distribution

    func testAgentVersionDistributionCountsAndSortsByCount() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let computersFile = tempDir.appendingPathComponent("computers-ver-test.json")
        let computersJSON = """
        [
          {"hostname": "h1.example", "uuid": "c1", "version": "6.1.0.2"},
          {"hostname": "h2.example", "uuid": "c2", "version": "6.1.0.2"},
          {"hostname": "h3.example", "uuid": "c3", "version": "6.0.4.1"},
          {"hostname": "h4.example", "uuid": "c4"}
        ]
        """
        try computersJSON.write(to: computersFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: computersFile) }

        let snapshot = ProtectDashboardService.load(
            overviewURL: nil, alertsURL: nil, computersURL: computersFile, insightsURL: nil
        )
        let versions = ProtectDashboardService.agentVersionDistribution(snapshot.computers)
        XCTAssertEqual(versions.count, 3)
        XCTAssertEqual(versions[0].version, "6.1.0.2")
        XCTAssertEqual(versions[0].count, 2)
        let unknown = versions.first { $0.version == "Unknown" }
        XCTAssertEqual(unknown?.count, 1)
    }

    func testAgentVersionDistributionEmpty() {
        XCTAssertTrue(ProtectDashboardService.agentVersionDistribution([]).isEmpty)
    }

    // MARK: - Per-device alert timeline

    func testAlertTimelineFiltersByHostnameCaseInsensitive() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let alertsFile = tempDir.appendingPathComponent("alerts-timeline-test.json")
        let alertsJSON = """
        [
          {"computer": "Mac-001.example", "created": "2026-05-01T08:00:00.000Z", "uuid": "a1"},
          {"computer": "mac-001.example", "created": "2026-05-03T08:00:00.000Z", "uuid": "a2"},
          {"computer": "Mac-002.example", "created": "2026-05-02T08:00:00.000Z", "uuid": "a3"},
          {"created": "2026-05-04T08:00:00.000Z", "uuid": "a4"}
        ]
        """
        try alertsJSON.write(to: alertsFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: alertsFile) }

        let snapshot = ProtectDashboardService.load(
            overviewURL: nil, alertsURL: alertsFile, computersURL: nil, insightsURL: nil
        )
        let timeline = ProtectDashboardService.alertTimeline(
            for: "mac-001.example", in: snapshot.alerts)
        XCTAssertEqual(snapshot.alerts.count, 4)
        XCTAssertEqual(timeline.map(\.uuid), ["a2", "a1"])
    }

    func testAlertTimelineEmptyForUnknownDevice() {
        XCTAssertTrue(
            ProtectDashboardService.alertTimeline(for: "nonexistent", in: []).isEmpty
        )
    }

    // MARK: - sourceDates (freshness chip row)

    func testSourceDatesPopulatedForPresentKinds() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let alertsFile = tempDir.appendingPathComponent("sourcedates-alerts-\(UUID().uuidString).json")
        let computersFile = tempDir.appendingPathComponent("sourcedates-computers-\(UUID().uuidString).json")
        try "[]".write(to: alertsFile, atomically: true, encoding: .utf8)
        try "[]".write(to: computersFile, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: alertsFile)
            try? FileManager.default.removeItem(at: computersFile)
        }

        let snapshot = ProtectDashboardService.load(
            overviewURL: nil, alertsURL: alertsFile, computersURL: computersFile, insightsURL: nil
        )

        XCTAssertNotNil(snapshot.sourceDates["protect-alerts"])
        XCTAssertNotNil(snapshot.sourceDates["protect-computers"])
        XCTAssertNil(snapshot.sourceDates["protect-overview"])
        XCTAssertNil(snapshot.sourceDates["protect-insights"])
        XCTAssertNil(snapshot.sourceDates["protect-plans"])
    }

    func testSourceDatesEmptyWhenAllURLsNil() {
        let snapshot = ProtectDashboardService.load(
            overviewURL: nil, alertsURL: nil, computersURL: nil, insightsURL: nil
        )
        XCTAssertTrue(snapshot.sourceDates.isEmpty)
    }
}
