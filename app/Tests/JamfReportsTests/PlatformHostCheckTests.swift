import XCTest
@testable import JamfReports

final class PlatformHostCheckTests: XCTestCase {
    func testHostsCompareCaseInsensitivelyWithOrWithoutScheme() {
        XCTAssertEqual(PlatformHostCheck.verdict(
            jamfProURL: "https://Example.jamfcloud.com",
            platformJamfProURL: "example.jamfcloud.com/"), .same)
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
        XCTAssertEqual(
            PlatformHostCheck.verdict(jamfProURL: nil, platformJamfProURL: "b"), .unknown)
    }

    private func lookup(
        jamfProIsPlatform: Bool = false, learned: [String: String], stored: [String: String]
    ) -> (jamfPro: String?, platform: String?) {
        PlatformHostCheck.lookup(
            jamfPro: "pro", platform: "api", jamfProIsPlatform: jamfProIsPlatform,
            configured: "https://configured.example.org",
            learned: { learned[$0] }, stored: { stored[$0] })
    }

    /// A stored URL outlives a profile re-pointed at another tenant, so the probe wins.
    func testTheServersAnswerBeatsTheStoredURL() {
        let found = lookup(learned: ["api": "https://new.example.org"],
                           stored: ["api": "https://old.example.org"])
        XCTAssertEqual(found.platform, "https://new.example.org")
        XCTAssertEqual(found.jamfPro, "https://configured.example.org")
    }

    func testTheStoredURLStandsInOnlyWhenTheProbeFails() {
        XCTAssertEqual(lookup(learned: [:], stored: ["api": "https://old.example.org"]).platform,
                       "https://old.example.org")
    }

    /// A custom domain: jamf-cli holds the tenant URL, the server reports its own setting, and
    /// both sides are asked of the server so they compare like with like.
    func testBothSidesAreAskedOfTheServer() {
        let found = lookup(
            learned: ["pro": "https://jamf.acme.org", "api": "https://jamf.acme.org"], stored: [:])
        XCTAssertEqual(found.jamfPro, "https://jamf.acme.org")
        XCTAssertEqual(PlatformHostCheck.verdict(
            jamfProURL: found.jamfPro, platformJamfProURL: found.platform), .same)
        XCTAssertEqual(lookup(learned: ["api": "https://x.org"], stored: [:]).jamfPro,
                       "https://configured.example.org")
    }

    /// A Platform `jamf_pro` has the gateway as its URL, so it is learned like the other side.
    func testAPlatformJamfProIsLearnedNotConfigured() {
        let found = lookup(jamfProIsPlatform: true, learned: ["pro": "https://p.example.org"],
                           stored: [:])
        XCTAssertEqual(found.jamfPro, "https://p.example.org")
    }
}
