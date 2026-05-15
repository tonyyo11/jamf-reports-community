import XCTest
@testable import JamfReports

/// Locks the SchedulesView.extractExitCode contract. The previous parser was
/// `msg.components(separatedBy: "exit ").last.flatMap(Int.init) ?? -1` —
/// fragile in two ways: a missing exit code rendered as a bogus "EXIT -1"
/// pill, and an unexpected log format silently emitted -1 instead of
/// suppressing the pill. Gemini's 2026-05-14 cross-review flagged the parser
/// shape; this suite pins the replacement.
final class SchedulesViewExitCodeTests: XCTestCase {

    // MARK: - Happy path — the producer's actual format

    func testProducerFormatZero() {
        // runSchedule emits "<name> · exit <code>"
        XCTAssertEqual(
            SchedulesView.extractExitCode(from: "Daily Snapshot · exit 0"),
            0
        )
    }

    func testProducerFormatNonZero() {
        XCTAssertEqual(
            SchedulesView.extractExitCode(from: "Daily Snapshot · exit 3"),
            3
        )
    }

    func testProducerFormatLargeCode() {
        XCTAssertEqual(
            SchedulesView.extractExitCode(from: "Long Schedule Name · exit 137"),
            137
        )
    }

    // MARK: - Edge cases — robust where the old parser was brittle

    func testNegativeExitCodeIsExtracted() {
        XCTAssertEqual(
            SchedulesView.extractExitCode(from: "Manual Run · exit -1"),
            -1
        )
    }

    func testNameContainingExitDoesNotConfuseParser() {
        // Previously msg.components(...).last.flatMap(Int.init) accidentally
        // worked here only because "exit 0" was at the end. The regex anchors
        // on end-of-string, so a schedule name with "exit" in it still parses.
        XCTAssertEqual(
            SchedulesView.extractExitCode(from: "Audit & Exit Plan · exit 2"),
            2
        )
    }

    func testTrailingWhitespaceIsTolerated() {
        XCTAssertEqual(
            SchedulesView.extractExitCode(from: "Schedule · exit 0   "),
            0
        )
    }

    // MARK: - Failure modes — returns nil rather than the -1 sentinel

    func testEmptyMessageReturnsNil() {
        XCTAssertNil(SchedulesView.extractExitCode(from: ""))
    }

    func testMessageWithoutExitMarkerReturnsNil() {
        XCTAssertNil(SchedulesView.extractExitCode(from: "Schedule completed"))
    }

    func testMessageWithExitButNoCodeReturnsNil() {
        XCTAssertNil(SchedulesView.extractExitCode(from: "Schedule · exit"))
    }

    func testMessageWithExitInMiddleAndTrailingTextReturnsNil() {
        // If the format ever changes such that " exit 0" is followed by more
        // text, the old parser would happily return whatever came after the
        // last "exit ". Anchoring on end-of-string prevents that confusion.
        XCTAssertNil(
            SchedulesView.extractExitCode(from: "Run with exit 0 followed by trailing words")
        )
    }
}
