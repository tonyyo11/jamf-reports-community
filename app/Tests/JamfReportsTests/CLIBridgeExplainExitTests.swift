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

    /// Exit 8 (jamf-cli 1.28+) is a policy refusal, not a fault: the command is
    /// outside what the profile's API publishes. The remedy is a different
    /// profile, so the text must not read as an outage or a credential problem.
    func testRefusedByPolicyNamesTheProfileRemedy() {
        let msg = CLIBridge.explainExit(
            CLIBridge.exitCodeRefusedByPolicy, operation: "Collect")
        XCTAssertTrue(msg.contains("exit 8"))
        XCTAssertTrue(msg.lowercased().contains("refused"))
        XCTAssertTrue(msg.contains("oauth2"), "must name the profile type that can serve it")
        XCTAssertTrue(
            msg.contains("commands -o json"),
            "must name the command that lists the refusals for the binary in hand")
        XCTAssertFalse(
            msg.contains("Run History"),
            "exit 8 remediation must not name Run History: \(msg)")
    }

    /// A refusal must not be confused with the exit-2 usage error it superseded
    /// — they lead to different remedies and only 2 is a caller bug.
    func testRefusedByPolicyIsDistinctFromUsageError() {
        XCTAssertNotEqual(CLIBridge.exitCodeRefusedByPolicy, CLIBridge.exitCodeUsage)
        XCTAssertNotEqual(
            CLIBridge.explainExit(CLIBridge.exitCodeRefusedByPolicy, operation: "X"),
            CLIBridge.explainExit(CLIBridge.exitCodeUsage, operation: "X"))
    }
}
