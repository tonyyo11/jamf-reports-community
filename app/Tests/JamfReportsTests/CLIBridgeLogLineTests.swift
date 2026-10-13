import Foundation
import XCTest
@testable import JamfReports

/// The live logs colour a line by its level; only jamf-cli's unmarked `Error: …` line is read
/// from the text (#273).
final class CLIBridgeLogLineTests: XCTestCase {

    private func line(_ text: String) -> CLIBridge.LogLine {
        CLIBridge.LogLine(timestamp: Date(), level: CLIBridge.LogLevel.from(line: text), text: text)
    }

    func testKindNamesContainingFailStayAtTheirLevel() {
        let ok = line("[ok] patch-device-failures: 12 rows")
        XCTAssertEqual(ok.level, .ok)
        XCTAssertFalse(ok.isBareError)

        let plan = line("[plan] skipping 2 sources (jamf_cli.collect_skip): update-device-failures")
        XCTAssertEqual(plan.level, .info)
        XCTAssertFalse(plan.isBareError)
    }

    func testJamfCLIErrorLineIsBareError() {
        XCTAssertTrue(line("Error: permission denied (HTTP 403)").isBareError)
        XCTAssertTrue(line("  error: unknown flag --foo").isBareError)
        XCTAssertFalse(line("[info] no error devices reported").isBareError)
    }
}
