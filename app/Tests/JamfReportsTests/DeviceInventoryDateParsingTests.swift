import Foundation
import XCTest
@testable import JamfReports

final class DeviceInventoryDateParsingTests: XCTestCase {

    func testParseDateAcceptsFractionalSeconds() {
        XCTAssertNotNil(DeviceInventoryService.parseDate("2015-02-17T21:33:23.712Z"))
        XCTAssertNotNil(DeviceInventoryService.parseDate("2015-02-17T21:33:23Z"))
        XCTAssertNotNil(DeviceInventoryService.parseDate("2015-02-17"))
        XCTAssertNil(DeviceInventoryService.parseDate("yesterday"))
    }
}
