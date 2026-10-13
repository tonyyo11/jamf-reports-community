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

    func testMarkConsumedWritesEmptySentinelAndLeavesCSV() throws {
        let (profile, root) = try makeWorkspace()
        let csv = try makeInboxCSV(named: "incoming.csv", in: root)

        XCTAssertTrue(try CSVInboxService.markConsumed(csv, profile: profile))

        let sentinel = csv.appendingPathExtension("consumed")
        XCTAssertEqual(try Data(contentsOf: sentinel).count, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: csv.path))
        XCTAssertEqual(CSVInboxService().list(profile: profile).first?.status, .consumed)
        // A second run over the same CSV is not an error.
        XCTAssertTrue(try CSVInboxService.markConsumed(csv, profile: profile))
    }

    func testMarkConsumedDoesNotWriteThroughSymlinkAtSentinelName() throws {
        let (profile, root) = try makeWorkspace()
        let csv = try makeInboxCSV(named: "incoming.csv", in: root)
        let victim = root.appendingPathComponent("victim.txt")
        try fileManager.createSymbolicLink(
            at: csv.appendingPathExtension("consumed"), withDestinationURL: victim)

        XCTAssertThrowsError(try CSVInboxService.markConsumed(csv, profile: profile))

        XCTAssertFalse(fileManager.fileExists(atPath: victim.path))
    }

    func testMarkConsumedIgnoresCSVOutsideInbox() throws {
        let (profile, root) = try makeWorkspace()
        let csv = root.appendingPathComponent("loose.csv")
        try writeCSV(to: csv)

        XCTAssertFalse(try CSVInboxService.markConsumed(csv, profile: profile))

        XCTAssertFalse(fileManager.fileExists(
            atPath: csv.appendingPathExtension("consumed").path))
    }

    func testNewestCSVIgnoresConsumedSentinelAndArchiveFolder() throws {
        let (profile, root) = try makeWorkspace()
        let older = try makeInboxCSV(named: "older.csv", in: root)
        try markModified(older, secondsAgo: 300)
        let archive = older.deletingLastPathComponent()
            .appendingPathComponent("archive", isDirectory: true)
        try fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
        try writeCSV(to: archive.appendingPathComponent("archived.csv"))
        try CSVInboxService.markConsumed(older, profile: profile)

        let picked = CLIBridge.newestCSV(in: profile)

        XCTAssertEqual(picked?.lastPathComponent, "older.csv")
    }

    func testArchiveMovesCSVAndSentinelIntoArchiveFolder() throws {
        let (profile, root) = try makeWorkspace()
        let csv = try makeInboxCSV(named: "incoming.csv", in: root)
        try CSVInboxService.markConsumed(csv, profile: profile)
        let file = try XCTUnwrap(CSVInboxService().list(profile: profile).first)

        try CSVInboxService().archive(file, profile: profile)

        let archive = csv.deletingLastPathComponent()
            .appendingPathComponent("archive", isDirectory: true)
        XCTAssertFalse(fileManager.fileExists(atPath: csv.path))
        XCTAssertFalse(fileManager.fileExists(atPath: csv.appendingPathExtension("consumed").path))
        XCTAssertTrue(fileManager.fileExists(
            atPath: archive.appendingPathComponent("incoming.csv").path))
        XCTAssertTrue(fileManager.fileExists(
            atPath: archive.appendingPathComponent("incoming.csv.consumed").path))
        let rows = CSVInboxService().list(profile: profile)
        XCTAssertEqual(rows.map(\.relativePath), ["archive/incoming.csv"])
        XCTAssertEqual(rows.first?.status, .archived)
    }

    func testArchiveRefusesToOverwriteAndRefusesArchivedFile() throws {
        let (profile, root) = try makeWorkspace()
        let csv = try makeInboxCSV(named: "incoming.csv", in: root)
        let archive = csv.deletingLastPathComponent()
            .appendingPathComponent("archive", isDirectory: true)
        try fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
        try writeCSV(to: archive.appendingPathComponent("incoming.csv"))
        let files = CSVInboxService().list(profile: profile)
        let pending = try XCTUnwrap(files.first { $0.status == .pending })
        let archived = try XCTUnwrap(files.first { $0.status == .archived })

        XCTAssertThrowsError(try CSVInboxService().archive(pending, profile: profile)) {
            XCTAssertEqual($0 as? CSVInboxService.ClearError, .archiveNameTaken("incoming.csv"))
        }
        XCTAssertThrowsError(try CSVInboxService().archive(archived, profile: profile)) {
            XCTAssertEqual($0 as? CSVInboxService.ClearError, .alreadyArchived("incoming.csv"))
        }
        XCTAssertTrue(fileManager.fileExists(atPath: csv.path))
    }

    private func makeInboxCSV(named name: String, in root: URL) throws -> URL {
        let inbox = root.appendingPathComponent("csv-inbox", isDirectory: true)
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        let csv = inbox.appendingPathComponent(name)
        try writeCSV(to: csv)
        return csv
    }

    private func markModified(_ url: URL, secondsAgo: TimeInterval) throws {
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -secondsAgo)], ofItemAtPath: url.path)
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
