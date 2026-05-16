import Foundation
import XCTest
@testable import JamfReports

/// Coverage for the file-export redaction path added by PR-7 review-gate CR-1.
/// The clipboard path (`copyLog`) already routed through `RunHistoryService.loadLog`
/// and therefore the LogRedactor; the file-export path previously used
/// `FileManager.copyItem` and copied raw bytes verbatim, bypassing redaction.
///
/// `RunHistoryService.loadLog` rejects paths outside
/// `~/Jamf-Reports/<profile>/automation/logs/`, so the test pins a real (unique)
/// directory under the running user's home and cleans up via `addTeardownBlock`.
final class RunsViewExportRedactionTests: XCTestCase {

    func testRenderExportRedactsBearerToken() throws {
        let logURL = try writeLogInRealLogsDir(
            "[info] starting\nAuthorization: Bearer abcdef0123456789abcdef0123456789\n[ok] done\n"
        )

        let rendered = RunsView.renderExport(from: logURL)

        XCTAssertTrue(rendered.contains("REDACTED_BEARER"),
                      "exportLogFile must route through LogRedactor")
        XCTAssertFalse(rendered.contains("abcdef0123456789abcdef0123456789"),
                       "Raw Bearer token must not survive into the exported file")
        // Non-secret content passes through.
        XCTAssertTrue(rendered.contains("[info] starting"))
        XCTAssertTrue(rendered.contains("[ok] done"))
    }

    func testRenderExportRedactsClientSecret() throws {
        let logURL = try writeLogInRealLogsDir(
            "client_secret: super-secret-value-1234\n"
        )

        let rendered = RunsView.renderExport(from: logURL)

        XCTAssertTrue(rendered.contains("REDACTED_CLIENT_SECRET"))
        XCTAssertFalse(rendered.contains("super-secret-value-1234"))
    }

    // MARK: - Helpers

    /// Stage a log file at `~/Jamf-Reports/<unique-profile>/automation/logs/<name>.log`
    /// (the only shape `RunHistoryService.loadLog` will read) and return its URL.
    /// Profile slug uses the test's unique UUID — guaranteed non-collision with
    /// any real workspace.
    private func writeLogInRealLogsDir(_ contents: String) throws -> URL {
        let slug = "pr7-export-test-" + UUID().uuidString.lowercased()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logsDir = home
            .appendingPathComponent("Jamf-Reports", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logURL = logsDir.appendingPathComponent("run.log")
        try contents.write(to: logURL, atomically: true, encoding: .utf8)
        addTeardownBlock {
            // Clean up the slug-scoped subtree only; never touch the parent.
            let profileRoot = home
                .appendingPathComponent("Jamf-Reports", isDirectory: true)
                .appendingPathComponent(slug, isDirectory: true)
            try? FileManager.default.removeItem(at: profileRoot)
        }
        return logURL
    }
}
