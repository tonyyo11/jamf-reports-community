import Foundation
import XCTest
@testable import JamfReports

final class DirectoryWatcherTests: XCTestCase {
    private let fileManager = FileManager.default

    @MainActor
    func testWatcherResponsivenessAndCleanup() async throws {
        let profile = "watcher-test-\(UUID().uuidString.lowercased())"
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaceRoot.path, 1)
        defer {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? fileManager.removeItem(at: workspaceRoot)
        }

        let root = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        let inbox = root.appendingPathComponent("csv-inbox", isDirectory: true)
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)

        let watcher = CSVInboxService.DirectoryWatcher()
        let expectation = expectation(description: "Change detected")
        expectation.assertForOverFulfill = false

        watcher.start(profile: profile) {
            expectation.fulfill()
        }

        // Trigger a change
        try "test".write(to: inbox.appendingPathComponent("trigger.csv"), atomically: true, encoding: .utf8)

        await fulfillment(of: [expectation], timeout: 5.0)
        watcher.stop()
    }

    @MainActor
    func testRapidProfileSwitchDoesNotCrash() async throws {
        let watcher = CSVInboxService.DirectoryWatcher()
        
        for i in 0..<10 {
            let profile = "switch-\(i)"
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
            
            let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
            try fileManager.createDirectory(at: workspace.appendingPathComponent("csv-inbox"), withIntermediateDirectories: true)
            
            watcher.start(profile: profile) { }
            
            if i % 2 == 0 {
                watcher.stop()
            }
        }
        watcher.stop()
    }
}
