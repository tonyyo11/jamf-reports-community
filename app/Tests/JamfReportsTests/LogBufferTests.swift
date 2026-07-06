import XCTest
@testable import JamfReports

final class LogBufferTests: XCTestCase {

    private func entry(_ t: TimeInterval, _ level: LogEntry.Level, _ msg: String) -> LogEntry {
        LogEntry(date: Date(timeIntervalSince1970: t), category: "collect", level: level, message: msg)
    }

    func test_snapshot_isNewestFirst() {
        let buffer = LogBuffer(capacity: 10)
        buffer.append(entry(1, .info, "a"))
        buffer.append(entry(2, .error, "b"))
        XCTAssertEqual(buffer.snapshot().map(\.message), ["b", "a"])
    }

    func test_capacity_dropsOldest() {
        let buffer = LogBuffer(capacity: 2)
        for i in 1...5 { buffer.append(entry(TimeInterval(i), .info, "\(i)")) }
        XCTAssertEqual(buffer.snapshot().map(\.message), ["5", "4"])
    }

    func test_minLevel_filtersBelowThreshold() {
        let buffer = LogBuffer(capacity: 10)
        buffer.append(entry(1, .debug, "d"))
        buffer.append(entry(2, .error, "e"))
        XCTAssertEqual(buffer.snapshot(minLevel: .error).map(\.message), ["e"])
    }

    func test_since_filtersOlderEntries() {
        let buffer = LogBuffer(capacity: 10)
        buffer.append(entry(100, .info, "old"))
        buffer.append(entry(200, .info, "new"))
        XCTAssertEqual(buffer.snapshot(since: Date(timeIntervalSince1970: 150)).map(\.message), ["new"])
    }

    func test_limit_capsToNewest() {
        let buffer = LogBuffer(capacity: 100)
        for i in 1...10 { buffer.append(entry(TimeInterval(i), .info, "\(i)")) }
        XCTAssertEqual(buffer.snapshot(limit: 3).map(\.message), ["10", "9", "8"])
    }

    func test_clear_emptiesBuffer() {
        let buffer = LogBuffer(capacity: 10)
        buffer.append(entry(1, .info, "a"))
        buffer.clear()
        XCTAssertTrue(buffer.snapshot().isEmpty)
    }

    func test_levelIsComparable() {
        XCTAssertTrue(LogEntry.Level.debug < .error)
        XCTAssertTrue(LogEntry.Level.notice < .fault)
        XCTAssertFalse(LogEntry.Level.error < .info)
    }
}
