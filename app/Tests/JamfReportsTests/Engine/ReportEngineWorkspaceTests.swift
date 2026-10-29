import Foundation
import XCTest
@testable import JamfReports

/// The folders `ReportEngine.generate` reads and writes belong to the run's workspace. The
/// `jamf_cli.profile` in a shared workspace's config.yaml, which a peer can edit, names no folder.
final class ReportEngineWorkspaceTests: XCTestCase {

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: CLIBridge.LogLine) { lock.lock(); stored.append(line.text); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-run-profile-\(UUID().uuidString)", isDirectory: true)
        for name in ["shared", "victim"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        }
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func workspace(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    private func engine(namedProfile: String?, run: String? = "shared") throws -> ReportEngine {
        var yaml = "charts:\n  enabled: true\n  archive_current_csv: true\n"
            + "  historical_csv_dir: snapshots\n"
        if let namedProfile { yaml += "jamf_cli:\n  profile: \(namedProfile)\n" }
        let config = workspace("shared").appendingPathComponent("config.yaml")
        try yaml.write(to: config, atomically: true, encoding: .utf8)
        return ReportEngine(
            config: try ConfigLoader.load(from: config),
            dataDir: workspace("shared").appendingPathComponent("jamf-cli-data"),
            workspace: run.flatMap(WorkspaceID.init))
    }

    private func everything(under folder: URL) -> [String] {
        let walker = FileManager.default.enumerator(atPath: folder.path)
        return (walker?.allObjects as? [String] ?? []).sorted()
    }

    /// Before 2.12 this was refused (`profileMismatch`). The key no longer names the folder or
    /// the profile, so the run generates into its own workspace and leaves the other alone.
    func testAConfigNamingAnotherProfileGeneratesIntoTheRunsOwnFolders() async throws {
        for named in [nil, "shared", "victim"] {
            let engine = try engine(namedProfile: named)
            let out = workspace("shared").appendingPathComponent("Generated Reports/r.xlsx")
            try await engine.generate(outputURL: out, locateJamfCLI: { nil })
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "\(named ?? "blank")")
            XCTAssertFalse(everything(under: workspace("shared")).isEmpty)
            XCTAssertEqual(everything(under: workspace("victim")), [])
        }
    }

    /// An engine with no workspace resolves no workspace folder, even when config.yaml names one.
    func testAnEngineWithNoWorkspaceNeverWritesIntoTheFolderTheConfigNames() async throws {
        let engine = try engine(namedProfile: "victim", run: nil)
        let lines = Lines()
        let out = workspace("shared").appendingPathComponent("Generated Reports/r.xlsx")
        try await engine.generate(outputURL: out, locateJamfCLI: { nil }, onLine: lines.add)
        XCTAssertEqual(everything(under: workspace("victim")), [])
    }
}
