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
}
