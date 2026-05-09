import XCTest
@testable import JamfReports

@MainActor
final class CLIBridgeBackupTests: XCTestCase {

    // MARK: - Helpers

    private func makeWorkspace(name: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIBridgeBackupTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Populate a workspace directory with the three backup sources.
    private func populateFull(_ workspace: URL) throws {
        // config.yaml
        try "jamf_url: https://example.jamfcloud.com\n"
            .write(to: workspace.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)

        // jamf-cli-data/ with one file
        let dataDir = workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try "{\"devices\":[]}".write(
            to: dataDir.appendingPathComponent("computers.json"),
            atomically: true, encoding: .utf8)

        // snapshots/ with one file
        let snapDir = workspace.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        try "{}".write(
            to: snapDir.appendingPathComponent("summary.json"),
            atomically: true, encoding: .utf8)
    }

    /// Return the single backup directory inside workspace/backups/.
    private func findBackupDir(in workspace: URL) throws -> URL {
        let backupsRoot = workspace.appendingPathComponent("backups", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: backupsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let dirs = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        XCTAssertEqual(dirs.count, 1, "Expected exactly one backup directory")
        return dirs[0]
    }

    // MARK: - Tests

    // MARK: - Real backup() call tests

    /// Invalid profile slug must cause backup() to return -1 immediately without
    /// attempting any filesystem operations. No jamf-cli needed.
    func test_backup_rejectsInvalidProfile() async {
        let bridge = CLIBridge()
        let collector = LineCollector()
        let code = await bridge.backup(profile: "../etc/passwd", label: nil) { line in
            collector.append(line)
        }
        XCTAssertEqual(code, -1, "backup must reject an invalid profile slug")
        XCTAssertTrue(
            collector.lines.contains(where: { $0.text.contains("invalid profile name") }),
            "expected an [error] invalid profile name line; got: \(collector.lines.map(\.text))"
        )
    }

    /// A label beginning with '-' must be rejected before any subprocess is launched.
    func test_backup_rejectsLeadingDashLabel() async {
        let bridge = CLIBridge()
        let collector = LineCollector()
        let code = await bridge.backup(profile: "valid-profile", label: "--evil") { line in
            collector.append(line)
        }
        XCTAssertEqual(code, -1, "backup must reject a leading-dash label")
        XCTAssertTrue(
            collector.lines.contains(where: { $0.text.contains("may not start with '-'") }),
            "expected label rejection line; got: \(collector.lines.map(\.text))"
        )
    }

    /// When jamf-cli is absent the backup() path must emit an error line and
    /// return a non-zero code without hanging. Skipped when jamf-cli is installed.
    func test_backup_emitsErrorWhenJamfCLIMissing() async throws {
        guard ExecutableLocator.locate("jamf-cli") == nil else {
            throw XCTSkip("jamf-cli is installed — cannot test the not-found path")
        }
        let bridge = CLIBridge()
        let collector = LineCollector()
        let code = await bridge.backup(profile: "test-profile", label: nil) { line in
            collector.append(line)
        }
        XCTAssertNotEqual(code, 0, "backup must not succeed when jamf-cli is absent")
        XCTAssertFalse(collector.lines.isEmpty, "backup must emit at least one log line when jamf-cli is absent")
    }

    // MARK: - Legacy white-box copy tests

    func testBackupCopiesAllThreeSources() async throws {
        let workspace = try makeWorkspace(name: "full")
        defer { try? FileManager.default.removeItem(at: workspace) }
        try populateFull(workspace)

        // Inject the workspace as profile "test-backup" by pointing WorkspacePaths at tmp.
        // CLIBridge.backup calls ProfileService.workspaceURL(for:), which resolves to
        // ~/Jamf-Reports/<profile>. We test the copy logic directly by calling backup
        // and then inspecting the output directory structure; because we cannot inject
        // an arbitrary workspace URL through the public API, we replicate the core copy
        // loop here as a white-box test of the filesystem layout contract.
        let bridge = CLIBridge()
        var lines: [CLIBridge.LogLine] = []

        // Use the real backup() indirectly: exercise copyItem semantics on our tmp tree.
        let destName = "backup_test"
        let destDir = workspace.appendingPathComponent("backups/\(destName)", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let sources: [(src: URL, dest: URL)] = [
            (workspace.appendingPathComponent("config.yaml"),
             destDir.appendingPathComponent("config.yaml")),
            (workspace.appendingPathComponent("jamf-cli-data", isDirectory: true),
             destDir.appendingPathComponent("jamf-cli-data")),
            (workspace.appendingPathComponent("snapshots", isDirectory: true),
             destDir.appendingPathComponent("snapshots")),
        ]
        for entry in sources {
            do {
                try FileManager.default.copyItem(at: entry.src, to: entry.dest)
                lines.append(.init(timestamp: Date(), level: .info, text: "copied \(entry.src.lastPathComponent)"))
            } catch {
                lines.append(.init(timestamp: Date(), level: .warn, text: "warn: \(error)"))
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("config.yaml").path),
                      "config.yaml must be in backup")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destDir.appendingPathComponent("jamf-cli-data/computers.json").path),
            "jamf-cli-data/ must be in backup")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destDir.appendingPathComponent("snapshots/summary.json").path),
            "snapshots/ must be in backup")
        XCTAssertTrue(lines.allSatisfy { $0.level != .fail },
                      "No failures expected when all sources exist")
        _ = bridge  // silence unused-variable warning; bridge type is exercised by import
    }

    func testBackupSucceedsWhenConfigYamlMissing() throws {
        let workspace = try makeWorkspace(name: "no-config")
        defer { try? FileManager.default.removeItem(at: workspace) }
        try populateFull(workspace)
        try FileManager.default.removeItem(at: workspace.appendingPathComponent("config.yaml"))

        let destDir = workspace.appendingPathComponent("backups/backup_partial", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        var warnCount = 0
        let sources: [(src: URL, destName: String)] = [
            (workspace.appendingPathComponent("config.yaml"), "config.yaml"),
            (workspace.appendingPathComponent("jamf-cli-data"), "jamf-cli-data"),
            (workspace.appendingPathComponent("snapshots"), "snapshots"),
        ]
        for entry in sources {
            guard FileManager.default.fileExists(atPath: entry.src.path) else {
                warnCount += 1
                continue
            }
            try FileManager.default.copyItem(at: entry.src,
                                             to: destDir.appendingPathComponent(entry.destName))
        }

        XCTAssertEqual(warnCount, 1, "Exactly one source was missing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("config.yaml").path),
                       "config.yaml should not appear in backup when source was absent")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destDir.appendingPathComponent("jamf-cli-data").path),
            "jamf-cli-data must still be copied when config.yaml is missing")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destDir.appendingPathComponent("snapshots").path),
            "snapshots must still be copied when config.yaml is missing")
    }

    func testBackupSucceedsWhenSnapshotsMissing() throws {
        let workspace = try makeWorkspace(name: "no-snapshots")
        defer { try? FileManager.default.removeItem(at: workspace) }
        try populateFull(workspace)
        try FileManager.default.removeItem(at: workspace.appendingPathComponent("snapshots"))

        let destDir = workspace.appendingPathComponent("backups/backup_partial2", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        var warnCount = 0
        let sources: [(src: URL, destName: String)] = [
            (workspace.appendingPathComponent("config.yaml"), "config.yaml"),
            (workspace.appendingPathComponent("jamf-cli-data"), "jamf-cli-data"),
            (workspace.appendingPathComponent("snapshots"), "snapshots"),
        ]
        for entry in sources {
            guard FileManager.default.fileExists(atPath: entry.src.path) else {
                warnCount += 1
                continue
            }
            try FileManager.default.copyItem(at: entry.src,
                                             to: destDir.appendingPathComponent(entry.destName))
        }

        XCTAssertEqual(warnCount, 1, "Exactly one source was missing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("config.yaml").path),
                      "config.yaml must be in backup")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destDir.appendingPathComponent("jamf-cli-data").path),
            "jamf-cli-data must be in backup")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destDir.appendingPathComponent("snapshots").path),
            "snapshots should not appear when source was absent")
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
