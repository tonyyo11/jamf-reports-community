import Foundation
import XCTest
@testable import JamfReports

final class CSVInboxServiceTests: XCTestCase {
    private let fileManager = FileManager.default

    func testListReturnsEmptyWhenInboxDirectoryDoesNotExist() throws {
        let (profile, _) = try makeWorkspace()

        let files = CSVInboxService().list(profile: profile)

        XCTAssertTrue(files.isEmpty)
    }

    func testListReadsInboxAndArchiveFiles() throws {
        let (profile, root) = try makeWorkspace()
        let inbox = root.appendingPathComponent("csv-inbox", isDirectory: true)
        let archive = inbox.appendingPathComponent("archive", isDirectory: true)
        try fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
        try writeCSV(to: inbox.appendingPathComponent("incoming.csv"))
        try writeCSV(to: archive.appendingPathComponent("old.csv"))

        let files = CSVInboxService().list(profile: profile)

        let rows = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0.status) })
        XCTAssertEqual(rows["incoming.csv"], .pending)
        XCTAssertEqual(rows["archive/old.csv"], .archived)
    }

    func testClearRemovesInboxFileAndConsumedSentinel() throws {
        let (profile, root) = try makeWorkspace()
        let inbox = root.appendingPathComponent("csv-inbox", isDirectory: true)
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        let csv = inbox.appendingPathComponent("incoming.csv")
        let sentinel = csv.appendingPathExtension("consumed")
        try writeCSV(to: csv)
        try "".write(to: sentinel, atomically: true, encoding: .utf8)
        let file = try XCTUnwrap(CSVInboxService().list(profile: profile).first)

        try CSVInboxService().clear(file, profile: profile)

        XCTAssertFalse(fileManager.fileExists(atPath: csv.path))
        XCTAssertFalse(fileManager.fileExists(atPath: sentinel.path))
        XCTAssertTrue(CSVInboxService().list(profile: profile).isEmpty)
    }

    private func makeWorkspace() throws -> (String, URL) {
        let profile = "csvinbox-\(UUID().uuidString.lowercased())"
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
