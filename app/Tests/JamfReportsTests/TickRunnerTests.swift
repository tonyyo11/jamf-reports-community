import XCTest
@testable import JamfReports

/// Run-now markers: listing them leaves them queued, and only the tick's per-run
/// clear removes one, so a tick killed mid-run never loses the requests behind it.
final class TickRunnerTests: XCTestCase {

    private let alpha = "com.github.tonyyo11.jamf-reports-community.alpha.collect"
    private let beta = "com.github.tonyyo11.jamf-reports-community.beta.backup"

    private func markerDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-now-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func markerExists(_ name: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    func testPendingLabelsLeaveTheMarkersInPlace() throws {
        let dir = markerDir()
        try TickRunner.requestRunNow(label: alpha, dir: dir)
        try TickRunner.requestRunNow(label: beta, dir: dir)

        XCTAssertEqual(TickRunner.pendingRunNowLabels(dir: dir), [alpha, beta])
        XCTAssertTrue(markerExists(alpha, in: dir))
        XCTAssertTrue(markerExists(beta, in: dir))
        XCTAssertEqual(TickRunner.pendingRunNowLabels(dir: dir), [alpha, beta],
                       "listing must not consume a request")
    }

    func testClearingRemovesOnlyTheNamedMarker() throws {
        let dir = markerDir()
        try TickRunner.requestRunNow(label: alpha, dir: dir)
        try TickRunner.requestRunNow(label: beta, dir: dir)

        TickRunner.clearRunNowMarker(label: alpha, dir: dir)

        XCTAssertFalse(markerExists(alpha, in: dir))
        XCTAssertTrue(markerExists(beta, in: dir))
        XCTAssertEqual(TickRunner.pendingRunNowLabels(dir: dir), [beta])
    }

    func testInvalidMarkerNamesAreRemovedAndIgnored() throws {
        let dir = markerDir()
        try TickRunner.requestRunNow(label: alpha, dir: dir)
        try Data().write(to: dir.appendingPathComponent("not-a-label"))
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))

        XCTAssertEqual(TickRunner.pendingRunNowLabels(dir: dir), [alpha])
        XCTAssertFalse(markerExists("not-a-label", in: dir))
        XCTAssertFalse(markerExists(".DS_Store", in: dir))
        XCTAssertTrue(markerExists(alpha, in: dir), "a valid marker stays queued")
    }

    func testAMissingMarkerDirectoryQueuesNothing() {
        let dir = markerDir()  // never created
        XCTAssertTrue(TickRunner.pendingRunNowLabels(dir: dir).isEmpty)
        TickRunner.clearRunNowMarker(label: alpha, dir: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
