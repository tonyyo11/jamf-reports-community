import XCTest
@testable import JamfReports

/// jamf-cli keeps its profiles under `$XDG_CONFIG_HOME/jamf-cli/` when that variable is set; the
/// app passes it through and reads the same file.
final class JamfCLIConfigLocationTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/someone")

    func testEnvironmentPassesAbsoluteXDGConfigHome() {
        let env = CLIBridge.environmentForJamfCLI(parent: ["XDG_CONFIG_HOME": "/Volumes/Cfg/xdg"])
        XCTAssertEqual(env["XDG_CONFIG_HOME"], "/Volumes/Cfg/xdg")
    }

    func testEnvironmentDropsRelativeOrMissingXDGConfigHome() {
        for parent in [["XDG_CONFIG_HOME": "cfg"], ["XDG_CONFIG_HOME": ""], [:]] {
            XCTAssertNil(CLIBridge.environmentForJamfCLI(parent: parent)["XDG_CONFIG_HOME"])
        }
    }

    func testConfigPathPrefersAbsoluteXDGConfigHome() {
        let url = ProfileService.jamfCLIConfigFileURL(
            environment: ["XDG_CONFIG_HOME": "/Volumes/Cfg/xdg"], home: home)
        XCTAssertEqual(url.path, "/Volumes/Cfg/xdg/jamf-cli/config.yaml")
    }

    func testConfigPathFallsBackToHomeForRelativeOrMissingXDGConfigHome() {
        let expected = "/Users/someone/.config/jamf-cli/config.yaml"
        XCTAssertEqual(
            ProfileService.jamfCLIConfigFileURL(environment: [:], home: home).path, expected)
        XCTAssertEqual(
            ProfileService.jamfCLIConfigFileURL(
                environment: ["XDG_CONFIG_HOME": "relative/dir"], home: home).path,
            expected)
    }
}
