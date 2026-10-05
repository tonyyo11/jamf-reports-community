import Foundation
import XCTest
@testable import JamfReports

/// Coverage for the file-export redaction path added by PR-7 review-gate CR-1.
/// The clipboard path (`copyLog`) already routed through `RunHistoryService.loadLog`
/// and therefore the LogRedactor; the file-export path previously used
/// `FileManager.copyItem` and copied raw bytes verbatim, bypassing redaction.
///
/// `RunHistoryService.loadLog` reads only `<workspaces root>/<profile>/automation/logs/`, so the
/// test stages a unique profile under `ProfileService.workspacesRoot()`, which under XCTest is
/// this test process's own folder, never the real `~/Jamf-Reports`.
///
/// `@MainActor` is required (PR-9.5): `RunsView.renderExport(from:)` is
/// MainActor-isolated via `View` conformance. Swift 6.0/6.1 (CI macos-latest)
/// enforces the isolation check synchronously; Swift 6.3 (local) relaxes it.
@MainActor
final class RunsViewExportRedactionTests: XCTestCase {

    func testRenderExportRedactsBearerToken() throws {
        let logURL = try writeLogInLogsDir(
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
        let logURL = try writeLogInLogsDir(
            "client_secret: super-secret-value-1234\n"
        )

        let rendered = RunsView.renderExport(from: logURL)

        XCTAssertTrue(rendered.contains("REDACTED_CLIENT_SECRET"))
        XCTAssertFalse(rendered.contains("super-secret-value-1234"))
    }

    // MARK: - Helpers

    /// Stage a log file at `<workspaces root>/<unique-profile>/automation/logs/run.log` (the
    /// only shape `RunHistoryService.loadLog` will read) and return its URL.
    private func writeLogInLogsDir(_ contents: String) throws -> URL {
        let root = ProfileService.workspacesRoot()
        let realRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Jamf-Reports", isDirectory: true)
        XCTAssertNotEqual(root.standardizedFileURL, realRoot.standardizedFileURL)
        let profileRoot = root.appendingPathComponent(
            "pr7-export-test-" + UUID().uuidString.lowercased(), isDirectory: true)
        let logsDir = profileRoot.appendingPathComponent("automation/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logURL = logsDir.appendingPathComponent("run.log")
        try contents.write(to: logURL, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: profileRoot) }
        return logURL
    }
}
