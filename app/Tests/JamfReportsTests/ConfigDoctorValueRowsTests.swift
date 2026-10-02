import Foundation
import XCTest
@testable import JamfReports

/// Values the app replaced, clamped or ignored are stated by the Config Doctor, and the two
/// value-reading changes that go with them.
final class ConfigDoctorValueRowsTests: XCTestCase {

    // MARK: - notify.detail fails toward sending less

    func testAnUnrecognisedNotifyDetailResolvesToMinimal() throws {
        for typed in ["verbose", "", "ful", "everything"] {
            let notify = try XCTUnwrap(
                try ConfigLoader.loadFromString("notify:\n  detail: \"\(typed)\"\n").notify)
            XCTAssertEqual(notify.resolvedDetail, .minimal,
                           "\"\(typed)\" is neither full nor minimal, so it must send less")
        }
    }

    func testNotifyDetailIsReadCaseInsensitivelyAndAbsentStaysFull() throws {
        let upper = try XCTUnwrap(
            try ConfigLoader.loadFromString("notify:\n  detail: MINIMAL\n").notify)
        XCTAssertEqual(upper.resolvedDetail, .minimal)
        let mixed = try XCTUnwrap(
            try ConfigLoader.loadFromString("notify:\n  detail: Full\n").notify)
        XCTAssertEqual(mixed.resolvedDetail, .full)
        let absent = try XCTUnwrap(
            try ConfigLoader.loadFromString("notify:\n  enabled: false\n").notify)
        XCTAssertEqual(absent.resolvedDetail, .full, "no value typed: the documented default")
    }
}
