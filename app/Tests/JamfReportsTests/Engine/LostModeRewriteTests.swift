import Foundation
import XCTest
@testable import JamfReports

/// The one-time rewrite of mobile snapshots saved before 2.11
/// (`ReportEngine.rewriteLostModeTextOnce`).
final class LostModeRewriteTests: XCTestCase {
    private var dataDir: URL!
    private var folder: URL!
    private let kind = MobileFleetService.deviceKind
    private let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: CLIBridge.LogLine) {
            lock.lock(); defer { lock.unlock() }
            stored.append(line.text)
        }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lost-mode-rewrite-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        folder = dataDir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A test may leave a folder read-only.
        chmod(folder.path, 0o700)
        try? FileManager.default.removeItem(at: dataDir)
    }

    private static let old = #"""
        [{"id":"7","security":{"lostModeEnabled":true,"lostModePhoneNumber":"555-0100",
          "lostModeMessage":"Call the help desk"},
          "extra":{"nested":[{"lostModeLocation":"Building 4","lostModeFootnote":"Reward"}]}}]
        """#
    private static let clean = #"[{"id":"7","security":{"lostModeEnabled":false}}]"#
    private static var stripped: Data {
        ReportEngine.droppingLostModeText(Data(old.utf8), sortedKeys: true)!
    }

    @discardableResult
    private func write(_ text: String, _ name: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? folder).appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func rewrite(
        archive: URL? = nil, limit: Int = BoundedFile.inventoryLimit
    ) -> Lines {
        let lines = Lines()
        ReportEngine.rewriteLostModeTextOnce(
            dataDir: dataDir, archiveRoot: archive, now: fixedNow, limit: limit, onLine: lines.add)
        return lines
    }

    private var markerURL: URL {
        dataDir.appendingPathComponent("state/\(ReportEngine.lostModeRewriteMarker)")
    }
    private var markerExists: Bool { FileManager.default.fileExists(atPath: markerURL.path) }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testKeysAtTwoDepthsAreRemovedAndTheRestKept() throws {
        let file = try write(Self.old, "\(kind)_20260101T000000.json")
        let lines = rewrite()

        let data = try Data(contentsOf: file)
        XCTAssertEqual(data, Self.stripped)
        let text = String(decoding: data, as: UTF8.self)
        for key in ReportEngine.lostModeTextKeys { XCTAssertFalse(text.contains(key), key) }
        let record = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first)
        XCTAssertEqual((record["security"] as? [String: Any])?["lostModeEnabled"] as? Bool, true)
        XCTAssertEqual(record["id"] as? String, "7")
        XCTAssertNotNil(record["extra"])
        XCTAssertEqual(lines.all, ["[info] removed lost-mode text from 1 mobile device snapshots"])
        XCTAssertTrue(markerExists)
        XCTAssertEqual(try mode(markerURL), 0o600)
        XCTAssertEqual(try mode(markerURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try mode(file), 0o600)
    }

    func testSnapshotWithoutTheKeysIsByteIdenticalAndNothingIsLogged() throws {
        let file = try write(Self.clean, "\(kind)_20260101T000000.json")
        let lines = rewrite()
        XCTAssertEqual(try Data(contentsOf: file), Data(Self.clean.utf8))
        XCTAssertEqual(lines.all, [])
        XCTAssertTrue(markerExists)
    }

    func testConflictCopyIsRewrittenAndManifestJSONIsUntouched() throws {
        let copy = try write(Self.old, "\(kind)_20260101T000000 2.json")
        let manifest = try write("not a manifest", SnapshotManifest.fileName)
        let lines = rewrite()
        XCTAssertEqual(try Data(contentsOf: copy), Self.stripped)
        XCTAssertEqual(try Data(contentsOf: manifest), Data("not a manifest".utf8))
        XCTAssertTrue(lines.all.filter { $0.hasPrefix("[warn]") }.isEmpty)
    }

    func testUnparsableFileIsLeftWarnedWithoutForgeryAndStillCompletes() throws {
        let junk = "{\"lostModeMessage\": \"secret"
        let bad = try write(junk, "\(kind)_20260102T000000\n[partial] forged.json")
            .deletingLastPathComponent().appendingPathComponent(
                "\(kind)_20260102T000000\n[partial] forged.json")
        let good = try write(Self.old, "\(kind)_20260101T000000.json")
        let lines = rewrite()

        XCTAssertEqual(try Data(contentsOf: bad), Data(junk.utf8))
        XCTAssertFalse(String(decoding: try Data(contentsOf: good), as: UTF8.self)
            .contains("lostModePhoneNumber"))
        let warns = lines.all.filter { $0.hasPrefix("[warn]") }
        XCTAssertEqual(warns.count, 1)
        XCTAssertFalse(warns[0].contains("\n"))
        XCTAssertFalse(warns[0].contains("secret"))
        XCTAssertTrue(warns[0].contains("may still contain lost-mode text"))
        XCTAssertTrue(warns[0].contains("delete or replace"))
        XCTAssertTrue(markerExists, "a parse failure is final, so the pass is complete")
    }

    func testMarkerStopsASecondPass() throws {
        _ = rewrite()
        let file = try write(Self.old, "\(kind)_20260101T000000.json")
        let lines = rewrite()
        XCTAssertEqual(try Data(contentsOf: file), Data(Self.old.utf8))
        XCTAssertEqual(lines.all, [])
    }

    func testVerifiedManifestEntryIsRestampedAndUnlistedOnesAreNotAdded() throws {
        let listed = try write(Self.old, "\(kind)_20260101T000000.json")
        let unlisted = try write(Self.old, "\(kind)_20260102T000000.json")
        try SnapshotManifest.record(snapshotFile: listed, data: Data(Self.old.utf8))

        _ = rewrite()

        XCTAssertEqual(
            SnapshotManifest.verify(snapshot: listed, data: try Data(contentsOf: listed)),
            .verified)
        XCTAssertEqual(
            SnapshotManifest.verify(snapshot: unlisted, data: try Data(contentsOf: unlisted)),
            .omitted)
    }

    func testMismatchedManifestEntryStaysMismatchedAfterTheStrip() throws {
        let file = try write(Self.old, "\(kind)_20260101T000000.json")
        try SnapshotManifest.record(snapshotFile: file, data: Data("something else".utf8))

        _ = rewrite()

        XCTAssertEqual(try Data(contentsOf: file), Self.stripped)
        XCTAssertEqual(
            SnapshotManifest.verify(snapshot: file, data: try Data(contentsOf: file)), .mismatch)
    }

    /// A crash after the manifest was stamped but before the file was written: the entry names
    /// the stripped bytes, the file is still the original. The next pass finishes the write.
    func testCrashBetweenStampAndWriteIsRepairedOnTheNextPass() throws {
        let file = try write(Self.old, "\(kind)_20260101T000000.json")
        try SnapshotManifest.record(snapshotFile: file, data: Self.stripped)

        _ = rewrite()

        XCTAssertEqual(try Data(contentsOf: file), Self.stripped)
        XCTAssertEqual(
            SnapshotManifest.verify(snapshot: file, data: try Data(contentsOf: file)), .verified)
    }

    func testWriteFailureWarnsOnceKeepsTheFileAndLeavesNoMarker() throws {
        let file = try write(Self.old, "\(kind)_20260101T000000.json")
        chmod(folder.path, 0o500)
        let lines = rewrite()
        chmod(folder.path, 0o700)

        XCTAssertEqual(try Data(contentsOf: file), Data(Self.old.utf8))
        let warns = lines.all.filter { $0.hasPrefix("[warn]") }
        XCTAssertEqual(warns.count, 1)
        XCTAssertTrue(warns[0].contains("could not be rewritten"))
        XCTAssertTrue(warns[0].contains(file.lastPathComponent))
        XCTAssertFalse(lines.all.contains { $0.hasPrefix("[info]") })
        XCTAssertFalse(markerExists)

        _ = rewrite()
        XCTAssertEqual(try Data(contentsOf: file), Self.stripped)
        XCTAssertTrue(markerExists)
    }

    func testTooLargeFileIsWarnedLeftAndLeavesNoMarker() throws {
        let file = try write(Self.old, "\(kind)_20260101T000000.json")
        let lines = rewrite(limit: 10)
        XCTAssertEqual(try Data(contentsOf: file), Data(Self.old.utf8))
        XCTAssertEqual(lines.all.filter { $0.contains("could not be read") }.count, 1)
        XCTAssertFalse(markerExists)
    }

    func testSymlinkedKindFolderIsRefusedAndLeavesNoMarker() throws {
        let elsewhere = dataDir.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let planted = try write(Self.old, "\(kind)_20260101T000000.json", in: elsewhere)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)

        let lines = rewrite()

        XCTAssertEqual(try Data(contentsOf: planted), Data(Self.old.utf8))
        XCTAssertEqual(lines.all.filter { $0.hasPrefix("[warn]") }.count, 1)
        XCTAssertFalse(markerExists)
    }

    func testKindFolderThatCannotBeListedLeavesNoMarker() throws {
        try FileManager.default.removeItem(at: folder)
        try Data("x".utf8).write(to: folder)
        _ = rewrite()
        XCTAssertFalse(markerExists)
    }

    func testRefusedStateFolderWarnsAndSkips() throws {
        let file = try write(Self.old, "\(kind)_20260101T000000.json")
        let elsewhere = dataDir.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: dataDir.appendingPathComponent("state"), withDestinationURL: elsewhere)
        let lines = rewrite()
        XCTAssertEqual(try Data(contentsOf: file), Data(Self.old.utf8))
        XCTAssertEqual(lines.all.filter { $0.hasPrefix("[warn] state") }.count, 1)
    }

    func testLegacyInventoryKindAndTheArchiveFoldersAreRewritten() throws {
        let legacyDir = dataDir.appendingPathComponent(
            MobileFleetService.legacyInventoryKind, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacy = try write(Self.old, "legacy_20260101T000000.json", in: legacyDir)

        let archive = dataDir.appendingPathComponent("_archive", isDirectory: true)
        let archived = archive.appendingPathComponent("jamf-cli-data/\(kind)", isDirectory: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let archivedFile = try write(Self.old, "\(kind)_20250101T000000.json", in: archived)

        let lines = rewrite(archive: archive)

        XCTAssertEqual(try Data(contentsOf: legacy), Self.stripped)
        XCTAssertEqual(try Data(contentsOf: archivedFile), Self.stripped)
        XCTAssertEqual(lines.all, ["[info] removed lost-mode text from 2 mobile device snapshots"])
        XCTAssertTrue(markerExists)
    }

    func testArchiveRootOutsideTheWorkspaceIsNotSweptAndWarns() throws {
        let lines = Lines()
        let outside = try JSONDecoder().decode(
            RetentionConfig.self, from: Data(#"{"archive_dir":"/Users/Shared/jr-archive"}"#.utf8))
        XCTAssertNil(ReportEngine.lostModeArchiveRoot(
            config: outside, workspace: dataDir, onLine: lines.add))
        XCTAssertEqual(lines.all.count, 1)
        XCTAssertTrue(lines.all[0].hasPrefix("[warn]"))

        let inside = ReportEngine.lostModeArchiveRoot(
            config: nil, workspace: dataDir, onLine: lines.add)
        XCTAssertEqual(inside?.lastPathComponent, "_archive")
        XCTAssertEqual(lines.all.count, 1)
    }
}
