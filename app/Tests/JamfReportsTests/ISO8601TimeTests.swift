import XCTest
@testable import JamfReports

/// The format-style readers and writers must give the strings and dates the
/// `ISO8601DateFormatter`s they replaced did: workbooks, summaries and state files carry them.
final class ISO8601TimeTests: XCTestCase {
    private let sampleDates: [Date] = stride(from: -2_000_000_000.0, through: 4_000_000_000.0,
                                             by: 7_654_321.37).map(Date.init(timeIntervalSince1970:))

    func testStringMatchesTheLegacyFormatter() {
        let legacy = ISO8601DateFormatter()
        for date in sampleDates {
            XCTAssertEqual(ISO8601Time.string(date), legacy.string(from: date))
        }
    }

    func testWorkbookTimestampMatchesTheLegacyFormatter() {
        let legacy = ISO8601DateFormatter()
        legacy.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        for date in sampleDates {
            let expected = legacy.string(from: date)
                .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "T", with: "_")
            XCTAssertEqual(ReportEngine.workbookTimestamp(date), expected)
        }
    }

    func testParseReadsWhatTheLegacyFormattersRead() throws {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let inputs = [
            "2026-10-29T12:34:56Z", "2026-10-29T12:34:56+00:00", "2026-10-29T12:34:56-0500",
            "2026-10-29T12:34:56.712Z", "2015-02-17T21:33:23.7Z", "  2026-10-29T12:34:56Z",
            "1969-12-31T23:59:59Z",
        ]
        for text in inputs {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let expected = plain.date(from: text) ?? fractional.date(from: trimmed)
            let read = try? XCTUnwrap(ISO8601Time.parse(text), text)
            // A fraction may differ in the last floating-point bits, never by a millisecond.
            XCTAssertEqual(read?.timeIntervalSince1970 ?? 0,
                           try XCTUnwrap(expected).timeIntervalSince1970, accuracy: 0.0005, text)
        }
    }

    func testParseRejectsWhatTheLegacyFormattersRejected() {
        for text in ["", "garbage", "2026-10-29", "2026-10-29 12:34:56", "2026-13-29T12:34:56Z",
                     "2026-10-29T12:34:56", "20261029T123456Z"] {
            XCTAssertNil(ISO8601Time.parse(text), text)
        }
    }

    func testDateOnlyStyleMatchesTheLegacyFormatter() {
        let legacy = ISO8601DateFormatter()
        legacy.formatOptions = [.withFullDate]
        for text in ["2026-05-11", "1999-12-31", "2026-05-11T00:00:00"] {
            let head = String(text.prefix(10))
            XCTAssertEqual(try? Date.ISO8601FormatStyle().year().month().day().parse(head),
                           legacy.date(from: head), text)
        }
    }
}
