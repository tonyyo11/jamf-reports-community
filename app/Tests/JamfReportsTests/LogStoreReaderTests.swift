import XCTest
import OSLog
@testable import JamfReports

final class LogStoreReaderTests: XCTestCase {
    func test_recent_retrievesAndFiltersBySubsystem() throws {
        let marker = "JRC.LogStoreReaderTests.\(UUID().uuidString)"
        AppLogger.collect.notice("reader-test marker=\(marker, privacy: .public)")
        let since = Date().addingTimeInterval(-5)
        let entries: [LogEntry]
        do { entries = try LogStoreReader.recent(minLevel: .notice, since: since, limit: 2000) }
        catch { throw XCTSkip("OSLogStore unavailable in this host: \(error.localizedDescription)") }
        XCTAssertTrue(entries.contains { $0.message.contains(marker) },
                      "expected the emitted marker among \(entries.count) entries")
    }

    func test_recent_respectsLimit() {
        let since = Date().addingTimeInterval(-60)
        let entries = (try? LogStoreReader.recent(minLevel: .debug, since: since, limit: 3)) ?? []
        XCTAssertLessThanOrEqual(entries.count, 3)
    }

    func test_levelIsComparable_forMinLevelFiltering() {
        XCTAssertTrue(LogEntry.Level.debug < LogEntry.Level.error)
        XCTAssertTrue(LogEntry.Level.notice < LogEntry.Level.fault)
        XCTAssertFalse(LogEntry.Level.error < LogEntry.Level.info)
    }
}
