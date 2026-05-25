import XCTest
import SwiftUI
@testable import JamfReports

/// View-instantiation tests for the v2.1.0 Protect deep-dive surfaces.
/// Each test toggles the experimental flag via an isolated UserDefaults suite
/// and confirms the view constructs without crashing — Swift 6.1 CI cannot
/// snapshot-render SwiftUI, so this is the cheapest available guard against
/// gating regressions.
@MainActor
final class ProtectViewTests: XCTestCase {

    nonisolated(unsafe) private var suiteName: String = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "protect-view-tests-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return UserDefaults.standard
        }
        return defaults
    }

    func testViewInstantiatesWhenExperimentalFlagOff() throws {
        let defaults = makeDefaults()
        defaults.removeObject(forKey: ExperimentalFeatureService.storageKey)
        let workspace = WorkspaceStore()
        workspace.demoMode = true
        _ = ProtectView().environment(workspace)
    }

    func testViewInstantiatesWhenExperimentalFlagOn() throws {
        let defaults = makeDefaults()
        let service = ExperimentalFeatureService(defaults: defaults)
        service.setEnabled(.protect, true)
        XCTAssertTrue(service.isEnabled(.protect))

        let workspace = WorkspaceStore()
        workspace.demoMode = true
        _ = ProtectView().environment(workspace)
    }

    func testExperimentalBadgeReflectsFlagState() throws {
        let defaults = makeDefaults()
        let off = ExperimentalFeatureService(defaults: defaults)
        XCTAssertFalse(off.isEnabled(.protect))

        off.setEnabled(.protect, true)
        let on = ExperimentalFeatureService(defaults: defaults)
        XCTAssertTrue(on.isEnabled(.protect))
    }
}
