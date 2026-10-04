import Foundation
import XCTest
@testable import JamfReports

/// `retention.archive_dir` is resolved the way `output.archive_dir` is: inside the workspace,
/// or outside it only with `output.allow_absolute_paths`; anything else archives to `_archive`.
final class RetentionArchiveDirTests: XCTestCase {

    private let profile = "retention"

    func testARelativeArchiveDirThatClimbsOutOfTheWorkspaceArchivesToTheDefault() throws {
        try withWorkspace { root, workspace in
            let old = try oldSnapshot(in: workspace)
            try configure(workspace, archiveDir: "../outside")
            let lines = LineBox()

            SnapshotRetentionService.sweepIfDue(profile: profile, onLine: { lines.add($0.text) })

            XCTAssertEqual(lines.all.filter { $0.hasPrefix("[warn] retention.archive_dir") }, [
                "[warn] retention.archive_dir \"../outside\" is not used: a relative path must "
                    + "stay inside the workspace. Archiving to _archive in the workspace instead.",
            ])

            let outside = root.appendingPathComponent("outside")
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path),
                           "nothing is written beside the workspace")
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent(
                    "_archive/jamf-cli-data/computers/\(old.lastPathComponent)").path))
        }
    }

    func testAnArchiveDirInsideTheWorkspaceIsUsed() throws {
        try withWorkspace { _, workspace in
            for typed in ["old-snapshots", "nested/../kept", workspace.path + "/abs-inside"] {
                try configure(workspace, archiveDir: typed)
                let used = SnapshotRetentionService.resolvedArchiveRoot(
                    config: try config(workspace), workspace: workspace)
                XCTAssertTrue(used.resolvingSymlinksInPath().path.hasPrefix(
                    workspace.resolvingSymlinksInPath().path + "/"), typed)
                XCTAssertNotEqual(used.lastPathComponent, "_archive", typed)
            }
        }
    }

    func testAnAbsoluteArchiveDirOutsideTheWorkspaceNeedsAllowAbsolutePaths() throws {
        let outside = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jrc-test-retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try withWorkspace { root, workspace in
            let sibling = root.appendingPathComponent("shared-archive").path
            for typed in [outside.path, sibling] {
                try configure(workspace, archiveDir: typed)
                XCTAssertEqual(try usedPath(workspace), fallback(workspace),
                               "\(typed): outside the workspace without the opt-in")
            }
            try configure(workspace, archiveDir: outside.path, allowAbsolute: "yes")
            XCTAssertEqual(try usedPath(workspace), outside.standardizedFileURL.path)
        }
    }

    // MARK: - Helpers

    private final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private func usedPath(_ workspace: URL) throws -> String {
        SnapshotRetentionService.resolvedArchiveRoot(config: try config(workspace),
                                                     workspace: workspace)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func fallback(_ workspace: URL) -> String {
        workspace.appendingPathComponent("_archive").resolvingSymlinksInPath()
            .standardizedFileURL.path
    }

    private func config(_ workspace: URL) throws -> RetentionConfig? {
        try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml")).retention
    }

    private func configure(_ workspace: URL, archiveDir: String, allowAbsolute: String? = nil)
        throws {
        var yaml = "retention:\n  enabled: true\n  snapshot_keep_days: 30\n"
            + "  archive_dir: \"\(archiveDir)\"\n"
        if let allowAbsolute { yaml += "output:\n  allow_absolute_paths: \(allowAbsolute)\n" }
        try yaml.write(to: workspace.appendingPathComponent("config.yaml"),
                       atomically: true, encoding: .utf8)
    }

    private func oldSnapshot(in workspace: URL) throws -> URL {
        let dir = workspace.appendingPathComponent("jamf-cli-data/computers", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("computers_20250101T000000.json")
        try "[]".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -90 * 86_400)], ofItemAtPath: url.path)
        return url
    }

    /// Under the home folder, as `WorkspacePathsAbsoluteTests` does: the temp folder resolves
    /// under /private, which the path rules refuse for any absolute path.
    private func withWorkspace(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jrc-test-retention-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        try body(root, workspace)
    }
}
