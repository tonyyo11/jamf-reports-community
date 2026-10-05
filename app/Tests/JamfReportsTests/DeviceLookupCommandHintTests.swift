import XCTest
@testable import JamfReports

/// The command the lookup error offers to run in a terminal. The id comes from the index
/// and a profile name is free text, so neither may reach the shell unquoted.
@MainActor
final class DeviceLookupCommandHintTests: XCTestCase {

    func testAPlainIDReadsAsBefore() {
        XCTAssertEqual(
            DeviceLookupView.cliCommand(kind: .computer, profile: "prod", id: "1234"),
            "jamf-cli -p prod pro device 1234")
        XCTAssertEqual(
            DeviceLookupView.cliCommand(kind: .mobile, profile: "prod", id: "77"),
            "jamf-cli -p prod pro mobile-devices get 77")
    }

    func testAnIDWithShellSyntaxIsQuoted() {
        XCTAssertEqual(
            DeviceLookupView.cliCommand(
                kind: .computer, profile: "prod", id: "$(touch pwned); `id` it's"),
            "jamf-cli -p prod pro device '$(touch pwned); `id` it'\\''s'")
        XCTAssertEqual(
            DeviceLookupView.cliCommand(kind: .mobile, profile: "my prod", id: "a b"),
            "jamf-cli -p 'my prod' pro mobile-devices get 'a b'")
    }

    /// A leading dash would be read as a flag; `--` ends the flags.
    func testAnIDStartingWithADashFollowsDoubleDash() {
        XCTAssertEqual(
            DeviceLookupView.cliCommand(kind: .computer, profile: "prod", id: "-1"),
            "jamf-cli -p prod pro device -- -1")
        XCTAssertEqual(
            DeviceLookupView.cliCommand(kind: .mobile, profile: "prod", id: "--help x"),
            "jamf-cli -p prod pro mobile-devices get -- '--help x'")
    }
}
