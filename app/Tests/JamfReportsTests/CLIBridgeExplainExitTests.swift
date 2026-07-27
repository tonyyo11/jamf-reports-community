import Foundation
import XCTest
@testable import JamfReports

/// `CLIBridge.explainExit` turns a raw jamf-cli exit code into a plain-language
/// cause + remediation, prefixed by the operation — replacing bare "… exit N"
/// strings across ReportsView / AuditView / BackupsView.
final class CLIBridgeExplainExitTests: XCTestCase {

    func testAlwaysLeadsWithOperation() {
        for code: Int32 in [0, 1, 2, 3, 4, 5, 6, 99] {
            XCTAssertTrue(
                CLIBridge.explainExit(code, operation: "HTML report generation")
                    .hasPrefix("HTML report generation failed: "),
                "exit \(code) should be prefixed by the operation")
        }
    }

    func testAuthCodeMentionsReauth() {
        let msg = CLIBridge.explainExit(CLIBridge.exitCodeUnauthorized, operation: "Audit")
        XCTAssertTrue(msg.contains("401"))
        XCTAssertTrue(msg.lowercased().contains("re-authenticate"))
    }

    func testPermissionCodeMentionsPrivileges() {
        let msg = CLIBridge.explainExit(CLIBridge.exitCodePermissionDenied, operation: "Backup")
        XCTAssertTrue(msg.contains("403"))
        XCTAssertTrue(msg.lowercased().contains("privile"))
    }

    func testRateLimitCodeMentionsWaiting() {
        let msg = CLIBridge.explainExit(CLIBridge.exitCodeRateLimited, operation: "Collect")
        XCTAssertTrue(msg.contains("429"))
        XCTAssertTrue(msg.lowercased().contains("wait"))
    }

    func testNotFoundAndUnknownAreDistinct() {
        XCTAssertTrue(
            CLIBridge.explainExit(CLIBridge.exitCodeNotFound, operation: "X").contains("404"))
        XCTAssertTrue(
            CLIBridge.explainExit(42, operation: "X").contains("exit 42"))
    }

    func testGeneralExitOneHintsNetworkOrPerCommand() {
        let msg = CLIBridge.explainExit(1, operation: "Inventory CSV export")
        XCTAssertTrue(msg.lowercased().contains("network")
            || msg.lowercased().contains("run history"))
    }

    /// `backup` is a caller of `explainExit` (both the GUI and the CLI) and
    /// never writes to Run History — that surface is scoped to collect/generate
    /// by design. The remediation must not promise a screen a given caller
    /// doesn't have; every code's text must hold for every caller.
    func testNoCodeNamesRunHistoryAsARemediationSurface() {
        for code: Int32 in [
            CLIBridge.exitCodePartialFailure, CLIBridge.exitCodeUsage, 1, 42,
        ] {
            let msg = CLIBridge.explainExit(code, operation: "Backup")
            XCTAssertFalse(
                msg.contains("Run History"),
                "exit \(code) remediation must not name Run History: \(msg)"
            )
        }
    }
}
