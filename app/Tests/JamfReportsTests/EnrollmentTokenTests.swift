import Foundation
import XCTest
@testable import JamfReports

final class EnrollmentTokenTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return calendar
    }

    /// 2026-11-15 14:30 local.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 14, minute: 30))
            ?? Date()
    }

    private func token(_ date: Any?) -> EnrollmentToken {
        var row: [String: Any] = ["name": "Placeholder Instance"]
        row["tokenExpirationDate"] = date
        return EnrollmentToken(row: row, warningDays: 90, now: now, calendar: calendar)
    }

    func testExpiredFromTheStartOfTheNextDay() {
        XCTAssertEqual(token("2026-11-15").state, .expiring)
        XCTAssertEqual(token("2026-11-15").daysLeft, 0)
        XCTAssertEqual(token("2026-11-14").state, .expired)
        XCTAssertEqual(token("2026-11-14").daysLeft, -1)
    }

    func testWindowEdges() {
        XCTAssertEqual(token("2027-02-13").state, .expiring)
        XCTAssertEqual(token("2027-02-13").daysLeft, 90)
        XCTAssertEqual(token("2027-02-14").state, .ok)
    }

    func testOtherFormatsAreNotReported() {
        for value: Any? in ["2026-11-20T00:00:00Z", "11/20/2026", "2026-13-01", "2026-02-30",
                            "", nil, 20261120] {
            XCTAssertEqual(token(value).state, .notReported, "\(String(describing: value))")
            XCTAssertNil(token(value).daysLeft)
        }
        XCTAssertEqual(token("2026-11-20").name, "Placeholder Instance")
    }

    func testLoaderTellsNoSnapshotFromUnreadableFromRows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enroll-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let kind = dir.appendingPathComponent("device-enrollment-instances", isDirectory: true)
        try FileManager.default.createDirectory(at: kind, withIntermediateDirectories: true)

        XCTAssertEqual(EnrollmentTokenSnapshot.load(dataDir: dir, warningDays: 90), .empty)

        let file = kind.appendingPathComponent("device-enrollment-instances_20261115_100000.json")
        try Data("not json".utf8).write(to: file)
        XCTAssertEqual(EnrollmentTokenSnapshot.load(dataDir: dir, warningDays: 90), .unreadable)

        try Data("[]".utf8).write(to: file)
        let empty = EnrollmentTokenSnapshot.load(dataDir: dir, warningDays: 90)
        XCTAssertTrue(empty.isDetected)
        XCTAssertFalse(empty.readFailed)
        XCTAssertTrue(empty.tokens.isEmpty)

        try Data(#"[{"name": "Placeholder Instance", "tokenExpirationDate": "2030-01-01"}]"#.utf8)
            .write(to: file)
        let rows = EnrollmentTokenSnapshot.load(
            dataDir: dir, warningDays: 90, now: now, calendar: calendar)
        XCTAssertEqual(rows.tokens.first?.state, .ok)
    }
}
