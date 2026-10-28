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
        try? FileManager.default.removeItem(at: dataDir)
    }

    private static let old = #"""
        [{"id":"7","security":{"lostModeEnabled":true,"lostModePhoneNumber":"555-0100",
          "lostModeMessage":"Call the help desk"},
          "extra":{"nested":[{"lostModeLocation":"Building 4","lostModeFootnote":"Reward"}]}}]
        """#
    private static let clean = #"[{"id":"7","security":{"lostModeEnabled":false}}]"#

    private func write(_ text: String, _ name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func rewrite(_ lines: Lines = Lines()) -> Lines {
        ReportEngine.rewriteLostModeTextOnce(dataDir: dataDir, now: fixedNow, onLine: lines.add)
        return lines
    }

    private var markerExists: Bool {
        FileManager.default.fileExists(atPath: dataDir
            .appendingPathComponent("state/\(ReportEngine.lostModeRewriteMarker)").path)
    }

    func testKeysAtTwoDepthsAreRemovedAndTheRestKept() throws {
        let file = try write(Self.old, "\(kind)_20260101T000000.json")
        let lines = rewrite()

        let data = try Data(contentsOf: file)
        XCTAssertEqual(data, ReportEngine.droppingLostModeText(Data(Self.old.utf8)))
        let text = String(decoding: data, as: UTF8.self)
        for key in ReportEngine.lostModeTextKeys { XCTAssertFalse(text.contains(key), key) }
        let record = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first)
        XCTAssertEqual((record["security"] as? [String: Any])?["lostModeEnabled"] as? Bool, true)
        XCTAssertEqual(record["id"] as? String, "7")
        XCTAssertNotNil(record["extra"])
        XCTAssertEqual(lines.all, ["[info] removed lost-mode text from 1 mobile device snapshots"])
        XCTAssertTrue(markerExists)
    }

    func testSnapshotWithoutTheKeysIsByteIdenticalAndNothingIsLogged() throws {
        let file = try write(Self.clean, "\(kind)_20260101T000000.json")
        let lines = rewrite()
        XCTAssertEqual(try Data(contentsOf: file), Data(Self.clean.utf8))
        XCTAssertEqual(lines.all, [])
        XCTAssertTrue(markerExists)
    }

    func testUnparsableFileIsLeftAndNamedInOneWarning() throws {
        let junk = "{\"lostModeMessage\": \"secret"
        let bad = try write(junk, "\(kind)_20260102T000000.json")
        let good = try write(Self.old, "\(kind)_20260101T000000.json")
        let lines = rewrite()

        XCTAssertEqual(try Data(contentsOf: bad), Data(junk.utf8))
        XCTAssertFalse(String(decoding: try Data(contentsOf: good), as: UTF8.self)
            .contains("lostModePhoneNumber"))
        let warns = lines.all.filter { $0.hasPrefix("[warn]") }
        XCTAssertEqual(warns.count, 1)
        XCTAssertTrue(warns[0].contains(bad.lastPathComponent))
        XCTAssertFalse(warns[0].contains("secret"))
        XCTAssertFalse(warns[0].contains("[partial]"))
    }

    func testMarkerStopsASecondPass() throws {
        _ = rewrite()
        let file = try write(Self.old, "\(kind)_20260101T000000.json")
        let lines = rewrite()
        XCTAssertEqual(try Data(contentsOf: file), Data(Self.old.utf8))
        XCTAssertEqual(lines.all, [])
    }

    func testListedManifestEntryIsRefreshedAndUnlistedOnesAreNotAdded() throws {
        let listed = try write(Self.old, "\(kind)_20260101T000000.json")
        let unlisted = try write(Self.old, "\(kind)_20260102T000000.json")
        try SnapshotManifest.record(snapshotFile: listed, data: Data(Self.old.utf8))
        XCTAssertEqual(SnapshotManifest.verify(snapshot: listed, data: Data(Self.old.utf8)), .verified)

        _ = rewrite()

        let listedData = try Data(contentsOf: listed)
        XCTAssertEqual(SnapshotManifest.verify(snapshot: listed, data: listedData), .verified)
        XCTAssertEqual(
            SnapshotManifest.verify(snapshot: unlisted, data: try Data(contentsOf: unlisted)),
            .omitted)
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
}
