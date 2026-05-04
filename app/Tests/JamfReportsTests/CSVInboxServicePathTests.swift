import Foundation
import XCTest
@testable import JamfReports

final class CSVInboxServicePathTests: XCTestCase {
    private let fileManager = FileManager.default

    func testListHandlesDeeperNestingGracefully() throws {
        let (profile, root) = try makeWorkspace()
        let inbox = root.appendingPathComponent("csv-inbox", isDirectory: true)
        let deepDir = inbox.appendingPathComponent("nested/deep", isDirectory: true)
        try fileManager.createDirectory(at: deepDir, withIntermediateDirectories: true)
        try writeCSV(to: deepDir.appendingPathComponent("nested.csv"))

        let files = CSVInboxService().list(profile: profile)

        // Currently, list() only looks at top-level and "archive/"
        // Verify it doesn't crash and returns only what's supported
        XCTAssertTrue(files.isEmpty, "Should not find deeply nested files currently")
    }

    func testClearRejectsInvalidRelativePaths() throws {
        let (profile, _) = try makeWorkspace()
        let file = InboxFile(
            name: "test.csv",
            relativePath: "../secret.txt",
            size: "1 KB",
            mtime: Date(),
            status: .pending
        )

        XCTAssertThrowsError(try CSVInboxService().clear(file, profile: profile)) { error in
            XCTAssertEqual(error as? CSVInboxService.ClearError, .invalidPath)
        }
    }

    func testClearRejectsNonCSVExtensions() throws {
        let (profile, _) = try makeWorkspace()
        let file = InboxFile(
            name: "test.txt",
            relativePath: "test.txt",
            size: "1 KB",
            mtime: Date(),
            status: .pending
        )

        XCTAssertThrowsError(try CSVInboxService().clear(file, profile: profile)) { error in
            XCTAssertEqual(error as? CSVInboxService.ClearError, .invalidPath)
        }
    }

    private func makeWorkspace() throws -> (String, URL) {
        let profile = "path-test-\(UUID().uuidString.lowercased())"
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaceRoot.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: workspaceRoot)
        }

        let root = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return (profile, root)
    }

    private func writeCSV(to url: URL) throws {
        try "name,serial\nMac,ABC123\n".write(to: url, atomically: true, encoding: .utf8)
    }
}
