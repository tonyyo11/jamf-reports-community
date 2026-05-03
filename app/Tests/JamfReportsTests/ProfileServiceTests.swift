import Foundation
import XCTest
@testable import JamfReports

final class ProfileServiceTests: XCTestCase {
    func testProfileSlugValidationAcceptsSupportedShape() {
        let valid = [
            "a",
            "0",
            "dummy",
            "harbor-edu",
            "school.test",
            "profile_01",
            "tenant-1.prod",
        ]

        for profile in valid {
            XCTAssertTrue(ProfileService.isValid(profile), profile)
        }
    }

    func testProfileSlugValidationRejectsBadInput() {
        let invalid = [
            "",
            "Dummy",
            "dummy profile",
            "dummy/profile",
            "../dummy",
            "-dummy",
            ".dummy",
            "_dummy",
            "dummy$",
            "dummy\nprofile",
            "dummy:profile",
        ]

        for profile in invalid {
            XCTAssertFalse(ProfileService.isValid(profile), profile)
        }
    }

    func testWorkspaceURLResolvesValidSlugUnderWorkspaceRoot() throws {
        let root = try temporaryWorkspaceRoot()

        try withTemporaryWorkspaceRoot(root) {
            let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: "dummy.profile-1"))
            let expected = root.appendingPathComponent("dummy.profile-1", isDirectory: true)

            XCTAssertEqual(workspace, expected)
        }
    }

    func testWorkspaceURLReturnsNilForInvalidSlug() throws {
        let root = try temporaryWorkspaceRoot()

        try withTemporaryWorkspaceRoot(root) {
            XCTAssertNil(ProfileService.workspaceURL(for: "../dummy"))
            XCTAssertNil(ProfileService.workspaceURL(for: "Dummy"))
            XCTAssertNil(ProfileService.workspaceURL(for: "dummy/profile"))
        }
    }

    private func temporaryWorkspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func withTemporaryWorkspaceRoot<T>(_ root: URL, body: () throws -> T) throws -> T {
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        return try body()
    }
}
