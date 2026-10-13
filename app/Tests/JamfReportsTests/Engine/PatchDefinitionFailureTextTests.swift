import Foundation
import XCTest
@testable import JamfReports

/// A failed patch-definition lookup names why, so a run that skips most titles says whether
/// jamf-cli refused them, timed out or answered with nothing.
final class PatchDefinitionFailureTextTests: XCTestCase {
    func testNamesTheExitCode() {
        XCTAssertEqual(ReportEngine.patchDefinitionFailureText((4, Data())), "failed (exit 4)")
        XCTAssertEqual(ReportEngine.patchDefinitionFailureText((8, Data("x".utf8))),
                       "failed (exit 8)")
    }

    func testTimeoutNoDataAndNoLaunchReadApart() {
        XCTAssertEqual(
            ReportEngine.patchDefinitionFailureText((CLIBridge.exitCodeTimedOut, Data())),
            "timed out")
        XCTAssertEqual(ReportEngine.patchDefinitionFailureText((0, Data())),
                       "failed (no data returned)")
        XCTAssertEqual(ReportEngine.patchDefinitionFailureText(nil),
                       "failed (jamf-cli did not start)")
    }
}
