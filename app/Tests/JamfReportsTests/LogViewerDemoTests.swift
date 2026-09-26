import XCTest
@testable import JamfReports

/// Settings → Logging in demo mode lists the demo org's run, never this Mac's
/// session buffer, and a live profile still reads the buffer.
@MainActor
final class LogViewerDemoTests: XCTestCase {

    private func realBuffer(now: Date) -> LogBuffer {
        let buffer = LogBuffer(capacity: 10)
        buffer.append(LogEntry(date: now, category: "collect", level: .info,
                               message: "[info] collecting computers for live-tenant"))
        return buffer
    }

    func testDemoModeListsTheDemoRunInsteadOfTheBuffer() {
        let now = Date()
        let events = LogViewerView.events(
            demoMode: true, minLevel: .info, windowHours: 4,
            buffer: realBuffer(now: now), now: now)
        XCTAssertFalse(events.isEmpty)
        XCTAssertFalse(events.contains { $0.message.contains("live-tenant") })
        XCTAssertEqual(events.map(\.message), DemoData.diagnosticEvents.reversed().map(\.message))
    }

    func testLiveModeListsTheBuffer() {
        let now = Date()
        let events = LogViewerView.events(
            demoMode: false, minLevel: .info, windowHours: 4,
            buffer: realBuffer(now: now), now: now)
        XCTAssertEqual(events.map(\.message), ["[info] collecting computers for live-tenant"])
    }

    /// The events are the newest demo run's log, the one Run History lists
    /// first, and end when that run ended, never after the demo's "now".
    func testDemoEventsAreTheNewestRunHistoryLog() throws {
        let newest = try XCTUnwrap(DemoData.runHistory(for: DemoData.org.profile).first)
        XCTAssertEqual(DemoData.diagnosticEvents.map(\.message), newest.lines.map(\.text))
        let last = try XCTUnwrap(DemoData.diagnosticEvents.last?.date)
        XCTAssertEqual(last.timeIntervalSince(newest.summary.date), 0, accuracy: 0.001)
        XCTAssertTrue(DemoData.diagnosticEvents.allSatisfy {
            $0.date <= DemoData.referenceDate.addingTimeInterval(0.001)
        })
        let dates = DemoData.diagnosticEvents.map(\.date)
        XCTAssertEqual(dates, dates.sorted())
    }

    func testRunLineLevelsMapLikeTheCollectStream() {
        XCTAssertEqual(LogEntry.Level(.ok), .info)
        XCTAssertEqual(LogEntry.Level(.info), .info)
        XCTAssertEqual(LogEntry.Level(.warn), .notice)
        XCTAssertEqual(LogEntry.Level(.fail), .error)
    }
}
