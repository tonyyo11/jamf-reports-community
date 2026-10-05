import XCTest
@testable import JamfReports

/// Config › Thresholds: the stale-basis switches.
final class StaleBasisControlsTests: XCTestCase {

    func testTheScreenKeepsAtLeastOneDateOn() {
        XCTAssertEqual(StaleBasisControls.setting(.inventory, on: true, in: [.checkIn]),
                       [.checkIn, .inventory])
        XCTAssertEqual(StaleBasisControls.setting(.checkIn, on: false, in: [.checkIn, .inventory]),
                       [.inventory])
        XCTAssertEqual(StaleBasisControls.setting(.checkIn, on: false, in: [.checkIn]), [.checkIn],
                       "the last date cannot be turned off")
        XCTAssertEqual(StaleBasisControls.setting(.contact, on: true, in: [.inventory, .checkIn]),
                       [.checkIn, .inventory, .contact], "canonical order")
    }
}
