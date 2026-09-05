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

    private func decide(demo: Bool = false, experimental: Bool = true, platform: Bool = true,
                        platformData: Bool = false, deviceData: Bool = false, enabled: Int = 0,
                        deviceSnapshot: Bool = false) -> DDMBlueprintView.LockState {
        DDMBlueprintView.decideLockState(
            isDemoMode: demo, experimentalOn: experimental, platformAvailable: platform,
            hasPlatformData: platformData, hasDeviceData: deviceData, ddmEnabledCount: enabled,
            hasDeviceSnapshot: deviceSnapshot)
    }

    func testLockedOnlyWhenNoInputExists() {
        XCTAssertEqual(decide(experimental: false, platform: false), .locked)
        XCTAssertEqual(decide(experimental: true, platform: true), .unlockedNoData,
                       "a platform profile with no snapshots yet is empty, not locked")
    }

    func testPerDeviceSnapshotUnlocksAnOnPremProfile() {
        XCTAssertEqual(
            decide(experimental: false, platform: false, deviceData: true), .unlockedWithData)
    }

    func testDDMEnabledCountAloneUnlocksToEmpty() {
        XCTAssertEqual(decide(experimental: false, platform: false, enabled: 6), .unlockedNoData,
                       "inventory says DDM is on; the scan has not run yet")
    }

    func testEmptyDeviceSnapshotUnlocksToEmptyNotLocked() {
        XCTAssertEqual(
            decide(experimental: false, platform: false, deviceSnapshot: true), .unlockedNoData,
            "the scan ran and found no DDM-enabled Macs — that's an empty result, not locked")
    }

    func testPlatformDataStillNeedsTheExperimentalGate() {
        XCTAssertEqual(decide(experimental: false, platform: true, platformData: true), .locked)
        XCTAssertEqual(
            decide(experimental: true, platform: true, platformData: true), .unlockedWithData)
    }

    func testDemoModeBypassesGates() {
        XCTAssertEqual(
            decide(demo: true, experimental: false, platform: false, platformData: true),
            .unlockedWithData)
        XCTAssertEqual(decide(demo: true, experimental: false, platform: false), .unlockedNoData)
    }

    // MARK: - showsPlatformSections

    func testShowsPlatformSectionsRequiresBothPlatformPathAndData() {
        XCTAssertFalse(DDMBlueprintView.showsPlatformSections(
            platformPath: false, hasPlatformData: true),
            "a snapshot left over from when the flag was on must not render once it's off")
        XCTAssertTrue(DDMBlueprintView.showsPlatformSections(
            platformPath: true, hasPlatformData: true))
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
