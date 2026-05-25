import XCTest
import SwiftUI
@testable import JamfReports

/// Tests for ``DDMBlueprintView``. The view's `body` is not directly
/// testable, so these tests exercise the pure ``decideLockState(...)``
/// state machine the body switches on, plus the row-sorting helpers
/// the table sections use.
@MainActor
final class DDMBlueprintViewTests: XCTestCase {

    func testInstantiatesInDemoMode() {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = true
        _ = DDMBlueprintView().environment(workspace)
    }

    func testInstantiatesOutsideDemoMode() {
        let workspace = WorkspaceStore()
        workspace.profile = "test"
        workspace.demoMode = false
        _ = DDMBlueprintView().environment(workspace)
    }

    // MARK: - decideLockState semantics

    func testLockedWhenExperimentalFlagOff() {
        XCTAssertEqual(
            DDMBlueprintView.decideLockState(
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
            DDMBlueprintView.decideLockState(
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
            DDMBlueprintView.decideLockState(
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
            DDMBlueprintView.decideLockState(
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
            DDMBlueprintView.decideLockState(
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
            DDMBlueprintView.decideLockState(
                isDemoMode: true,
                experimentalOn: false,
                platformAvailable: false,
                hasData: false
            ),
            .unlockedNoData
        )
    }

    // MARK: - Sort helpers

    func testBlueprintsSortFailedFirstThenPendingThenName() {
        let input: [DDMBlueprintService.Snapshot.Blueprint] = [
            .init(name: "Bravo", state: "DEPLOYED", scope: 10, steps: 1,
                  succeeded: 9, failed: 0, pending: 5),
            .init(name: "Alpha", state: "DEPLOYED", scope: 10, steps: 1,
                  succeeded: 9, failed: 0, pending: 0),
            .init(name: "Charlie", state: "DEPLOYED", scope: 10, steps: 1,
                  succeeded: 5, failed: 3, pending: 0),
        ]
        let sorted = DDMBlueprintView.sortedBlueprints(input)
        XCTAssertEqual(sorted.map(\.name), ["Charlie", "Bravo", "Alpha"],
                       "Failures sort first, then pending, then name")
    }

    func testDeclarationsSortUnsuccessfulFirstThenSource() {
        let input: [DDMBlueprintService.Snapshot.Declaration] = [
            .init(source: "Beta", type: "blueprint", declarations: 1,
                  devices: 1, successful: 1, unsuccessful: 0),
            .init(source: "Alpha", type: "blueprint", declarations: 1,
                  devices: 1, successful: 0, unsuccessful: 5),
            .init(source: "Gamma", type: "blueprint", declarations: 1,
                  devices: 1, successful: 0, unsuccessful: 5),
        ]
        let sorted = DDMBlueprintView.sortedDeclarations(input)
        XCTAssertEqual(sorted.map(\.source), ["Alpha", "Gamma", "Beta"],
                       "Unsuccessful sort first, then source name")
    }
}
