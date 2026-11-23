import XCTest
@testable import JamfReports

final class SecurityCloudCheckTests: XCTestCase {
    func testArgumentsNameTheProfile() {
        XCTAssertEqual(
            Array(SecurityCloudCheck.arguments(profile: "example-security").prefix(3)),
            ["-p", "example-security", "--no-input"])
    }

    func testAnsweredListCountsDevices() {
        let rows = Data(#"[{"guid":"a"},{"guid":"b"}]"#.utf8)
        XCTAssertEqual(SecurityCloudCheck.summary(exit: 0, data: rows, lastError: nil),
                       "Healthy · risk list answered, 2 devices")
        XCTAssertEqual(SecurityCloudCheck.summary(exit: 0, data: Data("null".utf8), lastError: nil),
                       "Healthy · risk list answered, no devices")
    }

    func testFailureShowsJamfCLIReason() {
        let line = "list: Risk API credentials are not configured; run 'jamf-cli security setup'"
        let text = SecurityCloudCheck.summary(exit: 1, data: Data(), lastError: line)
        XCTAssertTrue(text.hasPrefix("Failed · list: Risk API credentials"), text)
        XCTAssertEqual(SecurityCloudCheck.summary(exit: 3, data: Data(), lastError: nil),
                       "Failed · exit 3")
        XCTAssertEqual(SecurityCloudCheck.summary(
            exit: CLIBridge.exitCodeTimedOut, data: Data(), lastError: nil), "No answer within 60 s")
    }
}
