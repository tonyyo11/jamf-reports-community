import Foundation
import XCTest
@testable import JamfReports

/// #207 M2: the tick reads these files while it holds the lock, from a folder another Mac can
/// write. Each reader now refuses a link, an oversize file and anything not a regular file
/// (checked on the open descriptor, not left to Foundation), reading it as no record.
final class StateFileBoundedReadTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("StateFileBoundedRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func plantFIFO(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0, "mkfifo \(url.path)")
    }

    private func plantLink(at url: URL, text: String) throws {
        let target = root.appendingPathComponent("target-\(UUID().uuidString)")
        try Data(text.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    // MARK: - BoundedFile

    func testStateTextReadsARegularFile() throws {
        let url = root.appendingPathComponent("plain")
        try Data("2026-10-16\n".utf8).write(to: url)
        XCTAssertEqual(BoundedFile.stateText(url), "2026-10-16\n")
    }

    func testStateTextRefusesAFIFOALinkAndAnOversizeFile() throws {
        let fifo = root.appendingPathComponent("fifo")
        try plantFIFO(at: fifo)
        XCTAssertNil(BoundedFile.stateText(fifo))

        let link = root.appendingPathComponent("link")
        try plantLink(at: link, text: "2026-10-16")
        XCTAssertNil(BoundedFile.stateText(link))

        let big = root.appendingPathComponent("big")
        try Data(repeating: 0x41, count: BoundedFile.stateFileLimit + 1).write(to: big)
        XCTAssertNil(BoundedFile.stateText(big))
    }

    // MARK: - Readers the tick runs under the lock

    func testDayMarkerReadsAFIFOAsUnstamped() throws {
        let marker = DayMarker(name: "overdue-notify")
        try plantFIFO(at: root.appendingPathComponent("automation/.overdue-notify-last"))
        XCTAssertNil(marker.lastStampedDay(in: root))
    }

    /// A planted link would otherwise stamp the day for this Mac and hold its send back.
    func testDayMarkerDoesNotFollowALink() throws {
        let marker = DayMarker(name: "overdue-notify")
        let url = root.appendingPathComponent("automation/.overdue-notify-last")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plantLink(at: url, text: "2026-10-16")
        XCTAssertNil(marker.lastStampedDay(in: root))
    }

    func testStateFileStoreReadsAFIFOOrLinkAsNoRecord() throws {
        let store = StateFileStore(directory: root)
        try plantFIFO(at: root.appendingPathComponent("computers.last"))
        try plantFIFO(at: root.appendingPathComponent("computers.fail"))
        try plantLink(at: root.appendingPathComponent("computers.cause.json"),
                      text: #"{"kind": "other"}"#)
        XCTAssertNil(store.lastRun(report: "computers"))
        XCTAssertNil(store.lastFailureExitCode(for: "computers"))
        XCTAssertNil(store.cause(for: "computers"))
    }

    func testStateFileStoreRefusesALinkedOrOversizeRecord() throws {
        let store = StateFileStore(directory: root)
        let stamp = ISO8601DateFormatter().string(from: Date())
        try plantLink(at: root.appendingPathComponent("computers.last"), text: stamp)
        XCTAssertNil(store.lastRun(report: "computers"), "a link is not this Mac's record")

        let padded = stamp + String(repeating: " ", count: BoundedFile.stateFileLimit)
        try Data(padded.utf8).write(to: root.appendingPathComponent("policies.last"))
        XCTAssertNil(store.lastRun(report: "policies"), "past the cap nothing is read")
    }

    func testStateFileStoreStillReadsItsOwnFiles() throws {
        let store = StateFileStore(directory: root)
        try store.recordRun(report: "computers", at: Date())
        XCTAssertNotNil(store.lastRun(report: "computers"))
    }
}
