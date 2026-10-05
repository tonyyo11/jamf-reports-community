import Foundation
import XCTest
@testable import JamfReports

/// Jamf Pro timestamps can carry milliseconds. A Mac whose last contact was
/// written that way used to get no contact age, so it never read as stale.
final class DeviceInventoryDateParsingTests: XCTestCase {

    private func contactAge(_ lastContact: String) -> Int? {
        let general: [String: Any] = ["name": "Mac-1", "lastContactTime": lastContact]
        return DeviceInventoryService.recordFromComputer(
            ["general": general], source: "computers.json"
        ).daysSinceContact
    }

    /// Half a day past the whole days, so a daylight-saving change in between
    /// cannot move the count.
    private func stamp(daysAgo: Int, fractionalSeconds: Bool) -> String {
        let formatter = ISO8601DateFormatter()
        if fractionalSeconds {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }
        return formatter.string(
            from: Date().addingTimeInterval(-Double(daysAgo) * 86_400 - 43_200))
    }

    func testContactTimesWithMillisecondsGetAContactAge() {
        XCTAssertEqual(contactAge(stamp(daysAgo: 3, fractionalSeconds: true)), 3)
        XCTAssertEqual(contactAge(stamp(daysAgo: 3, fractionalSeconds: false)), 3)
    }

    func testOtherContactFormatsStillParseAndTextDoesNot() {
        XCTAssertNotNil(contactAge("2015-02-17T21:33:23.712Z"))
        XCTAssertNotNil(contactAge("2015-02-17"))
        XCTAssertNil(contactAge("yesterday"))
    }

    /// The shared formatters are read from the Devices load and the Outreach screen at once.
    func testParseDateGivesTheSameDateFromManyThreadsAtOnce() throws {
        let inputs = [
            "2026-03-04T05:06:07Z", "2026-03-04T05:06:07.123Z", "2026-03-04 05:06:07",
            "2026-03-04", "03/04/2026 05:06", "03/04/2026", "yesterday",
        ]
        let expected = inputs.map { DeviceInventoryService.parseDate($0) }
        XCTAssertEqual(expected.compactMap { $0 }.count, 6)
        let mismatches = Tally()
        DispatchQueue.concurrentPerform(iterations: 400) { iteration in
            let index = iteration % inputs.count
            if DeviceInventoryService.parseDate(inputs[index]) != expected[index] {
                mismatches.increment()
            }
        }
        XCTAssertEqual(mismatches.count, 0)
    }

    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int { lock.withLock { value } }

        func increment() { lock.withLock { value += 1 } }
    }
}
