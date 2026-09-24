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

    func testFinishingSetupFromDemoRunsTheDemoCleanup() throws {
        _ = try makeWorkspace("acme", withConfig: true)
        let leftover = try makeWorkspace(DemoData.org.profile, withConfig: false)
        let store = WorkspaceStore(demoMode: true)
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
        let store = WorkspaceStore(demoMode: true)
        let flow = OnboardingFlow()
        flow.profileName = DemoData.org.profile

        flow.finishSetup(in: store)

        XCTAssertFalse(UserDefaults.standard.bool(forKey: WorkspaceStore.forceDemoModeKey))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: workspace.path),
            "the demo cleanup must not delete a real workspace just set up under that name")
        XCTAssertFalse(store.demoMode)
    }
}
