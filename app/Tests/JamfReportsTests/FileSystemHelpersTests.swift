import XCTest
@testable import JamfReports

final class FileSystemHelpersTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        tempDir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testNonexistentDirectory() {
        let missing = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertNil(FileManager.newestJSONFile(in: missing))
    }

    func testEmptyDirectory() {
        XCTAssertNil(FileManager.newestJSONFile(in: tempDir))
    }

    func testReturnsNewestJSON() throws {
        let older = tempDir.appendingPathComponent("older.json")
        let newer = tempDir.appendingPathComponent("newer.json")
        try "{}".write(to: older, atomically: true, encoding: .utf8)
        // Ensure distinct mtimes by setting the older file's mtime one minute in the past.
        let pastDate = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes(
            [.modificationDate: pastDate], ofItemAtPath: older.path
        )
        try "{}".write(to: newer, atomically: true, encoding: .utf8)

        let result = FileManager.newestJSONFile(in: tempDir)
        XCTAssertEqual(result?.lastPathComponent, "newer.json")
    }

    func testIgnoresNonJSONFiles() throws {
        let txt = tempDir.appendingPathComponent("data.txt")
        let plist = tempDir.appendingPathComponent("config.plist")
        try "hello".write(to: txt, atomically: true, encoding: .utf8)
        try "hello".write(to: plist, atomically: true, encoding: .utf8)
        XCTAssertNil(FileManager.newestJSONFile(in: tempDir))
    }

    func testIgnoresHiddenFiles() throws {
        let hidden = tempDir.appendingPathComponent(".hidden.json")
        let visible = tempDir.appendingPathComponent("visible.json")
        try "{}".write(to: hidden, atomically: true, encoding: .utf8)
        try "{}".write(to: visible, atomically: true, encoding: .utf8)
        // .skipsHiddenFiles excludes the hidden one; only visible.json should be returned.
        let result = FileManager.newestJSONFile(in: tempDir)
        XCTAssertEqual(result?.lastPathComponent, "visible.json")
    }

    /// Epic #103: a symlink planted in the directory must not let readers
    /// follow it outside — even when it is the newest entry.
    func testSymlinkEscapingDirectoryIsRefused() throws {
        let outsideDir = tempDir.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outsideDir) }
        let target = outsideDir.appendingPathComponent("secret.json")
        try "{}".write(to: target, atomically: true, encoding: .utf8)

        let inside = tempDir.appendingPathComponent("real.json")
        try "{}".write(to: inside, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: inside.path
        )
        let link = tempDir.appendingPathComponent("planted.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = FileManager.newestJSONFile(in: tempDir)
        XCTAssertEqual(result?.lastPathComponent, "real.json",
                       "escaping symlink must be skipped, not followed")
    }

    /// A symlink that stays inside the directory remains usable — containment,
    /// not a blanket symlink ban.
    func testSymlinkWithinDirectoryIsAllowed() throws {
        let real = tempDir.appendingPathComponent("real.json")
        try "{}".write(to: real, atomically: true, encoding: .utf8)
        let link = tempDir.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let result = FileManager.newestJSONFile(in: tempDir)
        XCTAssertEqual(result?.lastPathComponent, "real.json",
                       "in-dir symlink resolves to its target and is kept")
    }
}
