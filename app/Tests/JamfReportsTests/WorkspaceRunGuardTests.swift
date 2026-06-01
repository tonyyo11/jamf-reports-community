import XCTest
@testable import JamfReports

@MainActor
final class WorkspaceRunGuardTests: XCTestCase {

    func testRunGuardInitialState() {
        let workspace = WorkspaceStore(demoMode: true)
        XCTAssertFalse(workspace.isRunInProgress(for: "test-profile"))
    }

    func testSetRunInProgressSuccess() {
        let workspace = WorkspaceStore(demoMode: true)
        let success = workspace.setRunInProgress(for: "test-profile")

        XCTAssertTrue(success, "Should successfully set run in progress")
        XCTAssertTrue(workspace.isRunInProgress(for: "test-profile"))
    }

    func testSetRunInProgressFailsWhenAlreadyRunning() {
        let workspace = WorkspaceStore(demoMode: true)

        let first = workspace.setRunInProgress(for: "test-profile")
        let second = workspace.setRunInProgress(for: "test-profile")

        XCTAssertTrue(first, "First call should succeed")
        XCTAssertFalse(second, "Second call should fail")
        XCTAssertTrue(workspace.isRunInProgress(for: "test-profile"))
    }

    func testClearRunInProgress() {
        let workspace = WorkspaceStore(demoMode: true)

        workspace.setRunInProgress(for: "test-profile")
        XCTAssertTrue(workspace.isRunInProgress(for: "test-profile"))

        workspace.clearRunInProgress(for: "test-profile")
        XCTAssertFalse(workspace.isRunInProgress(for: "test-profile"))
    }

    func testRunGuardPerProfile() {
        let workspace = WorkspaceStore(demoMode: true)

        workspace.setRunInProgress(for: "profile-a")

        XCTAssertTrue(workspace.isRunInProgress(for: "profile-a"))
        XCTAssertFalse(workspace.isRunInProgress(for: "profile-b"))

        let successA = workspace.setRunInProgress(for: "profile-a")
        let successB = workspace.setRunInProgress(for: "profile-b")

        XCTAssertFalse(successA, "Profile A should fail (already running)")
        XCTAssertTrue(successB, "Profile B should succeed (different profile)")
    }

    func testClearRunInProgressIdempotent() {
        let workspace = WorkspaceStore(demoMode: true)

        // Clear when nothing is running should not crash
        workspace.clearRunInProgress(for: "test-profile")
        XCTAssertFalse(workspace.isRunInProgress(for: "test-profile"))

        // Clear after already cleared should not crash
        workspace.setRunInProgress(for: "test-profile")
        workspace.clearRunInProgress(for: "test-profile")
        workspace.clearRunInProgress(for: "test-profile")
        XCTAssertFalse(workspace.isRunInProgress(for: "test-profile"))
    }
}