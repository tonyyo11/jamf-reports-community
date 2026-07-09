import XCTest
@testable import JamfReports

/// Round-trip + edge tests for the persisted once-per-day marker
/// (`<workspace>/automation/.<name>-last`). Pure filesystem, no launchctl.
final class DayMarkerTests: XCTestCase {

    private func makeWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DayMarker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testStampThenReadRoundTrips() throws {
        let workspace = try makeWorkspace()
        let marker = DayMarker(name: "overdue-notify")
        marker.stamp(day: "2026-07-09", in: workspace)
        XCTAssertEqual(marker.lastStampedDay(in: workspace), "2026-07-09")
    }

    func testAbsentMarkerReadsNil() throws {
        let workspace = try makeWorkspace()
        XCTAssertNil(DayMarker(name: "overdue-notify").lastStampedDay(in: workspace))
    }

    func testStampOverwritesSameDayMarker() throws {
        let workspace = try makeWorkspace()
        let marker = DayMarker(name: "catch-up")
        marker.stamp(day: "2026-07-08", in: workspace)
        marker.stamp(day: "2026-07-09", in: workspace)
        XCTAssertEqual(marker.lastStampedDay(in: workspace), "2026-07-09")
    }

    func testDistinctNamesDoNotCollide() throws {
        let workspace = try makeWorkspace()
        DayMarker(name: "overdue-notify").stamp(day: "2026-07-01", in: workspace)
        DayMarker(name: "catch-up").stamp(day: "2026-07-02", in: workspace)
        XCTAssertEqual(
            DayMarker(name: "overdue-notify").lastStampedDay(in: workspace), "2026-07-01")
        XCTAssertEqual(
            DayMarker(name: "catch-up").lastStampedDay(in: workspace), "2026-07-02")
    }

    func testMissingWorkspaceReadsNilWithoutThrowing() {
        // A workspace path that was never created → read returns nil, no throw.
        let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DayMarker-missing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertNil(DayMarker(name: "overdue-notify").lastStampedDay(in: missing))
    }
}
