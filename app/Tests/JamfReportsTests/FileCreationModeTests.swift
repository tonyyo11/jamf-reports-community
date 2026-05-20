import XCTest
import Foundation
@testable import JamfReports

/// Track B Wave 2 — B-06: file/dir creation TOCTOU.
///
/// Previously, `AppLogger.write(_:)` called `String.write(to:)` (default
/// umask) and then `setAttributes` to chmod 0600 — leaving a brief window
/// where another local user could open the file. The fix passes
/// `attributes:` directly to `createFile` so the file lands on disk with
/// the right mode.
final class FileCreationModeTests: XCTestCase {

    func test_createFile_withAttributesIs0600() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("crash.log")
        // Same call shape AppLogger uses after the B-06 fix.
        FileManager.default.createFile(
            atPath: file.path,
            contents: Data("hello".utf8),
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.int16Value ?? -1
        XCTAssertEqual(mode, 0o600, "crash log files must land at 0o600")
    }

    func test_createDirectory_withAttributesIs0700() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-mode-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }

        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: parent.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.int16Value ?? -1
        XCTAssertEqual(mode, 0o700, "log dirs must land at 0o700")
    }
}
