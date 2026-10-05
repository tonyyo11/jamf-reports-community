import XCTest
@testable import JamfReports

/// Pins `CLIBridge.snapshotFileName`: the app's own audit snapshot carries the local-time
/// stamp the snapshot readers parse, so it is never read as hours in the future.
final class CLIBridgeSnapshotNameTests: XCTestCase {

    func testTheStampReadsBackAsTheMomentItWasWritten() throws {
        // CI runs in UTC, where a UTC stamp would also pass; pin a zone that is not.
        let saved = NSTimeZone.default
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        defer { NSTimeZone.default = saved }

        let written = Date(timeIntervalSince1970: 1_791_213_138)  // 2026-10-05 15:12:18 UTC
        let name = CLIBridge.snapshotFileName(type: "audit", at: written)
        XCTAssertEqual(name, "audit_20261005T111218.json")

        let stem = (name as NSString).deletingPathExtension
        let read = try XCTUnwrap(CloudStorage.snapshotTimestamp(stem: stem))
        XCTAssertEqual(read.timeIntervalSince1970, written.timeIntervalSince1970, accuracy: 1)
    }
}
