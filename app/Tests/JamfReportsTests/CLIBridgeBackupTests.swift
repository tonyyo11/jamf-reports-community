import XCTest
@testable import JamfReports

@MainActor
final class CLIBridgeBackupTests: XCTestCase {

    // MARK: - Real backup() call tests

    /// Invalid profile slug must cause backup() to return -1 immediately without
    /// attempting any filesystem operations. No jamf-cli needed.
    func test_backup_rejectsInvalidProfile() async {
        let bridge = CLIBridge()
        let collector = LineCollector()
        do {
            _ = try await bridge.backup(profile: "../etc/passwd", label: nil) { line in
                collector.append(line)
            }
            XCTFail("backup must throw for an invalid profile slug")
        } catch let e as CLIBridgeError {
            XCTAssertEqual(e, .invalidProfile("../etc/passwd"), "backup must throw .invalidProfile")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertTrue(
            collector.lines.contains(where: { $0.text.contains("invalid profile name") }),
            "expected an [error] invalid profile name line; got: \(collector.lines.map(\.text))"
        )
    }

    /// A label beginning with '-' must be rejected before any subprocess is launched.
    func test_backup_rejectsLeadingDashLabel() async {
        let bridge = CLIBridge()
        let collector = LineCollector()
        do {
            _ = try await bridge.backup(profile: "valid-profile", label: "--evil") { line in
                collector.append(line)
            }
            XCTFail("backup must throw for a leading-dash label")
        } catch let e as CLIBridgeError {
            if case .invalidArgument = e { /* expected */ } else {
                XCTFail("Expected .invalidArgument, got \(e)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertTrue(
            collector.lines.contains(where: { $0.text.contains("may not start with '-'") }),
            "expected label rejection line; got: \(collector.lines.map(\.text))"
        )
    }

    /// When the backups/ directory cannot be created (a regular file blocks it),
    /// backup() must throw `.directoryOperationFailed` and emit an error line.
    /// No jamf-cli needed — the failure occurs before the binary is invoked.
    func test_backup_throwsDirectoryOperationFailedWhenBackupsDirBlocked() async throws {
        guard ExecutableLocator.locate("jamf-cli") != nil else {
            // The check for executable happens before workspace validation in backup().
            // Skip on machines without jamf-cli since .executableNotFound fires first.
            throw XCTSkip("jamf-cli not installed — executableNotFound fires before directory check")
        }
        // Build a minimal temp workspace so ProfileService.workspaceURL resolves.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIBridgeBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let profile = "backup-dirtest-\(UUID().uuidString.prefix(8).lowercased())"
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        // Plant a regular file at <workspace>/backups to block createDirectory.
        let blockingFile = workspace.appendingPathComponent("backups")
        try "blocking".write(to: blockingFile, atomically: true, encoding: .utf8)

        let bridge = CLIBridge()
        let collector = LineCollector()
        do {
            _ = try await bridge.backup(profile: profile, label: nil) { line in
                collector.append(line)
            }
            XCTFail("backup must throw when backups/ directory cannot be created")
        } catch let e as CLIBridgeError {
            if case .directoryOperationFailed = e { /* expected */ } else {
                XCTFail("Expected .directoryOperationFailed, got \(e)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertTrue(
            collector.lines.contains(where: { $0.text.contains("could not create backups directory") }),
            "expected backups-directory error line; got: \(collector.lines.map(\.text))"
        )
    }

    /// When jamf-cli is absent the backup() path must throw `.executableNotFound`
    /// and emit an error line. Skipped when jamf-cli is installed.
    func test_backup_emitsErrorWhenJamfCLIMissing() async throws {
        guard ExecutableLocator.locate("jamf-cli") == nil else {
            throw XCTSkip("jamf-cli is installed — cannot test the not-found path")
        }
        let bridge = CLIBridge()
        let collector = LineCollector()
        do {
            _ = try await bridge.backup(profile: "test-profile", label: nil) { line in
                collector.append(line)
            }
            XCTFail("backup must throw when jamf-cli is absent")
        } catch let e as CLIBridgeError {
            XCTAssertEqual(e, .executableNotFound,
                           "backup must throw .executableNotFound when jamf-cli is absent")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertFalse(collector.lines.isEmpty, "backup must emit at least one log line when jamf-cli is absent")
    }
}

// MARK: - LineCollector

private final class LineCollector: @unchecked Sendable {
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
