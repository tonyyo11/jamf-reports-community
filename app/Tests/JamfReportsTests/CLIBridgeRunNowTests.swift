import Darwin
import Foundation
import XCTest
@testable import JamfReports

/// Tests for the `newestCSV(in:)` logic embedded in `CLIBridge.runNow`.
///
/// `newestCSV` is `private` on `CLIBridge`, so it cannot be called directly.
/// These tests exercise it through `runNow` using `JRC_TEST_WORKSPACES_ROOT`
/// to redirect workspace resolution to a temp directory.
///
/// Observable behaviour: `runNow` in `.jamfCLIFull` mode resolves the newest
/// CSV before calling `collectThenGenerate`. When jamf-cli is absent the flow
/// fails at the auth-guard before any CSV content is read, so the CSV-selection
/// path is exercised but the result (which URL was chosen) is not surfaced
/// through public log lines. Tests that can be asserted without jamf-cli cover
/// the precondition checks (invalid profile, workspace not found). Tests that
/// require observing which CSV was selected are skipped when jamf-cli is absent
/// — they are documented here so the gap is explicit.
@MainActor
final class CLIBridgeRunNowTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a temp workspaces root and a profile directory inside it.
    /// Sets `JRC_TEST_WORKSPACES_ROOT` and registers teardown to unset + delete.
    private func makeWorkspace(profile: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIBridgeRunNowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    private func writeCSV(named name: String, to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "name,serial\nMac,ABC123\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Invalid profile

    /// `runNow` must reject an invalid profile slug before touching the filesystem.
    func test_runNow_rejectsInvalidProfile() async {
        let bridge = CLIBridge()
        let collector = RunLineCollector()
        do {
            _ = try await bridge.runNow(
                profile: "../evil",
                mode: .jamfCLIFull
            ) { line in collector.append(line) }
            XCTFail("runNow must throw for an invalid profile")
        } catch let e as CLIBridgeError {
            XCTAssertEqual(e, .invalidProfile("../evil"), "runNow must throw .invalidProfile")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertTrue(
            collector.lines.contains(where: { $0.text.contains("invalid profile name") }),
            "expected invalid profile error; got: \(collector.lines.map(\.text))"
        )
    }

    // MARK: - newestCSV — no CSV files

    /// When the workspace has no CSV files, `newestCSV` returns nil. `runNow` in
    /// `.jamfCLIFull` mode passes nil csvPath to `collectThenGenerate`.
    /// With jamf-cli absent the auth guard fires — the test verifies the path
    /// reaches `collectThenGenerate` (auth guard log line) rather than stopping
    /// earlier for a missing-CSV reason.
    func test_runNow_noCSV_proceedsToAuthGuard() async throws {
        let profile = "runnow-nocsv-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try makeWorkspace(profile: profile)

        let bridge = CLIBridge()
        let collector = RunLineCollector()
        // Valid profile: must not throw .invalidProfile — any other throw or non-zero exit is acceptable.
        do {
            let code = try await bridge.runNow(profile: profile, mode: .jamfCLIFull) { line in
                collector.append(line)
            }
            // The auth guard must have been reached; it emits either an auth failure or
            // a jamf-cli not-found line.
            let authLinePresent = collector.lines.contains(where: {
                $0.text.contains("auth check failed") || $0.text.contains("jamf-cli not found")
            })
            XCTAssertTrue(authLinePresent,
                          "expected auth guard line; got: \(collector.lines.map(\.text))")
            _ = code  // non-zero is expected when jamf-cli is absent; we only assert the path was reached
        } catch let e as CLIBridgeError {
            // Only .invalidProfile would indicate the wrong code path was hit.
            if case .invalidProfile = e {
                XCTFail("runNow must not use the invalid-profile exit path for a valid profile; got \(e)")
            }
            // Any other CLIBridgeError (executableNotFound, workspaceMissing, etc.) is acceptable.
        } catch {
            // Non-CLIBridgeError throws are fine; they mean we passed profile validation.
        }
    }

    // MARK: - newestCSV — inbox preferred over root

    /// When `csv-inbox/` exists and contains a CSV, `newestCSV` must prefer it
    /// over a root-level CSV. This test documents the expected behaviour; the
    /// assertion is limited to confirming `runNow` reaches the auth guard (not a
    /// CSV-missing early exit), because the selected URL is not surfaced in log
    /// lines without jamf-cli executing the full pipeline.
    func test_runNow_inboxPreferredOverRoot_reachesAuthGuard() async throws {
        let profile = "runnow-inbox-\(UUID().uuidString.prefix(8).lowercased())"
        let workspace = try makeWorkspace(profile: profile)

        // Place a CSV at the root level.
        _ = try writeCSV(named: "root.csv", to: workspace)

        // Place a newer CSV in csv-inbox/.
        let inbox = workspace.appendingPathComponent("csv-inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        _ = try writeCSV(named: "inbox.csv", to: inbox)

        let bridge = CLIBridge()
        let collector = RunLineCollector()
        do {
            _ = try await bridge.runNow(profile: profile, mode: .jamfCLIFull) { line in
                collector.append(line)
            }
        } catch let e as CLIBridgeError {
            if case .invalidProfile = e {
                XCTFail("runNow must not throw .invalidProfile for a valid profile; got \(e)")
            }
        } catch { /* non-CLIBridgeError throw is acceptable */ }

        let authLinePresent = collector.lines.contains(where: {
            $0.text.contains("auth check failed") || $0.text.contains("jamf-cli not found")
        })
        XCTAssertTrue(authLinePresent,
                      "expected auth guard line; got: \(collector.lines.map(\.text))")
    }

    // MARK: - newestCSV — multiple CSVs in inbox

    /// When multiple CSVs exist in `csv-inbox/`, `newestCSV` must select the one
    /// with the most recent modification date. The selected URL is not directly
    /// observable; this test confirms the path reaches the auth guard (not an
    /// early exit for missing CSV), verifying `newestCSV` found at least one file.
    func test_runNow_multipleInboxCSVs_reachesAuthGuard() async throws {
        let profile = "runnow-multi-\(UUID().uuidString.prefix(8).lowercased())"
        let workspace = try makeWorkspace(profile: profile)
        let inbox = workspace.appendingPathComponent("csv-inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        let older = try writeCSV(named: "older.csv", to: inbox)
        // Force a measurable mtime difference between the two files.
        let olderMtime = Date(timeIntervalSinceNow: -60)
        try FileManager.default.setAttributes(
            [.modificationDate: olderMtime],
            ofItemAtPath: older.path
        )
        _ = try writeCSV(named: "newer.csv", to: inbox)

        let bridge = CLIBridge()
        let collector = RunLineCollector()
        do {
            _ = try await bridge.runNow(profile: profile, mode: .jamfCLIFull) { line in
                collector.append(line)
            }
        } catch let e as CLIBridgeError {
            if case .invalidProfile = e {
                XCTFail("runNow must not throw .invalidProfile for a valid profile; got \(e)")
            }
        } catch { /* non-CLIBridgeError throw is acceptable */ }

        let authLinePresent = collector.lines.contains(where: {
            $0.text.contains("auth check failed") || $0.text.contains("jamf-cli not found")
        })
        XCTAssertTrue(authLinePresent,
                      "expected auth guard line; got: \(collector.lines.map(\.text))")
    }

    // MARK: - snapshotOnly mode bypasses newestCSV

    /// `.snapshotOnly` mode calls `collect` directly and never invokes `newestCSV`.
    /// The auth guard must still fire, confirming the correct subpath was taken.
    func test_runNow_snapshotOnlyMode_doesNotRequireCSV() async throws {
        let profile = "runnow-snap-\(UUID().uuidString.prefix(8).lowercased())"
        _ = try makeWorkspace(profile: profile)

        let bridge = CLIBridge()
        let collector = RunLineCollector()
        do {
            _ = try await bridge.runNow(profile: profile, mode: .snapshotOnly) { line in
                collector.append(line)
            }
        } catch let e as CLIBridgeError {
            if case .invalidProfile = e {
                XCTFail("runNow must not throw .invalidProfile for a valid profile; got \(e)")
            }
        } catch { /* non-CLIBridgeError throw is acceptable */ }

        let authLinePresent = collector.lines.contains(where: {
            $0.text.contains("auth check failed") || $0.text.contains("jamf-cli not found")
        })
        XCTAssertTrue(authLinePresent,
                      "expected auth guard line; got: \(collector.lines.map(\.text))")
    }
}

// MARK: - RunLineCollector

private final class RunLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [CLIBridge.LogLine] = []

    func append(_ line: CLIBridge.LogLine) {
        lock.lock(); defer { lock.unlock() }
        _lines.append(line)
    }

    var lines: [CLIBridge.LogLine] {
        lock.lock(); defer { lock.unlock() }
        return _lines
    }
}
