import Foundation
import XCTest
@testable import JamfReports

/// #207 G27/G10: demo mode runs no jamf-cli, yet the store's launch and ⌘R's
/// `reloadFromDisk` still asked jamf-cli for its profiles and its version.
@MainActor
final class WorkspaceStoreDemoJamfCLITests: XCTestCase {

    @MainActor private final class Calls {
        var discover = 0
        var version = 0
    }

    private func demoStore(_ calls: Calls) -> WorkspaceStore {
        WorkspaceStore(
            demoMode: true,
            jamfCLIProfileNames: { [] },
            discoverProfiles: { calls.discover += 1; return [] },
            jamfCLIInstallation: { calls.version += 1; return nil })
    }

    /// The demo the operator chose (Settings, or the first-launch chooser).
    private func chooseDemo() {
        let key = WorkspaceStore.forceDemoModeKey
        let saved = UserDefaults.standard.object(forKey: key) as? Bool
        UserDefaults.standard.set(true, forKey: key)
        addTeardownBlock {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    func testADemoStoreAsksJamfCLINothingAtLaunch() {
        let calls = Calls()

        _ = demoStore(calls)

        XCTAssertEqual(calls.discover, 0)
        XCTAssertEqual(calls.version, 0)
    }

    func testReloadingTheChosenDemoAsksJamfCLINothing() {
        chooseDemo()
        let calls = Calls()
        let store = demoStore(calls)

        store.reloadFromDisk()
        store.refreshToolStatus()

        XCTAssertTrue(store.demoMode)
        XCTAssertEqual(calls.discover, 0)
        XCTAssertEqual(calls.version, 0)
    }

    func testALiveStoreStillReadsJamfCLI() {
        let calls = Calls()
        let store = WorkspaceStore(
            demoMode: false,
            jamfCLIProfileNames: { [] },
            discoverProfiles: { calls.discover += 1; return [] },
            jamfCLIInstallation: { calls.version += 1; return nil })

        store.refreshToolStatus()

        XCTAssertEqual(calls.discover, 1)
        XCTAssertEqual(calls.version, 2)
    }
}
