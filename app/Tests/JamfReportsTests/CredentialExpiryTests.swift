import XCTest
@testable import JamfReports

final class CredentialExpiryTests: XCTestCase {

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        return calendar
    }

    private func credential(
        _ raw: Any?, now: Date, zone: String = "UTC", warning: Int = 90
    ) -> CredentialExpiry {
        CredentialExpiry(
            key: "ca", label: "CA", raw: raw, warningDays: warning, now: now,
            calendar: calendar(zone))
    }

    private let noon = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 12:53 UTC

    func testTheCaptureRule() {
        XCTAssertEqual(CredentialExpiry.parse(1_893_456_000),
                       .instant(Date(timeIntervalSince1970: 1_893_456_000)))
        XCTAssertEqual(CredentialExpiry.parse(1_893_456_000_000),
                       .instant(Date(timeIntervalSince1970: 1_893_456_000)))
        XCTAssertEqual(CredentialExpiry.parse("2030-01-01"), .day("2030-01-01"))
        let plain = CredentialExpiry.parse("2030-01-01T00:00:00Z")
        XCTAssertEqual(plain, .instant(Date(timeIntervalSince1970: 1_893_456_000)))
        XCTAssertEqual(CredentialExpiry.parse("2030-01-01T00:00:00.250Z"),
                       .instant(Date(timeIntervalSince1970: 1_893_456_000.25)))
        XCTAssertEqual(CredentialExpiry.parse("2030-01-01T00:00:00"), plain, "no zone is UTC")
    }

    func testAnythingElseIsNotReported() {
        for value: Any? in [nil, "", "soon", "2030-13-01", true, 1.5, ["a"], NSNull()] {
            XCTAssertNil(CredentialExpiry.parse(value), "\(String(describing: value))")
        }
        XCTAssertEqual(credential(nil, now: noon).state, .notReported)
        XCTAssertNil(credential("soon", now: noon).daysLeft)
    }

    func testADayCredentialHasOneDayCountInAnyZone() {
        // Late evening in New York is already the next UTC day; a day credential must not move.
        let evening = Date(timeIntervalSince1970: 1_790_000_000 + 7 * 3_600)
        let utc = credential("2026-11-15", now: evening, zone: "UTC")
        let local = credential("2026-11-15", now: evening, zone: "America/New_York")
        XCTAssertEqual(utc.daysLeft, local.daysLeft)
        XCTAssertEqual(utc.expiresText, "2026-11-15")
    }

    func testStateEdges() {
        XCTAssertEqual(CredentialExpiry.state(daysLeft: -1, warningDays: 90), .expired)
        XCTAssertEqual(CredentialExpiry.state(daysLeft: 0, warningDays: 90), .expiring)
        XCTAssertEqual(CredentialExpiry.state(daysLeft: 90, warningDays: 90), .expiring)
        XCTAssertEqual(CredentialExpiry.state(daysLeft: 91, warningDays: 90), .ok)
    }

    func testAnInstantIsExpiredAsSoonAsItPasses() {
        let earlierToday = Int(noon.timeIntervalSince1970) - 60
        let expired = credential(earlierToday, now: noon)
        XCTAssertEqual(expired.daysLeft, 0)
        XCTAssertEqual(expired.state, .expired, "never 'expiring' on the day it already passed")
        let later = credential(Int(noon.timeIntervalSince1970) + 60, now: noon)
        XCTAssertEqual(later.state, .expiring)
    }

    func testAnInstantTextIsOneISOInstant() {
        XCTAssertEqual(credential(1_893_456_000, now: noon).expiresText, "2030-01-01T00:00:00Z")
    }
}
