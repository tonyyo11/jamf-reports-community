import Foundation
import XCTest
@testable import JamfReports

final class ProfileServiceSecurityTests: XCTestCase {
    private let fileManager = FileManager.default

    func testRemoveLocalWorkspaceRejectsSymlinkEscapes() throws {
        let root = try temporaryWorkspaceRoot()
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        let profile = "safe-profile"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)

        // Create a symlink that points outside the root
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkURL = root.appendingPathComponent("malicious-link")
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: outside)

        // Refuse removal of the malicious link via the profile API
        XCTAssertThrowsError(try ProfileService.removeLocalWorkspace(profile: "malicious-link"))
        
        XCTAssertTrue(fileManager.fileExists(atPath: outside.path))
        XCTAssertTrue(fileManager.fileExists(atPath: linkURL.path))
    }

    private func temporaryWorkspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
