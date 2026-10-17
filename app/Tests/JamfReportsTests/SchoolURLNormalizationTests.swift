import XCTest
@testable import JamfReports

/// Jamf School's API settings page shows the URL with `/api`, and jamf-cli adds `/api` to
/// every call, so a URL stored with it made every list command 404 (reported on 2.10.0).
@MainActor
final class SchoolURLNormalizationTests: XCTestCase {

    private func normalized(_ raw: String) -> String? {
        OnboardingFlow.normalizedSchoolURL(raw)
    }

    func testATrailingAPIIsRemoved() {
        XCTAssertEqual(normalized("https://school.jamfcloud.com/api"),
                       "https://school.jamfcloud.com")
        XCTAssertEqual(normalized("https://school.jamfcloud.com/api/"),
                       "https://school.jamfcloud.com")
        XCTAssertEqual(normalized(" https://school.jamfcloud.com/API "),
                       "https://school.jamfcloud.com")
    }

    func testAURLWithoutAPIIsKeptAndLosesItsTrailingSlash() {
        XCTAssertEqual(normalized("https://school.jamfcloud.com/"),
                       "https://school.jamfcloud.com")
        XCTAssertEqual(normalized("https://school.jamfcloud.com/apiary"),
                       "https://school.jamfcloud.com/apiary")
    }

    /// jamf-cli adds `https://` to a bare host itself; the app now agrees instead of
    /// marking the stored host as invalid.
    func testABareHostGetsHTTPS() {
        XCTAssertEqual(normalized("school.jamfcloud.com"), "https://school.jamfcloud.com")
        XCTAssertEqual(normalized("school.jamfcloud.com/api"), "https://school.jamfcloud.com")
    }

    func testPlainHTTPAndEmptyValuesAreRefused() {
        XCTAssertNil(normalized("http://school.jamfcloud.com/api"))
        XCTAssertNil(normalized(""))
        XCTAssertNil(normalized("https:///api"))
        XCTAssertNil(normalized("ftp://school.jamfcloud.com"))
    }

    func testTheSetupArgumentsCarryTheNormalizedURL() throws {
        let url = try XCTUnwrap(normalized("https://school.jamfcloud.com/api"))
        let args = OnboardingFlow.schoolArguments(profile: "Albion", url: url)
        let index = try XCTUnwrap(args.firstIndex(of: "--url"))
        XCTAssertEqual(args[index + 1], "https://school.jamfcloud.com")
    }
}
