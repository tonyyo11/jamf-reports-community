import XCTest
@testable import JamfReports

/// The us/eu/apac picker maps to the three gateway hosts and back. A stored URL that is none of
/// them shows as "Other" and is kept until a region is picked.
@MainActor
final class GatewayRegionTests: XCTestCase {

    func testEachRegionMapsToItsHost() {
        XCTAssertEqual(GatewayRegion.us.url, "https://us.api.jamfcloud.com")
        XCTAssertEqual(GatewayRegion.eu.url, "https://eu.api.jamfcloud.com")
        XCTAssertEqual(GatewayRegion.apac.url, "https://apac.api.jamfcloud.com")
        XCTAssertEqual(GatewayRegion.allCases.count, 3)
    }

    func testAKnownHostMapsBackToItsRegion() {
        for region in GatewayRegion.allCases {
            XCTAssertEqual(GatewayRegion.region(forURL: region.url), region)
            XCTAssertEqual(GatewayRegion.region(forURL: region.url + "/"), region)
            XCTAssertEqual(GatewayRegion.region(forURL: "  \(region.url.uppercased())  "), region)
        }
    }

    func testAnyOtherURLIsNotARegion() {
        for other in [
            "https://us.apigw.jamf.com", "https://api.jamfcloud.com",
            "https://us.api.jamfcloud.com.evil.example", "http://us.api.jamfcloud.com",
            "https://us.api.jamfcloud.com:8443", "https://us.api.jamfcloud.com/v1",
            "https://user@us.api.jamfcloud.com", "us.api.jamfcloud.com", "", "not a url",
        ] {
            XCTAssertNil(GatewayRegion.region(forURL: other), other)
        }
    }

    func testTheFlowStartsOnUSAndFollowsThePicker() {
        let flow = OnboardingFlow()
        XCTAssertEqual(flow.gatewayRegion, .us)
        XCTAssertTrue(flow.isGatewayURLValid)

        flow.chooseGatewayRegion(.apac)
        XCTAssertEqual(flow.gatewayURL, "https://apac.api.jamfcloud.com")
        XCTAssertEqual(flow.gatewayRegion, .apac)
    }

    func testAnUnknownStoredURLIsKeptUntilARegionIsPicked() {
        let flow = OnboardingFlow()
        flow.gatewayURL = "https://gateway.example.org"
        XCTAssertNil(flow.gatewayRegion)
        XCTAssertTrue(flow.isGatewayURLValid)
        XCTAssertEqual(flow.gatewayURL, "https://gateway.example.org")

        flow.chooseGatewayRegion(.eu)
        XCTAssertEqual(flow.gatewayRegion, .eu)
    }

    func testAnUnknownInvalidURLStaysInvalid() {
        let flow = OnboardingFlow()
        flow.gatewayURL = "http://gateway.example.org"
        XCTAssertNil(flow.gatewayRegion)
        XCTAssertFalse(flow.isGatewayURLValid)
    }

    /// The profile list keeps a bare host; Update credentials must not start with a URL that
    /// fails validation.
    func testUpdateCredentialsStartsFromTheProfileListsBareHost() {
        XCTAssertEqual(
            GatewayRegion.startingURL(fromStored: "eu.api.jamfcloud.com"), "https://eu.api.jamfcloud.com")
        XCTAssertEqual(
            GatewayRegion.startingURL(fromStored: "https://APAC.api.jamfcloud.com/"),
            "https://apac.api.jamfcloud.com")
        XCTAssertEqual(
            GatewayRegion.startingURL(fromStored: "gateway.example.org"), "https://gateway.example.org")
        XCTAssertNil(GatewayRegion.startingURL(fromStored: "(jamf-cli profile)"))
        XCTAssertNil(GatewayRegion.startingURL(fromStored: "  "))
    }
}
