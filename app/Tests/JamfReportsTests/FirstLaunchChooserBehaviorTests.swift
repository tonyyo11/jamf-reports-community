import Foundation
import XCTest
@testable import JamfReports

/// Behavior tests for the first-launch chooser plumbing in `WorkspaceStore.init`.
///
/// Before this change, an empty real-profile list silently flipped the store
/// into demo mode. That hid the "blank slate" state from the UI, so the new
/// `FirstLaunchChooserView` (rendered by `ContentView` when
/// `profiles.isEmpty && !demoMode`) could never appear on a real first launch.
///
/// The init now consults the persisted `forceDemoModeKey` (the same key
/// `setDemoMode(_:)` writes) instead of `realProfiles.isEmpty`. Tests below
/// pin both the workspace root (`JRC_TEST_WORKSPACES_ROOT`, only honored in
/// DEBUG builds) and the UserDefaults flag so each case runs in isolation.
@MainActor
final class FirstLaunchChooserBehaviorTests: XCTestCase {

    // `nonisolated(unsafe)` per saved memory `swift_test_concurrency_pattern.md`
    // — the only combination that satisfies both Swift 6.0/6.1 (CI's Xcode 16.4)
    // and Swift 6.3 (local) for @MainActor XCTestCase subclasses with stored
    // properties touched from setUp.
    private nonisolated(unsafe) var workspacesRoot: URL!
    private nonisolated(unsafe) var testRoot: URL!

    override func setUp() {
        super.setUp()
        testRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "FirstLaunchChooser-\(UUID().uuidString)",
                isDirectory: true
            )
        workspacesRoot = testRoot.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        UserDefaults.standard.removeObject(forKey: WorkspaceStore.forceDemoModeKey)
    }

    override func tearDown() {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        UserDefaults.standard.removeObject(forKey: WorkspaceStore.forceDemoModeKey)
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
        super.tearDown()
    }

    // MARK: - Init no longer auto-flips to demo

    /// Fresh install: no real profiles, no persisted demo preference.
    /// The chooser route depends on `!demoMode` so init must NOT silently
    /// flip into demo just because the workspace dir is empty.
    ///
    /// Only `demoMode` is asserted here. The companion assertion would be
    /// `profiles.isEmpty`, but `ProfileService.discoverLocal()` reads
    /// `~/.config/jamf-cli/config.yaml` directly — independent of
    /// `JRC_TEST_WORKSPACES_ROOT` — so a developer with real jamf-cli
    /// profiles configured would see this assertion fail spuriously. CI
    /// (per saved memory `swift_ci_environment.md`) has a clean home and
    /// no jamf-cli, so `discoverLocal()` returns `[]` there; the
    /// `ContentView` route condition `profiles.isEmpty && !demoMode`
    /// would hold. Locally, the demoMode side of that condition is the
    /// only piece this code change owns — so that's all we assert.
    func testInitWithEmptyRealProfilesAndNoFlagDoesNotEnterDemoMode() {
        let store = WorkspaceStore()

        XCTAssertFalse(
            store.demoMode,
            "Fresh-launch init must not auto-enable demo — the chooser is responsible for that decision"
        )
    }

    // MARK: - Init still honors persisted demo preference

    /// User previously clicked "Try the demo first" (or the menu's Demo
    /// Mode toggle). `setDemoMode(true)` persisted `forceDemoModeKey`; on
    /// next launch the init must restore demo mode without showing the
    /// chooser again.
    func testInitWithForceDemoModeFlagEnablesDemoMode() {
        UserDefaults.standard.set(true, forKey: WorkspaceStore.forceDemoModeKey)

        let store = WorkspaceStore()

        XCTAssertTrue(
            store.demoMode,
            "Persisted forceDemoModeKey must restore demo mode on init"
        )
        XCTAssertFalse(
            store.profiles.isEmpty,
            "Demo mode init must populate profiles with DemoData.cliProfiles"
        )
    }

    // MARK: - Explicit constructor override wins

    /// Test seam: `WorkspaceStore(demoMode: false)` must override the
    /// persisted flag so existing tests can construct a non-demo store
    /// even when a sibling test polluted `forceDemoModeKey`.
    func testExplicitDemoModeFalseOverridesPersistedFlag() {
        UserDefaults.standard.set(true, forKey: WorkspaceStore.forceDemoModeKey)

        let store = WorkspaceStore(demoMode: false)

        XCTAssertFalse(
            store.demoMode,
            "Explicit demoMode:false must override the persisted forceDemoModeKey"
        )
    }

    /// Symmetric to the above: an explicit `demoMode: true` must enable
    /// demo mode regardless of the persisted flag.
    func testExplicitDemoModeTrueOverridesPersistedFlag() {
        UserDefaults.standard.removeObject(forKey: WorkspaceStore.forceDemoModeKey)

        let store = WorkspaceStore(demoMode: true)

        XCTAssertTrue(
            store.demoMode,
            "Explicit demoMode:true must enable demo mode regardless of the persisted flag"
        )
    }

    // MARK: - View instantiation smoke test

    /// Mirrors the LightModeRenderTests / PostureViewsRenderTests pattern:
    /// confirm the new chooser view at least instantiates without
    /// crashing. Closure is a no-op stand-in for the parent's
    /// `userPickedOnboarding = true` flip.
    func testFirstLaunchChooserViewInstantiates() {
        let workspace = WorkspaceStore(demoMode: false)
        _ = FirstLaunchChooserView(onStartOnboarding: {}).environment(workspace)
    }
}
