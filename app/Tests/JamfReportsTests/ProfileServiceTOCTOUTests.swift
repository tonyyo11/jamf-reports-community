import Foundation
import XCTest
@testable import JamfReports

/// v2.1.1 review item #12: ProfileService.removeLocalWorkspace had a TOCTOU
/// window — it called fileExists(atPath:) then removeItem(at:). The fix drops
/// the guard and catches NSFileNoSuchFileError from removeItem directly,
/// returning false (not throws) when the path is already gone.
final class ProfileServiceTOCTOUTests: XCTestCase {
    private let fm = FileManager.default

    func test_removeLocalWorkspace_existingDir_removesAndReturnsTrue() throws {
        let root = try temporaryWorkspaceRoot()
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        let profile = "toctou-test"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)

        let result = try ProfileService.removeLocalWorkspace(profile: profile)
        XCTAssertTrue(result)
        XCTAssertFalse(fm.fileExists(atPath: workspace.path))
    }

    func test_removeLocalWorkspace_alreadyRemoved_returnsFalse() throws {
        let root = try temporaryWorkspaceRoot()
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        // Do not create the workspace directory — it simply doesn't exist.
        let profile = "toctou-absent"
        // Must not throw; must return false to signal "nothing was removed".
        let result = try ProfileService.removeLocalWorkspace(profile: profile)
        XCTAssertFalse(result)
    }

    func test_removeLocalWorkspace_removedBetweenCallsSimulated() throws {
        // Simulate the TOCTOU race by removing the directory between the point
        // where a guard check would have passed and the removeItem call.
        // With the fix (no fileExists guard), the function still returns false
        // when removeItem throws NSFileNoSuchFileError.
        let root = try temporaryWorkspaceRoot()
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        let profile = "toctou-race"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        // Create it…
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        // …then remove it externally before calling the API.
        try fm.removeItem(at: workspace)

        // With the fix, this must return false (not throw).
        let result = try ProfileService.removeLocalWorkspace(profile: profile)
        XCTAssertFalse(result)
    }

    func test_removeLocalWorkspace_invalidProfile_throws() {
        XCTAssertThrowsError(try ProfileService.removeLocalWorkspace(profile: "../evil"))
        XCTAssertThrowsError(try ProfileService.removeLocalWorkspace(profile: ""))
    }

    // MARK: - Helpers

    private func temporaryWorkspaceRoot() throws -> URL {
        let root = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
