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
            do {
                _ = try await bridge.audit(profile: profile, category: nil) { _ in }
                XCTFail("audit must throw for profile: \(profile)")
            } catch let e as CLIBridgeError {
                XCTAssertEqual(e, .invalidProfile(profile), "audit must throw .invalidProfile for: \(profile)")
            } catch {
                XCTFail("Unexpected error type for profile \(profile): \(error)")
            }
        }
    }

    func test_groupHygiene_rejectsInvalidProfile() async {
        let bridge = CLIBridge()
        for profile in invalidProfiles {
            do {
                _ = try await bridge.groupHygiene(profile: profile) { _ in }
                XCTFail("groupHygiene must throw for profile: \(profile)")
            } catch let e as CLIBridgeError {
                XCTAssertEqual(e, .invalidProfile(profile), "groupHygiene must throw .invalidProfile for: \(profile)")
            } catch {
                XCTFail("Unexpected error type for profile \(profile): \(error)")
            }
        }
    }

    func test_runMulti_rejectsInvalidProfileInList() async {
        let bridge = CLIBridge()
        let target = MultiTarget(scope: .list(["good-profile", "--config=/etc/passwd"]))
        do {
            _ = try await bridge.runMulti(target: target, subcommand: ["pro", "collect"]) { _ in }
            XCTFail("runMulti must throw for an invalid profile in the list")
        } catch let e as CLIBridgeError {
            XCTAssertEqual(e, .invalidProfile("--config=/etc/passwd"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_diffBackups_rejectsInvalidProfile() async {
        let bridge = CLIBridge()
        let lhs = URL(fileURLWithPath: "/tmp/a")
        let rhs = URL(fileURLWithPath: "/tmp/b")
        for profile in invalidProfiles {
            do {
                _ = try await bridge.diffBackups(profile: profile, left: lhs, right: rhs) { _ in }
                XCTFail("diffBackups must throw for profile: \(profile)")
            } catch let e as CLIBridgeError {
                XCTAssertEqual(e, .invalidProfile(profile), "diffBackups must throw .invalidProfile for: \(profile)")
            } catch {
                XCTFail("Unexpected error type for profile \(profile): \(error)")
            }
        }
    }

    // MARK: - B-03 — leading-dash argv injection

    func test_audit_rejectsLeadingDashCategory() async {
        let bridge = CLIBridge()
        // Use a valid profile so we get past B-02 and exercise the B-03 guard.
        // The default workspace will be missing in a fresh test env, but the
        // category check happens before workspace resolution.
        do {
            _ = try await bridge.audit(
                profile: "valid-profile",
                category: "--config=/etc/passwd"
            ) { _ in }
            XCTFail("audit must throw for leading-dash category")
        } catch let e as CLIBridgeError {
            if case .invalidArgument = e { /* expected */ } else {
                XCTFail("Expected .invalidArgument, got \(e)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_backup_rejectsLeadingDashLabel() async {
        let bridge = CLIBridge()
        // Same as above — we need a valid profile to get past the path
        // resolution; the label check is independent.
        do {
            _ = try await bridge.backup(
                profile: "valid-profile",
                label: "--config=/etc/passwd"
            ) { _ in }
            XCTFail("backup must throw for leading-dash label")
        } catch let e as CLIBridgeError {
            if case .invalidArgument = e { /* expected */ } else {
                XCTFail("Expected .invalidArgument, got \(e)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_runNow_rejectsInvalidProfile() async {
        let bridge = CLIBridge()
        for profile in invalidProfiles {
            do {
                _ = try await bridge.runNow(profile: profile, mode: .jamfCLIOnly) { _ in }
                XCTFail("runNow must throw for profile: '\(profile)'")
            } catch let e as CLIBridgeError {
                XCTAssertEqual(e, .invalidProfile(profile), "runNow must throw .invalidProfile for: '\(profile)'")
            } catch {
                XCTFail("Unexpected error type for profile \(profile): \(error)")
            }
        }
    }
}
