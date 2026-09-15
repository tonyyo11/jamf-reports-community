import XCTest
import SwiftUI
@testable import JamfReports

/// Tests for ``ComplianceBenchmarksView``. The view's `body` is not
/// directly testable, so these tests exercise the pure
/// ``decideLockState(...)`` state machine the body switches on.
@MainActor
final class ComplianceBenchmarksViewTests: XCTestCase {

    func testInstantiatesInDemoMode() {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = true
        _ = ComplianceBenchmarksView().environment(workspace)
    }

    func testInstantiatesOutsideDemoMode() {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = false
        _ = ComplianceBenchmarksView().environment(workspace)
    }

    // MARK: - decideLockState semantics

    func testLockedWhenExperimentalFlagOff() {
        XCTAssertEqual(
            ComplianceBenchmarksView.decideLockState(
                isDemoMode: false,
                experimentalOn: false,
                platformAvailable: true,
                hasData: true
            ),
            .locked
        )
    }

    func testLockedWhenPlatformCapabilityUnavailable() {
        XCTAssertEqual(
            ComplianceBenchmarksView.decideLockState(
                isDemoMode: false,
                experimentalOn: true,
                platformAvailable: false,
                hasData: true
            ),
            .locked
        )
    }

    func testUnlockedNoDataWhenBothChecksPassButNoSnapshots() {
        XCTAssertEqual(
            ComplianceBenchmarksView.decideLockState(
                isDemoMode: false,
                experimentalOn: true,
                platformAvailable: true,
                hasData: false
            ),
            .unlockedNoData
        )
    }

    func testUnlockedWithDataWhenAllConditionsMet() {
        XCTAssertEqual(
            ComplianceBenchmarksView.decideLockState(
                isDemoMode: false,
                experimentalOn: true,
                platformAvailable: true,
                hasData: true
            ),
            .unlockedWithData
        )
    }

    func testDemoModeBypassesGatesAndShowsData() {
        XCTAssertEqual(
            ComplianceBenchmarksView.decideLockState(
                isDemoMode: true,
                experimentalOn: false,
                platformAvailable: false,
                hasData: true
            ),
            .unlockedWithData
        )
    }

    func testDemoModeWithoutDataIsEmptyNotLocked() {
        XCTAssertEqual(
            ComplianceBenchmarksView.decideLockState(
                isDemoMode: true,
                experimentalOn: false,
                platformAvailable: false,
                hasData: false
            ),
            .unlockedNoData
        )
    }

    /// Collect skips benchmarks on a tenant-level profile, so "collect this workspace" would be a
    /// dead end; the screen names the integration level instead.
    func testATenantLevelProfileWithoutDataNeedsAnEnvironmentIntegration() {
        XCTAssertEqual(
            ComplianceBenchmarksView.decideLockState(
                isDemoMode: false, experimentalOn: true, platformAvailable: true,
                hasData: false, tenantLevel: true),
            .needsEnvironmentLevel
        )
    }

    func testSnapshotsCollectedBeforeASwitchToTenantLevelStillShow() {
        XCTAssertEqual(
            ComplianceBenchmarksView.decideLockState(
                isDemoMode: false, experimentalOn: true, platformAvailable: true,
                hasData: true, tenantLevel: true),
            .unlockedWithData
        )
    }

    // MARK: - Per-benchmark display (2.8.1)

    func testSeveralBenchmarksShowOneAtATime() {
        func rule(_ benchmark: String) -> ComplianceBenchmarksService.Snapshot.Rule {
            .init(rule: "FileVault", passed: 1, failed: 0, unknown: 0, devices: 1,
                  passRate: "100%", ruleId: "r1", benchmark: benchmark)
        }
        let snapshot = ComplianceBenchmarksService.Snapshot(
            rules: [rule("CIS"), rule("STIG")], devices: [],
            rulesSourceFile: nil, devicesSourceFile: nil, snapshotDate: nil)
        func shown(_ selected: String) -> [String] {
            ComplianceBenchmarksView.displayed(snapshot, selected: selected).rules.map(\.benchmark)
        }
        XCTAssertEqual(shown(""), ["CIS"], "defaults to the first benchmark")
        XCTAssertEqual(shown("STIG"), ["STIG"])
        XCTAssertEqual(shown("Removed since"), ["CIS"], "a vanished selection falls back")
    }

    func testOneBenchmarkShowsEverything() {
        let snapshot = ComplianceBenchmarksService.Snapshot(
            rules: [.init(rule: "FileVault", passed: 1, failed: 0, unknown: 0, devices: 1,
                          passRate: "100%", benchmark: "CIS")],
            devices: [], rulesSourceFile: nil, devicesSourceFile: nil, snapshotDate: nil)
        XCTAssertNil(ComplianceBenchmarksView.activeBenchmark(in: snapshot, selected: ""))
        XCTAssertEqual(ComplianceBenchmarksView.displayed(snapshot, selected: "").rules.count, 1)
    }
}
