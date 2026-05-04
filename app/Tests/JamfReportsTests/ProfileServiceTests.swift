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

    // MARK: - API scope tests

    func testScopeDefaultsToLimitedWhenNothingPersisted() {
        let store = makeSuiteStore()
        XCTAssertEqual(ProfileService.scope(for: "dummy", store: store), .limited)
    }

    func testSetScopeThenScopeRoundTrips() {
        let store = makeSuiteStore()
        ProfileService.setScope(.fullAdmin, for: "dummy", store: store)
        XCTAssertEqual(ProfileService.scope(for: "dummy", store: store), .fullAdmin)
    }

    func testSetScopeLimitedRoundTrips() {
        let store = makeSuiteStore()
        ProfileService.setScope(.fullAdmin, for: "dummy", store: store)
        ProfileService.setScope(.limited, for: "dummy", store: store)
        XCTAssertEqual(ProfileService.scope(for: "dummy", store: store), .limited)
    }

    func testScopeRejectsInvalidSlug() {
        let store = makeSuiteStore()
        // setScope silently no-ops; scope returns .limited for the same bad slug
        ProfileService.setScope(.fullAdmin, for: "../evil", store: store)
        XCTAssertEqual(ProfileService.scope(for: "../evil", store: store), .limited)
    }

    func testTwoProfilesHaveIndependentScopeStorage() {
        let store = makeSuiteStore()
        ProfileService.setScope(.fullAdmin, for: "tenant-a", store: store)
        ProfileService.setScope(.limited,   for: "tenant-b", store: store)
        XCTAssertEqual(ProfileService.scope(for: "tenant-a", store: store), .fullAdmin)
        XCTAssertEqual(ProfileService.scope(for: "tenant-b", store: store), .limited)
    }

    /// Returns a throwaway `UserDefaults` suite backed by a unique suiteName so
    /// tests never touch the real `.standard` suite.
    private func makeSuiteStore() -> UserDefaults {
        let suiteName = "com.jamfreports.tests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        return store
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
