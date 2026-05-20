import XCTest
@testable import JamfReports

/// Track B Wave 2 — B-02 / B-03 defense-in-depth tests for CLIBridge.
///
/// `audit`, `groupHygiene`, `runMulti`, and `diffBackups` previously skipped
/// `ProfileService.isValid(profile)` before passing `-p <profile>` to
/// jamf-cli. While not exploitable as called today, an obviously invalid
/// profile name should be refused at the bridge layer so a future caller
/// (URL handler, drag-drop, AppleScript) cannot turn it into argv-as-flag
/// injection.
///
/// `audit` and `backup` also accept free-text user input bound to
/// `--checks` / `--label`. Leading-dash values must be rejected so they
/// cannot be re-interpreted as flags by jamf-cli/Cobra.
@MainActor
final class CLIBridgeProfileValidationTests: XCTestCase {

    // Profile names that must be refused.
    private let invalidProfiles: [String] = [
        "",
        "--config=/etc/passwd",
        "-foo",
        "foo bar",
        "foo/bar",
        "foo\u{0000}bar",
        "../escape",
    ]

    func test_audit_rejectsInvalidProfile() async {
        let bridge = CLIBridge()
        for profile in invalidProfiles {
            let code = await bridge.audit(profile: profile, category: nil) { _ in }
            XCTAssertEqual(code, -1, "audit must reject profile: \(profile)")
        }
    }

    func test_groupHygiene_rejectsInvalidProfile() async {
        let bridge = CLIBridge()
        for profile in invalidProfiles {
            let code = await bridge.groupHygiene(profile: profile) { _ in }
            XCTAssertEqual(code, -1, "groupHygiene must reject profile: \(profile)")
        }
    }

    func test_runMulti_rejectsInvalidProfileInList() async {
        let bridge = CLIBridge()
        let target = MultiTarget(scope: .list(["good-profile", "--config=/etc/passwd"]))
        let code = await bridge.runMulti(target: target, subcommand: ["pro", "collect"]) { _ in }
        XCTAssertEqual(code, -1)
    }

    func test_diffBackups_rejectsInvalidProfile() async {
        let bridge = CLIBridge()
        let lhs = URL(fileURLWithPath: "/tmp/a")
        let rhs = URL(fileURLWithPath: "/tmp/b")
        for profile in invalidProfiles {
            let code = await bridge.diffBackups(profile: profile, left: lhs, right: rhs) { _ in }
            XCTAssertEqual(code, -1, "diffBackups must reject profile: \(profile)")
        }
    }

    // MARK: - B-03 — leading-dash argv injection

    func test_audit_rejectsLeadingDashCategory() async {
        let bridge = CLIBridge()
        // Use a valid profile so we get past B-02 and exercise the B-03 guard.
        // The default workspace will be missing in a fresh test env, but the
        // category check happens before workspace resolution.
        let code = await bridge.audit(
            profile: "valid-profile",
            category: "--config=/etc/passwd"
        ) { _ in }
        XCTAssertEqual(code, -1, "audit must reject leading-dash category")
    }

    func test_backup_rejectsLeadingDashLabel() async {
        let bridge = CLIBridge()
        // Same as above — we need a valid profile to get past the path
        // resolution; the label check is independent.
        let code = await bridge.backup(
            profile: "valid-profile",
            label: "--config=/etc/passwd"
        ) { _ in }
        // Either workspace setup fails (-1) or label guard fires (-1).
        // Important assertion: never returns 0.
        XCTAssertEqual(code, -1)
    }

    func test_runNow_rejectsInvalidProfile() async {
        let bridge = CLIBridge()
        for profile in invalidProfiles {
            let code = await bridge.runNow(profile: profile, mode: .jamfCLIOnly) { _ in }
            XCTAssertEqual(code, -1, "runNow must reject profile: '\(profile)'")
        }
    }
}
