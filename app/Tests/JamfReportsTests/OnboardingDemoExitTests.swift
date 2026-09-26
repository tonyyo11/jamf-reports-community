import Foundation
import XCTest
@testable import JamfReports

/// Finishing setup from demo mode leaves it through `setDemoMode(false)`, whose
/// cleanup removes what earlier builds wrote under the demo profile. Setup used
/// to clear the demo flag directly and skip that cleanup. A new profile named
/// like the demo's is the exception: the cleanup would delete its fresh
/// workspace.
@MainActor
final class OnboardingDemoExitTests: XCTestCase {

    // `nonisolated(unsafe)`: the combination FirstLaunchChooserBehaviorTests
    // uses for a @MainActor XCTestCase with stored properties set in setUp.
    private nonisolated(unsafe) var testRoot: URL!
    private nonisolated(unsafe) var workspacesRoot: URL!

    override func setUp() {
        super.setUp()
        testRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("OnboardingDemoExit-\(UUID().uuidString)", isDirectory: true)
        workspacesRoot = testRoot.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: workspacesRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        UserDefaults.standard.set(true, forKey: WorkspaceStore.forceDemoModeKey)
    }

    override func tearDown() {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        UserDefaults.standard.removeObject(forKey: WorkspaceStore.forceDemoModeKey)
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
        super.tearDown()
    }

    /// A workspace folder, with a config.yaml when it should be discovered.
    private func makeWorkspace(_ profile: String, withConfig: Bool) throws -> URL {
        let dir = workspacesRoot.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(withConfig ? "config.yaml" : "leftover.log")
        try Data("jamf_cli:\n  profile: \"\(profile)\"\n".utf8).write(to: file)
        return dir
    }

    /// A file inside `profile`'s workspace, with its folders.
    private func write(_ relativePath: String, in profile: String) throws {
        let file = workspacesRoot.appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: file)
    }

    func testFinishingSetupFromDemoRunsTheDemoCleanup() throws {
        _ = try makeWorkspace("acme", withConfig: true)
        let leftover = try makeWorkspace(DemoData.org.profile, withConfig: false)
        let store = WorkspaceStore(demoMode: true, jamfCLIProfileNames: { [] })
        let flow = OnboardingFlow()
        flow.profileName = "acme"

        flow.finishSetup(in: store)

        XCTAssertFalse(UserDefaults.standard.bool(forKey: WorkspaceStore.forceDemoModeKey))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leftover.path),
            "leaving demo mode must remove the demo profile's leftover workspace")
        XCTAssertFalse(store.demoMode, "the new real profile must replace the demo")
    }

    func testANewProfileNamedLikeTheDemoKeepsItsWorkspace() throws {
        let workspace = try makeWorkspace(DemoData.org.profile, withConfig: true)
        let store = WorkspaceStore(demoMode: true, jamfCLIProfileNames: { [] })
        let flow = OnboardingFlow()
        flow.profileName = DemoData.org.profile

        flow.finishSetup(in: store)

        XCTAssertFalse(UserDefaults.standard.bool(forKey: WorkspaceStore.forceDemoModeKey))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: workspace.path),
            "the demo cleanup must not delete a real workspace just set up under that name")
        XCTAssertFalse(store.demoMode)
    }

    /// Entering demo mode swaps in the demo's config. Leaving it has to drop that config, or
    /// the demo's agent and benchmark label the live screens and score real Macs.
    func testLeavingDemoDropsTheDemoConfig() throws {
        _ = try makeWorkspace("acme", withConfig: true)
        let store = WorkspaceStore(demoMode: true, jamfCLIProfileNames: { [] })
        XCTAssertEqual(store.configState, DemoData.configState)

        store.setDemoMode(false)

        XCTAssertFalse(store.demoMode)
        XCTAssertNotEqual(store.configState, DemoData.configState,
                          "the demo config must not outlive demo mode")
    }

    func testLeavingDemoKeepsAWorkspaceJamfCLIListsUnderTheDemoName() throws {
        let workspace = try makeWorkspace(DemoData.org.profile, withConfig: false)
        let store = WorkspaceStore(demoMode: true, jamfCLIProfileNames: { [DemoData.org.profile] })

        store.setDemoMode(false)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: workspace.path),
            "a jamf-cli profile named like the demo owns that workspace")
    }

    /// A shared or synced root another Mac collects into, or a workspace kept after
    /// its jamf-cli profile was removed: this Mac's jamf-cli does not list it.
    func testLeavingDemoKeepsADemoNamedWorkspaceHoldingCollectedData() throws {
        let workspace = try makeWorkspace(DemoData.org.profile, withConfig: false)
        try write("jamf-cli-data/computers/computers_2026-09-01_120000.json",
                  in: DemoData.org.profile)
        let store = WorkspaceStore(demoMode: true, jamfCLIProfileNames: { [] })

        store.setDemoMode(false)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent(
                    "jamf-cli-data/computers/computers_2026-09-01_120000.json").path),
            "leaving demo mode must never delete collected snapshots")
    }

    func testCollectedDataIsWhatOnlyACollectOrBackupWrites() throws {
        let profile = DemoData.org.profile
        _ = try makeWorkspace(profile, withConfig: true)
        try write("automation/logs/demo.log", in: profile)
        try write("jamf-cli-data/state/computers.cause.json", in: profile)
        try write("jamf-cli-data/sofa/macos_data_feed.json", in: profile)
        XCTAssertFalse(
            WorkspaceStore.workspaceHoldsCollectedData(profile: profile),
            "config, logs, state and the SOFA cache are what older demo builds could leave")

        for evidence in [
            "jamf-cli-data/policies/policies_2026-09-01_120000.json",
            "snapshots/summaries/summary_2026-09-01.json",
            "snapshots/computers/summaries/summary_2026-09-01.json",
            "snapshots/inventory_2026-09-01.csv",
            "backups/2026-09-01_120000/manifest.json",
            "_archive/computers/computers_2025-01-01_120000.json",
        ] {
            let dir = workspacesRoot.appendingPathComponent(profile, isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            _ = try makeWorkspace(profile, withConfig: true)
            try write(evidence, in: profile)
            XCTAssertTrue(
                WorkspaceStore.workspaceHoldsCollectedData(profile: profile), evidence)
        }
    }
}
