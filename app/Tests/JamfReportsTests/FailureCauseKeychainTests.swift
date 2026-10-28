import XCTest
@testable import JamfReports

/// A locked login keychain: jamf-cli cannot read a `keychain:` credential and exits 1. The
/// message shape is go-keyring's (jamf-cli 1.31 and earlier) and the Security framework's;
/// no profile or host is kept in these fixtures.
final class FailureCauseKeychainTests: XCTestCase {

    private func envelope(_ message: String) -> Data {
        let object: [String: Any] = [
            "error": "request failed", "message": message, "exitCode": 1,
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    func testGoKeyringExitStatusIsKeychainLocked() {
        let cause = FailureCause.classify(
            exitCode: 1,
            stdout: envelope("reading keychain item jamf-cli/profile/client-secret: exit status 36"))
        XCTAssertEqual(cause.kind, .keychainLocked)
        XCTAssertEqual(cause.hint, FailureCause.keychainLockedHint)
        XCTAssertFalse(cause.isPermanent)
    }

    func testSecurityFrameworkTextIsKeychainLocked() {
        let cause = FailureCause.classify(
            exitCode: 1,
            stdout: envelope("reading keychain item jamf-cli/profile/client-secret: "
                + "User interaction is not allowed."))
        XCTAssertEqual(cause.kind, .keychainLocked)
    }

    func testMissingItemIsNotKeychainLocked() {
        let cause = FailureCause.classify(
            exitCode: 1,
            stdout: envelope("reading keychain item jamf-cli/profile/client-secret: "
                + "keychain item not found"))
        XCTAssertEqual(cause.kind, .other)
    }

    func testStderrLineClassifiesAnExitWithNoEnvelope() {
        let watcher = StderrSignalWatcher()
        let forward = watcher.forwarding { _ in }
        forward(.init(
            timestamp: Date(), level: .fail,
            text: "Error: reading keychain item jamf-cli/profile/client-secret: exit status 36"))
        XCTAssertTrue(watcher.sawKeychainLocked)
        let cause = FailureCause.classify(
            exitCode: 1, stdout: Data(), sawKeychainLockedOnStderr: watcher.sawKeychainLocked)
        XCTAssertEqual(cause.kind, .keychainLocked)
        watcher.reset()
        XCTAssertFalse(watcher.sawKeychainLocked)
    }

    func testHintAndWordingAreTheSameEverywhere() {
        XCTAssertEqual(
            FailureCause.keychainLockedHint,
            "Unlock the login keychain (open Keychain Access, or run "
                + "`security unlock-keychain`), then try again")
        let cause = FailureCause(kind: .keychainLocked, names: [],
                                 hint: FailureCause.keychainLockedHint, exitCode: 1)
        XCTAssertTrue(ReportEngine.causeSuffix(cause).contains("hint: Unlock the login keychain"))
        XCTAssertTrue(
            ReportEngine.causeSuffix(cause).contains("cause: the login keychain is locked"))
        XCTAssertTrue(CLIBridge.explainExit(1, operation: "Collect", cause: cause)
            .contains(FailureCause.keychainLockedHint))
        struct Quoted: LocalizedError {
            var errorDescription: String? { "reading keychain item a/b: exit status 36" }
        }
        XCTAssertTrue(CLIBridge.explainOperationError(Quoted(), operation: "Backup")
            .contains(FailureCause.keychainLockedHint))
    }
}
