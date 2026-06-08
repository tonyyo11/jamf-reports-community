import XCTest
@testable import JamfReports

/// Tests for UpdateStatusService and UpdatesView instantiation.
@MainActor
final class UpdateStatusServiceTests: XCTestCase {

    func testUpdatesViewInstantiatesInDemoMode() throws {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = true

        _ = UpdatesView().environment(workspace)
    }

    func testUpdatesViewInstantiatesOutsideDemoMode() throws {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = false

        _ = UpdatesView().environment(workspace)
    }

    /// Tests decode parity with summary-only JSON (no failure arrays).
    func testUpdateStatusServiceDecodesSummaryOnlyReport() throws {
        let json = """
        [
          {
            "total": 150,
            "status_summary": [
              {"status": "COMPLETED", "count": 120},
              {"status": "PENDING", "count": 20},
              {"status": "ERROR", "count": 10}
            ],
            "plan_total": 8,
            "plan_state_summary": [
              {"state": "PlanCompleted", "count": 5},
              {"state": "PlanActive", "count": 2},
              {"state": "PlanFailed", "count": 1}
            ]
          }
        ]
        """

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-status-test-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let snapshot = try XCTUnwrap(UpdateStatusService.load(from: tmp))

        XCTAssertEqual(snapshot.total, 150)
        XCTAssertEqual(snapshot.planTotal, 8)
        XCTAssertEqual(snapshot.statusBreakdown.count, 3)
        XCTAssertEqual(snapshot.planStateBreakdown.count, 3)
        XCTAssertTrue(snapshot.errorDevices.isEmpty)
        XCTAssertTrue(snapshot.failedPlans.isEmpty)

        // Verify breakdown contents
        let statusByLabel = Dictionary(uniqueKeysWithValues:
            snapshot.statusBreakdown.map { ($0.label, $0.count) }
        )
        XCTAssertEqual(statusByLabel["COMPLETED"], 120)
        XCTAssertEqual(statusByLabel["PENDING"], 20)
        XCTAssertEqual(statusByLabel["ERROR"], 10)

        let planByLabel = Dictionary(uniqueKeysWithValues:
            snapshot.planStateBreakdown.map { ($0.label, $0.count) }
        )
        XCTAssertEqual(planByLabel["PlanCompleted"], 5)
        XCTAssertEqual(planByLabel["PlanActive"], 2)
        XCTAssertEqual(planByLabel["PlanFailed"], 1)
    }

    /// Tests decode parity with scan-failures JSON.
    func testUpdateStatusServiceDecodesFailuresReport() throws {
        let json = """
        [
          {
            "total": 100,
            "status_summary": [
              {"status": "COMPLETED", "count": 80},
              {"status": "ERROR", "count": 20}
            ],
            "error_devices": [
              {
                "name": "MacBook-001",
                "serial": "ABC123",
                "device_type": "Computer",
                "os_version": "15.2.1",
                "username": "jdoe",
                "status": "ERROR",
                "product_key": "macOS Sequoia 15.3",
                "updated": "2026-05-10T10:30:00Z"
              }
            ],
            "plan_total": 5,
            "plan_state_summary": [
              {"state": "PlanCompleted", "count": 4},
              {"state": "PlanFailed", "count": 1}
            ],
            "failed_plans": [
              {
                "name": "MacBook-035",
                "serial": "JKL012",
                "device_type": "Computer",
                "os_version": "14.7.5",
                "username": "cjohnson",
                "state": "PlanFailed",
                "action": "Install",
                "version": "15.3",
                "error": "Insufficient disk space",
                "last_event": "2026-05-11T14:20:00Z"
              }
            ]
          }
        ]
        """

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-failures-test-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let snapshot = try XCTUnwrap(UpdateStatusService.load(from: tmp))

        XCTAssertEqual(snapshot.total, 100)
        XCTAssertEqual(snapshot.planTotal, 5)
        XCTAssertEqual(snapshot.errorDevices.count, 1)
        XCTAssertEqual(snapshot.failedPlans.count, 1)

        // Verify error device
        let errorDevice = snapshot.errorDevices.first!
        XCTAssertEqual(errorDevice.name, "MacBook-001")
        XCTAssertEqual(errorDevice.serial, "ABC123")
        XCTAssertEqual(errorDevice.status, "ERROR")

        // Verify failed plan
        let failedPlan = snapshot.failedPlans.first!
        XCTAssertEqual(failedPlan.name, "MacBook-035")
        XCTAssertEqual(failedPlan.serial, "JKL012")
        XCTAssertEqual(failedPlan.state, "PlanFailed")
        XCTAssertEqual(failedPlan.error, "Insufficient disk space")
    }

    /// Tests color mapping for plan states.
    func testUpdateStatusServiceSliceColorMapping() throws {
        let json = """
        [
          {
            "total": 50,
            "status_summary": [],
            "plan_total": 3,
            "plan_state_summary": [
              {"state": "PlanCompleted", "count": 1},
              {"state": "PlanFailed", "count": 1},
              {"state": "PlanActive", "count": 1}
            ]
          }
        ]
        """

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("color-mapping-test-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let snapshot = try XCTUnwrap(UpdateStatusService.load(from: tmp))

        let colorByState = Dictionary(uniqueKeysWithValues:
            snapshot.planStateBreakdown.map { ($0.label, $0.colorHex) }
        )

        XCTAssertEqual(colorByState["PlanCompleted"], 0x30D158)  // green
        XCTAssertEqual(colorByState["PlanFailed"], 0xFF453A)     // red
        XCTAssertEqual(colorByState["PlanActive"], 0x007AFF)     // blue
    }

    /// Tests empty input handling.
    func testUpdateStatusServiceHandlesEmptyInput() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-test-\(UUID().uuidString).json")
        try "invalid json".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let snapshot = UpdateStatusService.load(from: tmp)
        XCTAssertNil(snapshot)
    }

    // MARK: - KPI honesty: scan-failures availability + plan-state failures

    /// Production bug: a summary-only snapshot (no --scan-failures) showed
    /// "0 failing plans / 0 error devices" while the plan-state donut showed
    /// thousands of PlanFailed entries. The empty arrays mean "not scanned",
    /// never "zero failures".
    func testSummaryOnlySnapshotReportsScanNotAvailable() throws {
        let json = """
        [
          {
            "total": 864,
            "status_summary": [{"status": "IDLE", "count": 641}],
            "plan_total": 4421,
            "plan_state_summary": [
              {"state": "PlanFailed", "count": 3724},
              {"state": "PlanCompleted", "count": 656},
              {"state": "PlanException", "count": 13},
              {"state": "PlanCanceled", "count": 4}
            ]
          }
        ]
        """
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kpi-honesty-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let snapshot = try XCTUnwrap(UpdateStatusService.load(from: tmp))

        XCTAssertFalse(snapshot.scanFailuresAvailable)
        // PlanFailed (3724) + PlanException (13); PlanCanceled is a user
        // action, not a failure; PlanCompleted is success.
        XCTAssertEqual(snapshot.plansFailedFromStates, 3737)
    }

    func testFailuresSnapshotReportsScanAvailable() throws {
        let json = """
        [
          {
            "total": 100,
            "status_summary": [{"status": "COMPLETED", "count": 100}],
            "error_devices": [],
            "plan_total": 5,
            "plan_state_summary": [{"state": "PlanCompleted", "count": 5}],
            "failed_plans": []
          }
        ]
        """
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-available-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let snapshot = try XCTUnwrap(UpdateStatusService.load(from: tmp))

        // Scan ran and found nothing — "0" is now a true statement.
        XCTAssertTrue(snapshot.scanFailuresAvailable)
        XCTAssertEqual(snapshot.plansFailedFromStates, 0)
        XCTAssertTrue(snapshot.errorDevices.isEmpty)
    }

    // MARK: - CacheSource derivation

    func testCacheSourceWithNilSnapshotDate() {
        let snapshot = UpdateStatusService.Snapshot(
            total: 0,
            planTotal: 0,
            statusBreakdown: [],
            planStateBreakdown: [],
            errorDevices: [],
            failedPlans: [],
            sourceFile: nil,
            snapshotDate: nil
        )
        XCTAssertEqual(snapshot.cacheSource, .neverFetchedLive)
    }

    func testCacheSourceWithFreshSnapshotDate() {
        let recent = Date(timeIntervalSinceNow: -1800) // 30 minutes ago
        let snapshot = UpdateStatusService.Snapshot(
            total: 0,
            planTotal: 0,
            statusBreakdown: [],
            planStateBreakdown: [],
            errorDevices: [],
            failedPlans: [],
            sourceFile: nil,
            snapshotDate: recent
        )
        XCTAssertEqual(snapshot.cacheSource, .fresh)
    }

    func testCacheSourceWithStaleSnapshotDate() {
        let stale = Date(timeIntervalSinceNow: -48 * 3600) // 48 hours ago
        let snapshot = UpdateStatusService.Snapshot(
            total: 0,
            planTotal: 0,
            statusBreakdown: [],
            planStateBreakdown: [],
            errorDevices: [],
            failedPlans: [],
            sourceFile: nil,
            snapshotDate: stale
        )
        XCTAssertEqual(snapshot.cacheSource, .stale(at: stale))
    }

    // MARK: - Snapshot equality

    /// `==` must include `snapshotDate`: two snapshots identical except for the
    /// date drive different `cacheSource` states, so equality that ignored the
    /// date would suppress a stale->fresh banner flip.
    func testSnapshotEqualityDistinguishesSnapshotDate() {
        func make(_ date: Date?) -> UpdateStatusService.Snapshot {
            UpdateStatusService.Snapshot(
                total: 1,
                planTotal: 1,
                statusBreakdown: [],
                planStateBreakdown: [],
                errorDevices: [],
                failedPlans: [],
                sourceFile: nil,
                snapshotDate: date
            )
        }
        let fresh = Date(timeIntervalSinceNow: -1800)
        let stale = Date(timeIntervalSinceNow: -48 * 3600)
        XCTAssertNotEqual(make(fresh), make(stale))
        XCTAssertEqual(make(fresh), make(fresh))
    }

    func testUpdateStatusServiceReturnsEmptyForMissingFile() throws {
        let snapshot = UpdateStatusService.load(profile: "nonexistent-profile")
        XCTAssertEqual(snapshot, .empty)
        XCTAssertEqual(snapshot.total, 0)
        XCTAssertEqual(snapshot.planTotal, 0)
        XCTAssertTrue(snapshot.statusBreakdown.isEmpty)
        XCTAssertTrue(snapshot.planStateBreakdown.isEmpty)
        XCTAssertTrue(snapshot.errorDevices.isEmpty)
        XCTAssertTrue(snapshot.failedPlans.isEmpty)
    }
}