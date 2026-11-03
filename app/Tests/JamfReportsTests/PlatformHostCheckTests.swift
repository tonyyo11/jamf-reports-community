import XCTest
@testable import JamfReports

final class PlatformHostCheckTests: XCTestCase {
    func testHostsCompareCaseInsensitivelyWithOrWithoutScheme() {
        XCTAssertEqual(PlatformHostCheck.verdict(
            jamfProURL: "https://Example.jamfcloud.com", platformJamfProURL: "example.jamfcloud.com/"),
            .same)
    }

    func testDifferentHostsAreNamed() {
        XCTAssertEqual(PlatformHostCheck.verdict(
            jamfProURL: "https://a.jamfcloud.com", platformJamfProURL: "https://b.jamfcloud.com"),
            .different(jamfPro: "a.jamfcloud.com", platform: "b.jamfcloud.com"))
    }

    /// We could not ask: a warning, never a block (spec 3.1).
    func testAnUnknownHostIsUnknown() {
        XCTAssertEqual(PlatformHostCheck.verdict(
            jamfProURL: "https://a.jamfcloud.com", platformJamfProURL: nil), .unknown)
        XCTAssertEqual(PlatformHostCheck.verdict(jamfProURL: nil, platformJamfProURL: "b"), .unknown)
    }
}
