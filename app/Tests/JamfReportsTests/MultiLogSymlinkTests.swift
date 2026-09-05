import Foundation
import XCTest
@testable import JamfReports

/// A managed (multi) agent's log paths are read back out of a plist during the
/// one-time legacy import, and a plist is an ordinary user-writable file. The
/// reader confines those paths to `~/Library/Logs/JamfReports/<label>/` and
/// resolves symlinks BEFORE the prefix check, so a plist cannot point the
/// parser at an arbitrary file. Coverage restored after the writer-side test
/// that used to pin this was deleted with the writer's dead path helpers.
final class MultiLogSymlinkTests: XCTestCase {

    private let prefix = LaunchAgentWriter.labelPrefix

    private func writePlist(label: String, stdout: URL, into dir: URL) throws -> URL {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/true", "--scheduled-run", "--all-profiles"],
            "StartCalendarInterval": [["Hour": 6, "Minute": 20]],
            "StandardOutPath": stdout.path,
        ]
        let url = dir.appendingPathComponent("\(label).plist")
        try PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url)
        return url
    }

    func testSymlinkedMultiLogIsRefusedWhileARealLogIsRead() throws {
        let fm = FileManager.default
        let label = "\(prefix).multi.\(UUID().uuidString.lowercased())"
        let logDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/JamfReports/\(label)", isDirectory: true)
        try fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: logDir) }
        let logURL = logDir.appendingPathComponent("stdout.log")

        let scratch = fm.temporaryDirectory
            .appendingPathComponent("multi-log-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }

        // A real file inside the confined dir IS read: its mtime becomes the
        // schedule's "last" stamp. This is the control that proves the negative
        // below is the symlink check, not an unrelated nil.
        try "[ok] done\n".write(to: logURL, atomically: true, encoding: .utf8)
        let honest = try XCTUnwrap(
            LaunchAgentService.parse(writePlist(label: label, stdout: logURL, into: scratch)))
        XCTAssertNotEqual(honest.last, "—", "a real log inside the log dir must be read")

        // Same path, now a symlink pointing outside. Resolution happens before
        // the prefix check, so the file is refused and no date is taken from it.
        try fm.removeItem(at: logURL)
        let outside = scratch.appendingPathComponent("outside.log")
        try "[fail] exit 1\n".write(to: outside, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: logURL, withDestinationURL: outside)
        let refused = try XCTUnwrap(
            LaunchAgentService.parse(writePlist(label: label, stdout: logURL, into: scratch)))
        XCTAssertEqual(refused.last, "—", "a symlinked log must not be read through")
    }
}
