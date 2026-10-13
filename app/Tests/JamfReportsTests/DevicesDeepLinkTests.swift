import XCTest
@testable import JamfReports

/// The filter another screen asks Devices to open with (#276): the Security Posture card's
/// "Open Devices" button posts the security-gap filter.
final class DevicesDeepLinkTests: XCTestCase {

    func testTheSecurityPostureButtonAsksForTheSecurityGapFilter() {
        let info = DevicesView.DeviceFilter.security.navigationUserInfo()
        XCTAssertEqual(info["tab"], Tab.devices.rawValue)
        XCTAssertEqual(
            DevicesView.DeviceFilter(
                deepLink: DevicesView.DeviceFilter.pending(from: info, destination: .devices)),
            .security)
    }

    func testEveryFilterRoundTripsAndAnUnknownOneIsIgnored() {
        for filter in DevicesView.DeviceFilter.allCases {
            XCTAssertEqual(DevicesView.DeviceFilter(deepLink: filter.rawValue), filter)
        }
        XCTAssertNil(DevicesView.DeviceFilter(deepLink: "bogus"))
        XCTAssertNil(DevicesView.DeviceFilter(deepLink: nil))
    }

    /// A request is held only for a navigation to Devices, so a stale one cannot apply to a
    /// later visit.
    func testAFilterRidesOnlyANavigationToDevices() {
        let info = DevicesView.DeviceFilter.contactGap.navigationUserInfo()
        XCTAssertEqual(DevicesView.DeviceFilter.pending(from: info, destination: .devices),
                       "contactGap")
        XCTAssertNil(DevicesView.DeviceFilter.pending(from: info, destination: .overview))
        XCTAssertNil(DevicesView.DeviceFilter.pending(
            from: ["tab": Tab.devices.rawValue], destination: .devices))
        XCTAssertNil(DevicesView.DeviceFilter.pending(from: nil, destination: .devices))
    }
}
