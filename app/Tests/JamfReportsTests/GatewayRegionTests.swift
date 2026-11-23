import XCTest
@testable import JamfReports

/// The us/eu/apac picker maps to the three gateway hosts and back. Other takes a typed host, and
/// a stored URL that is none of the three reopens on Other with that host. The retired
/// apigw.jamf.com gateway is refused in every entry point before any jamf-cli call.
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

    // MARK: - Other: a typed host

    func testTheTypedHostAcceptsHostsPortsAndAnOptionalScheme() {
        let accepted: [String: String] = [
            "gateway.example.org": "https://gateway.example.org",
            "https://Gateway.Example.org/": "https://gateway.example.org",
            "  HTTPS://gw-1.example.org:8443  ": "https://gw-1.example.org:8443",
            "10.0.0.5:443": "https://10.0.0.5:443",
            "localhost": "https://localhost",
        ]
        for (typed, url) in accepted {
            XCTAssertEqual(GatewayRegion.check(typed), .ok(url), typed)
        }
    }

    func testTheTypedHostRefusesAnythingElse() {
        for typed in [
            "", "  ", "http://gateway.example.org", "gateway.example.org/path",
            "user@gateway.example.org", "gateway example.org", "-gateway.example.org",
            "gateway-.example.org", "gateway..example.org", ".example.org", "gateway.example.org:",
            "gateway.example.org:0", "gateway.example.org:70000", "gateway.example.org:+80",
            "gateway.example.org:80:90", "gateway_1.example.org", "--url=x", "gatéway.example.org",
        ] {
            XCTAssertEqual(GatewayRegion.check(typed), .invalid, typed)
        }
        XCTAssertEqual(GatewayRegion.problem(with: "http://x.example.org"),
                       GatewayRegion.invalidHostText)
        XCTAssertNil(GatewayRegion.problem(with: "x.example.org"))
    }

    /// Typed, saved with the profile, shown again by Update credentials: Other with that host.
    func testACustomHostRoundTripsThroughTheProfileListToOther() {
        let flow = OnboardingFlow()
        flow.chooseOtherGateway()
        XCTAssertNil(flow.gatewayPickerSelection)
        XCTAssertFalse(flow.isGatewayURLValid, "Other starts with no host")

        flow.gatewayURL = "Gateway.Example.org:8443"
        XCTAssertEqual(flow.normalizedGatewayURL, "https://gateway.example.org:8443")

        // The profile list keeps what jamf-cli was given, as a bare host.
        let reopened = OnboardingFlow()
        let stored = GatewayRegion.startingURL(fromStored: "gateway.example.org:8443")
        XCTAssertEqual(stored, "https://gateway.example.org:8443")
        reopened.gatewayURL = stored ?? ""
        XCTAssertNil(reopened.gatewayPickerSelection)
        XCTAssertEqual(reopened.normalizedGatewayURL, "https://gateway.example.org:8443")
    }

    func testOtherStaysSelectedWhileAHostThatNamesARegionIsTyped() {
        let flow = OnboardingFlow()
        flow.chooseOtherGateway()
        flow.gatewayURL = "https://eu.api.jamfcloud.com"
        flow.gatewayOtherSelected = true
        XCTAssertEqual(flow.gatewayRegion, .eu)
        XCTAssertNil(flow.gatewayPickerSelection)

        flow.chooseGatewayRegion(.apac)
        XCTAssertEqual(flow.gatewayPickerSelection, .apac)
        XCTAssertEqual(flow.gatewayURL, "https://apac.api.jamfcloud.com")
    }

    func testOtherFromARegionClearsTheHostAndAKeptHostIsNotCleared() {
        let flow = OnboardingFlow()
        flow.chooseOtherGateway()
        XCTAssertEqual(flow.gatewayURL, "")

        let kept = OnboardingFlow()
        kept.gatewayURL = "https://gateway.example.org"
        kept.chooseOtherGateway()
        XCTAssertEqual(kept.gatewayURL, "https://gateway.example.org")
    }

    /// A custom host whose first label reads like a region must not be filed under that region.
    func testARegionIsNamedByTheWholeHostNotItsFirstLabel() {
        XCTAssertEqual(Connection.Region.region(forGatewayURL: "https://us.example.com"), .other)
        XCTAssertEqual(Connection.Region.region(forGatewayURL: "https://us.apigw.jamf.com"), .other)
        XCTAssertEqual(Connection.Region.region(forGatewayURL: "https://eu.api.jamfcloud.com"), .eu)
    }

    // MARK: - The retired gateway

    func testTheRetiredGatewayIsRefusedWithAnyLabelPrefix() {
        for typed in [
            "apigw.jamf.com", "https://apigw.jamf.com", "us.apigw.jamf.com",
            "https://EU.APIGW.JAMF.COM/", "a.b.apigw.jamf.com:443",
        ] {
            XCTAssertEqual(GatewayRegion.check(typed), .retired, typed)
        }
        XCTAssertEqual(GatewayRegion.check("notapigw.jamf.com"), .ok("https://notapigw.jamf.com"))
        XCTAssertEqual(GatewayRegion.check("apigw.jamf.com.example.org"),
                       .ok("https://apigw.jamf.com.example.org"))
        XCTAssertTrue(GatewayRegion.retiredRefusal.contains(FailureCause.retiredGatewayHint))
    }

    /// The retired gateway is named even when the scheme or path would make the URL invalid.
    func testTheRetiredGatewayIsNamedBeforeTheShapeIsChecked() {
        for typed in [
            "http://apigw.jamf.com", "https://apigw.jamf.com/x", "https://user@apigw.jamf.com",
            "ftp://us.apigw.jamf.com:8443/a?b#c", "apigw.jamf.com/x",
        ] {
            XCTAssertEqual(GatewayRegion.check(typed), .retired, typed)
        }
        XCTAssertEqual(GatewayRegion.check("http://gateway.example.org"), .invalid)
    }

    /// Onboarding and Update credentials share the flow: a retired host cannot advance, and
    /// registering throws before it looks for jamf-cli.
    func testOnboardingAndUpdateCredentialsRefuseTheRetiredGatewayBeforeJamfCLI() async {
        let flow = OnboardingFlow()
        flow.proConnectionType = .platformGateway
        flow.profileName = "acme"
        flow.platformScopeID = "env-1"
        flow.gatewayURL = "https://us.apigw.jamf.com"
        XCTAssertFalse(flow.isGatewayURLValid)
        XCTAssertFalse(ReauthenticateSheet.canVerifyPlatform(
            isBusy: false, gatewayURLValid: flow.isGatewayURLValid, scopeID: "env-1",
            clientID: "client", hasSecret: true))
        do {
            try await flow.registerJamfCLIProfile()
            XCTFail("a retired gateway must not register")
        } catch OnboardingFlow.FlowError.invalidGatewayHost(let problem) {
            XCTAssertEqual(problem, GatewayRegion.retiredRefusal)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testStartingAConnectionRefusesAProfileOnTheRetiredGateway() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = ConnectionStore(url: dir.appendingPathComponent("connections.json"))

        XCTAssertThrowsError(try ConnectionStarter.start(
            profile: "old", storedURL: "us.apigw.jamf.com", configText: nil, store: store)
        ) { XCTAssertEqual($0.localizedDescription, GatewayRegion.retiredRefusal) }
        XCTAssertTrue(store.load().isEmpty)

        let started = try ConnectionStarter.start(
            profile: "custom", storedURL: "gateway.example.org:8443", configText: nil,
            store: store)
        XCTAssertEqual(started.region, .other)
    }
}
