import XCTest
@testable import JamfReports

/// `/Users/Shared` and `~/Public` are refused only where the engine writes reports from
/// config: `output.output_dir`, `output.archive_dir` and `retention.archive_dir`. Even with
/// `allow_absolute_paths`. `jamf_cli.data_dir` is left alone so a workspace with data there
/// is not orphaned.
final class WorkspacePathsSharedFolderTests: XCTestCase {

    private let fileManager = FileManager.default
    private let profile = "sharedfolder"
    private let shared = "/Users/Shared/jrc-test-reports"

    private final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private func makeWorkspace(configBody: String) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        try configBody.write(to: workspace.appendingPathComponent("config.yaml"),
                             atomically: true, encoding: .utf8)
        return workspace
    }

    private func assertWorldReadable(_ body: @autoclosure () throws -> URL,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case WorkspacePaths.PathError.worldReadableFolder = error else {
                return XCTFail("expected worldReadableFolder, got \(error)", file: file, line: line)
            }
        }
    }

    func testOutputAndArchiveDirsRefuseTheSharedFoldersEvenWithTheOptIn() throws {
        let home = NSString(string: "~").expandingTildeInPath
        for typed in [shared, "\(home)/Public/jrc-test-reports"] {
            _ = try makeWorkspace(configBody: """
            output:
              allow_absolute_paths: true
              output_dir: "\(typed)"
              archive_dir: "\(typed)/archive"
            """)
            assertWorldReadable(try WorkspacePaths.outputDir(for: profile))
            assertWorldReadable(try WorkspacePaths.archiveDir(for: profile))
        }
    }

    func testOutputDirRefusesTmpEvenWithTheOptIn() throws {
        for path in ["/tmp/x", "/var/tmp/x", "/private/var/tmp/x"] {
            XCTAssertTrue(
                WorkspacePaths.isWorldReadableSharedFolder(URL(fileURLWithPath: path)), path)
        }
        _ = try makeWorkspace(configBody: """
        output:
          allow_absolute_paths: true
          output_dir: "/tmp/jrc-test-reports"
        """)
        assertWorldReadable(try WorkspacePaths.outputDir(for: profile))
    }

    func testRetentionArchiveDirRefusesTheSharedFolder() throws {
        let workspace = try makeWorkspace(configBody: """
        output:
          allow_absolute_paths: true
        retention:
          archive_dir: "\(shared)"
        """)
        let config = try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
        XCTAssertThrowsError(try SnapshotRetentionService.typedArchiveRoot(
            config: config.retention, workspace: workspace)) { error in
            guard case WorkspacePaths.PathError.worldReadableFolder = error else {
                return XCTFail("expected worldReadableFolder, got \(error)")
            }
        }
    }

    func testReportsDirFallsBackWithAWarnNamingTheRealCause() throws {
        let workspace = try makeWorkspace(configBody: """
        output:
          allow_absolute_paths: true
          output_dir: "\(shared)"
        """)
        let lines = LineBox()
        let dir = WorkspacePaths.reportsDir(for: profile, onLine: { lines.add($0.text) })
        XCTAssertEqual(dir?.lastPathComponent, WorkspacePaths.generatedReportsDirName)
        XCTAssertEqual(dir?.deletingLastPathComponent().resolvingSymlinksInPath().path,
                       workspace.resolvingSymlinksInPath().path)
        XCTAssertEqual(lines.all.count, 1)
        XCTAssertTrue(lines.all[0].contains("every account on this Mac can read it"), lines.all[0])
    }

    func testDataDirIsNotRefusedForTheSharedFolders() throws {
        _ = try makeWorkspace(configBody: """
        output:
          allow_absolute_paths: true
        jamf_cli:
          data_dir: "\(shared)"
        """)
        XCTAssertEqual(try WorkspacePaths.dataDir(for: profile).path, shared)
    }
}
