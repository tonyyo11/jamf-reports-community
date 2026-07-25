import XCTest
@testable import JamfReports

@MainActor
final class ProtectDashboardServiceTests: XCTestCase {

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
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("plans-array-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"""
        [{"name":"Standard","uuid":"u1","threatPreventionStrategy":"BALANCED",
          "logLevel":"INFO","autoUpdate":true,"telemetry":true,"profileVersion":3}]
        """#.write(to: url, atomically: true, encoding: .utf8)

        let snapshot = ProtectDashboardService.load(
            overviewURL: nil, alertsURL: nil, computersURL: nil, insightsURL: nil, plansURL: url)

        XCTAssertTrue(snapshot.isDetected, "a decoded plans file should mark Protect detected")
        XCTAssertEqual(snapshot.plans.count, 1)
        XCTAssertEqual(snapshot.plans.first?.name, "Standard")
        XCTAssertEqual(snapshot.plans.first?.threatPreventionStrategy, "BALANCED")
        XCTAssertEqual(snapshot.plans.first?.autoUpdate, true)
    }

    func testLoadPlansDecodesNodesEnvelope() throws {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("plans-nodes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"nodes":[{"name":"Premium","threatPreventionStrategy":"AGGRESSIVE"}]}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let snapshot = ProtectDashboardService.load(
            overviewURL: nil, alertsURL: nil, computersURL: nil, insightsURL: nil, plansURL: url)

        XCTAssertEqual(snapshot.plans.count, 1)
        XCTAssertEqual(snapshot.plans.first?.name, "Premium")
    }

    func testDecodeParityWithMockData() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let alertsFile = tempDir.appendingPathComponent("alerts-test.json")
        let computersFile = tempDir.appendingPathComponent("computers-test.json")

        // Mock alerts JSON
        let alertsJSON = """
        [
            {
                "uuid": "alert1",
                "created": "2024-05-12T10:00:00Z",
                "severity": "Critical",
                "status": "Open",
                "eventType": "Malware",
                "hostName": "TestMac",
                "serial": "TEST123"
            },
            {
                "uuid": "alert2",
                "created": "2024-05-12T09:00:00Z",
                "severity": "High",
                "status": "Investigating",
                "eventType": "Network",
                "hostName": "TestMac2",
                "serial": "TEST456"
            },
            {
                "uuid": "alert3",
                "created": "2024-05-12T08:00:00Z",
                "severity": "Medium",
                "status": "Resolved",
                "eventType": "Policy",
                "hostName": "TestMac3",
                "serial": "TEST789"
            }
        ]
        """

        // Mock computers JSON
        let computersJSON = """
        [
            {
                "uuid": "comp1",
                "hostName": "TestMac1",
                "serial": "TEST123",
                "webProtectionActive": true,
                "fullDiskAccess": true,
                "connectionStatus": "Connected"
            },
            {
                "uuid": "comp2",
                "hostName": "TestMac2",
                "serial": "TEST456",
                "webProtectionActive": false,
                "fullDiskAccess": true,
                "connectionStatus": "Disconnected"
            },
            {
                "uuid": "comp3",
                "hostName": "TestMac3",
                "serial": "TEST789",
                "webProtectionActive": true,
                "fullDiskAccess": false,
                "connectionStatus": "Online"
            }
        ]
        """

        try alertsJSON.write(to: alertsFile, atomically: true, encoding: .utf8)
        try computersJSON.write(to: computersFile, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: alertsFile)
            try? FileManager.default.removeItem(at: computersFile)
        }

        let snapshot = ProtectDashboardService.load(
            overviewURL: nil,
            alertsURL: alertsFile,
            computersURL: computersFile,
            insightsURL: nil
        )

        XCTAssertTrue(snapshot.isDetected, "Should be detected when valid data exists")
        XCTAssertEqual(snapshot.alerts.count, 3)
        XCTAssertEqual(snapshot.computers.count, 3)
        XCTAssertEqual(snapshot.totalComputers, 3)

        // Web protection: 2 out of 3 computers have it active
        XCTAssertEqual(snapshot.webProtectionActiveCount, 2)

        // Full disk access: 2 out of 3 computers have it
        XCTAssertEqual(snapshot.fullDiskAccessCount, 2)

        // Connected: "Connected" and "Online" should both count as connected
        XCTAssertEqual(snapshot.connectedCount, 2)

        // Alert severity breakdown
        XCTAssertEqual(snapshot.criticalAlerts, 1)
        XCTAssertEqual(snapshot.highAlerts, 1)
        XCTAssertEqual(snapshot.mediumAlerts, 1)
        XCTAssertEqual(snapshot.lowAlerts, 0)

        // Should have a source file (most recent between alerts and computers)
        XCTAssertNotNil(snapshot.sourceFile)
        XCTAssertNotNil(snapshot.snapshotDate)
    }

    func testConnectionPredicateCaseInsensitivity() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let computersFile = tempDir.appendingPathComponent("computers-connection-test.json")

        // Mock computers JSON with various connection statuses
        let computersJSON = """
        [
            {
                "uuid": "1",
                "hostName": "Mac1",
                "connectionStatus": "connected"
            },
            {
                "uuid": "2",
                "hostName": "Mac2",
                "connectionStatus": "CONNECTED"
            },
            {
                "uuid": "3",
                "hostName": "Mac3",
                "connectionStatus": "Online"
            },
            {
                "uuid": "4",
                "hostName": "Mac4",
                "connectionStatus": "ONLINE"
            },
            {
                "uuid": "5",
                "hostName": "Mac5",
                "connectionStatus": "Disconnected"
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

        // Verify that all case variations are recognized as connected (4 out of 5)
        XCTAssertEqual(snapshot.connectedCount, 4, "Should recognize 'connected', 'CONNECTED', 'Online', 'ONLINE' as connected")
        XCTAssertEqual(snapshot.totalComputers, 5)
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

        // Mock insights JSON with mixed pass/fail counts
        let insightsJSON = """
        [
            {
                "uuid": "i1",
                "label": "Test1",
                "totalPass": 10,
                "totalFail": 0
            },
            {
                "uuid": "i2",
                "label": "Test2",
                "totalPass": 8,
                "totalFail": 2
            },
            {
                "uuid": "i3",
                "label": "Test3",
                "totalPass": 5,
                "totalFail": 5
            },
            {
                "uuid": "i4",
                "label": "Test4",
                "totalPass": 0,
                "totalFail": 0
            }
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

        XCTAssertEqual(snapshot.failingInsights, 2, "Should count insights with totalFail > 0 (i2 and i3)")
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
          {"uuid": "a1", "eventType": "Malware", "severity": "high"},
          {"uuid": "a2", "eventType": "Malware", "severity": "high"},
          {"uuid": "a3", "eventType": "Network", "severity": "medium"},
          {"uuid": "a4", "eventType": "Policy", "severity": "low"},
          {"uuid": "a5", "severity": "low"}
        ]
        """
        try alertsJSON.write(to: alertsFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: alertsFile) }

        let snapshot = ProtectDashboardService.load(
            overviewURL: nil, alertsURL: alertsFile, computersURL: nil, insightsURL: nil
        )
        let buckets = ProtectDashboardService.killChainBuckets(snapshot.alerts)
        XCTAssertEqual(buckets.count, 4)
        XCTAssertEqual(buckets[0].stage, "Malware")
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
          {"uuid": "c1", "hostName": "h1", "version": "4.6.0"},
          {"uuid": "c2", "hostName": "h2", "version": "4.6.0"},
          {"uuid": "c3", "hostName": "h3", "version": "4.5.2"},
          {"uuid": "c4", "hostName": "h4"}
        ]
        """
        try computersJSON.write(to: computersFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: computersFile) }

        let snapshot = ProtectDashboardService.load(
            overviewURL: nil, alertsURL: nil, computersURL: computersFile, insightsURL: nil
        )
        let versions = ProtectDashboardService.agentVersionDistribution(snapshot.computers)
        XCTAssertEqual(versions.count, 3)
        XCTAssertEqual(versions[0].version, "4.6.0")
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
          {"uuid": "a1", "hostName": "Mac-001", "created": "2026-05-01T08:00:00Z"},
          {"uuid": "a2", "hostName": "mac-001", "created": "2026-05-03T08:00:00Z"},
          {"uuid": "a3", "hostName": "Mac-002", "created": "2026-05-02T08:00:00Z"}
        ]
        """
        try alertsJSON.write(to: alertsFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: alertsFile) }

        let snapshot = ProtectDashboardService.load(
            overviewURL: nil, alertsURL: alertsFile, computersURL: nil, insightsURL: nil
        )
        let timeline = ProtectDashboardService.alertTimeline(for: "mac-001", in: snapshot.alerts)
        XCTAssertEqual(timeline.count, 2)
        XCTAssertEqual(timeline.first?.uuid, "a2")
        XCTAssertEqual(timeline.last?.uuid, "a1")
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