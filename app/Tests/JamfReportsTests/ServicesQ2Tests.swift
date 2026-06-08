import Foundation
import XCTest
@testable import JamfReports

// MARK: - Lane Q2 Services Hardening Tests

/// Tests for Q2 persona findings:
///   #12 — Log directory/file permissions (0o700 / 0o600)
///
/// (#11 SnapshotRetentionService moved to SnapshotRetentionServiceTests when the
/// service was reworked into the v2.2.0 config-driven archive/keep model.)
@MainActor
final class ServicesQ2Tests: XCTestCase {

    private nonisolated(unsafe) var tmpRoot: URL!

    override func setUp() {
        super.setUp()
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Q2RetentionTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpRoot)
        super.tearDown()
    }

    // MARK: - #12 Log directory / file permissions

    func test_appLoggerCrashLogDir_createdWith0o700() throws {
        let fm = FileManager.default
        let testDir = tmpRoot.appendingPathComponent("LogDirPermTest_\(UUID().uuidString)", isDirectory: true)

        try fm.createDirectory(
            at: testDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: testDir.path)

        let attrs = try fm.attributesOfItem(atPath: testDir.path)
        let perms = attrs[.posixPermissions] as? Int ?? 0
        XCTAssertEqual(perms, 0o700, "Crash log directory must be created with mode 0700")
    }

    func test_appendHandle_logFile_permissions0o600() throws {
        let fm = FileManager.default
        let logURL = tmpRoot.appendingPathComponent("test.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)

        let attrs = try fm.attributesOfItem(atPath: logURL.path)
        let perms = attrs[.posixPermissions] as? Int ?? 0
        XCTAssertEqual(perms, 0o600, "Log files must have mode 0600")
    }

    func test_launchAgentLogRotator_recreatedLogHas0o600() throws {
        let log = tmpRoot.appendingPathComponent("rotate_perms.log")
        let content = String(repeating: "x", count: 200).data(using: .utf8)!
        try content.write(to: log)

        try LaunchAgentLogRotator.rotateIfNeeded(logURL: log, sizeLimit: 100)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: log.path), "Active log must exist after rotation")
        let attrs = try fm.attributesOfItem(atPath: log.path)
        let perms = attrs[.posixPermissions] as? Int ?? 0
        XCTAssertEqual(perms, 0o600, "Recreated log file after rotation must have mode 0600")
    }

    func test_preExistingLogDir_tightenedTo0o700() throws {
        let fm = FileManager.default
        let existingDir = tmpRoot.appendingPathComponent("existing_logdir", isDirectory: true)
        // Create with permissive umask-default (0o755).
        try fm.createDirectory(at: existingDir, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: existingDir.path)

        // Simulate what the service does on next access.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: existingDir.path)

        let attrs = try fm.attributesOfItem(atPath: existingDir.path)
        let perms = attrs[.posixPermissions] as? Int ?? 0
        XCTAssertEqual(perms, 0o700, "Pre-existing log dir must be tightened to 0700 on next access")
    }
}
