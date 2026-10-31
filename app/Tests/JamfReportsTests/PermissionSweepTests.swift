import XCTest
@testable import JamfReports

final class PermissionSweepTests: XCTestCase {
    /// A sweep from a nonisolated test: the hardener no longer needs the main actor.
    func testSweepLeavesARightModeAloneAndFixesAWrongOne() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let right = root.appendingPathComponent("right.json")
        let wrong = root.appendingPathComponent("wrong.json")
        for url in [right, wrong] { try Data("{}".utf8).write(to: url) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: right.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: wrong.path)
        let before = try status(of: right)

        let result = WorkspacePermissionHardener.tighten(directory: root)

        XCTAssertEqual(result.touched, 2)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(try status(of: wrong).st_mode & 0o777, 0o600)
        // chmod updates ctime even when the mode does not change, so an equal ctime means no chmod.
        let after = try status(of: right)
        XCTAssertEqual(after.st_ctimespec.tv_sec, before.st_ctimespec.tv_sec)
        XCTAssertEqual(after.st_ctimespec.tv_nsec, before.st_ctimespec.tv_nsec)
    }

    private func status(of url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return info
    }
}
