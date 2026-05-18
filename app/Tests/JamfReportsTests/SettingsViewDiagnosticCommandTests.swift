import Foundation
import XCTest
@testable import JamfReports

/// PR-19: pure-function tests for the diagnostic-bundle command builder.
/// The builder is intentionally separated from the side-effecting
/// `runDiagnosticBundle` (clipboard + Terminal launch) so the
/// bundled-vs-fallback behavior is testable without UI plumbing.
final class SettingsViewDiagnosticCommandTests: XCTestCase {

    // MARK: - Bundled script (release builds)

    func testUsesAbsolutePathFromBundledScriptWhenAvailable() {
        let configPath = "/Users/example/Jamf-Reports/prod/config.yaml"
        let bundledScript = URL(
            fileURLWithPath: "/Applications/JamfReports.app/Contents/Resources/jamf-reports-community.py"
        )

        let result = SettingsView.buildDiagnosticBundleCommand(
            configPath: configPath, bundledScriptURL: bundledScript
        )

        XCTAssertTrue(result.command.contains("'/Applications/JamfReports.app/Contents/Resources/jamf-reports-community.py'"),
                      "Bundled-script branch must emit the absolute path so the command is cwd-independent")
        XCTAssertTrue(result.command.contains("diagnostic-bundle"))
        XCTAssertTrue(result.command.contains("--config '\(configPath)'"))
        XCTAssertFalse(result.successMessage.contains("cd to your"),
                       "Bundled-script success message must NOT instruct the user to cd anywhere")
        XCTAssertTrue(result.successMessage.contains("any working directory"))
    }

    // MARK: - Dev build fallback (swift run)

    func testFallsBackToRelativePathWhenNoBundledScript() {
        let configPath = "/Users/example/Jamf-Reports/dev/config.yaml"

        let result = SettingsView.buildDiagnosticBundleCommand(
            configPath: configPath, bundledScriptURL: nil
        )

        XCTAssertTrue(result.command.hasPrefix("python3 jamf-reports-community.py"),
                      "Dev-build fallback must emit the relative-path command")
        XCTAssertTrue(result.command.contains("--config '\(configPath)'"))
        XCTAssertTrue(result.successMessage.contains("cd to your jamf-reports-community checkout"),
                      "Dev-build success message must tell the user to cd into the script dir")
    }

    // MARK: - Shell quoting safety

    func testEscapesSingleQuotesInConfigPath() {
        // POSIX single-quoted strings need `'` → `'\''`. Workspace paths under
        // ~/Jamf-Reports/<slug>/ never contain a single quote (slug regex
        // forbids it), but a user-supplied custom seed-config path through
        // this surface could — proving the boundary is hardened here keeps
        // the surface safe if it widens later.
        let configPath = "/Users/o'malley/Jamf-Reports/prod/config.yaml"

        let result = SettingsView.buildDiagnosticBundleCommand(
            configPath: configPath, bundledScriptURL: nil
        )

        XCTAssertTrue(result.command.contains("o'\\''malley"),
                      "Single quote in config path must be escaped as '\\''; got: \(result.command)")
        XCTAssertFalse(result.command.contains("o'malley'"),
                       "Raw single quote in config path would break shell parsing")
    }

    func testEscapesSingleQuotesInBundledScriptPath() {
        let bundledScript = URL(
            fileURLWithPath: "/Users/o'malley/JamfReports.app/Contents/Resources/jamf-reports-community.py"
        )

        let result = SettingsView.buildDiagnosticBundleCommand(
            configPath: "/safe/path.yaml", bundledScriptURL: bundledScript
        )

        XCTAssertTrue(result.command.contains("o'\\''malley"),
                      "Single quote in bundled script path must be escaped; got: \(result.command)")
    }
}
