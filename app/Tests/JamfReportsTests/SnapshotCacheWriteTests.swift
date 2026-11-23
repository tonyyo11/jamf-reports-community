import Foundation
import XCTest
@testable import JamfReports

/// A symlink planted at a fixed cache name must be replaced, never written through.
final class SnapshotCacheWriteTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func plantSymlink(at link: URL, target: URL) throws {
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    }

    func testPatchReleaseDatesWriteReplacesAPlantedSymlink() throws {
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let dir = dataDir.appendingPathComponent("patch-release-dates", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let victim = root.appendingPathComponent("victim.txt")
        let link = dir.appendingPathComponent("patch-release-dates_20261011T010203.json")
        try plantSymlink(at: link, target: victim)

        let written = try ReportEngine.writePatchReleaseDates(
            [["title_id": "1", "title": "Firefox"]], stamp: "20261011T010203", dataDir: dataDir)

        XCTAssertEqual(written.lastPathComponent, link.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "untouched")
        let values = try link.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, false)
        XCTAssertTrue(try String(contentsOf: link, encoding: .utf8).contains("Firefox"))
    }

    /// The staging name is unique per write, so a link left at the old fixed `.partial` name is
    /// never touched and nothing is written through it.
    func testSOFACacheWriteIgnoresALinkAtTheOldStagingName() throws {
        let cache = root.appendingPathComponent("macos.json")
        let victim = root.appendingPathComponent("victim.txt")
        try plantSymlink(at: root.appendingPathComponent(".macos.json.partial"), target: victim)

        SOFAFeedService.writeCacheAtomic(data: Data("{}".utf8), to: cache)

        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "untouched")
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), "{}")
    }
}
