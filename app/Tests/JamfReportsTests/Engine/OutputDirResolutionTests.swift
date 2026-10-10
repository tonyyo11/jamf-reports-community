import Foundation
import XCTest
@testable import JamfReports

/// The workbook generate writes lands in the folder the Reports library reads: `output_dir`
/// resolved by `WorkspacePaths.outputDir(for:)`, `~` expanded, `allow_absolute_paths` honoured.
final class OutputDirResolutionTests: XCTestCase {

    private let profile = "publish"

    func testAnAbsoluteOutputDirWithAllowAbsolutePathsReceivesTheWorkbook() async throws {
        try await withWorkspace { workspace, published in
            let written = try await generate(
                in: workspace, yaml: "output:\n  output_dir: \"\(published.path)\"\n"
                    + "  allow_absolute_paths: true\n")
            XCTAssertEqual(written.folder, published.standardizedFileURL.path)
            XCTAssertEqual(written.folder, try WorkspacePaths.outputDir(for: profile).path,
                           "the Reports library reads the same folder")
        }
    }

    func testATildeOutputDirIsExpanded() async throws {
        try await withWorkspace { workspace, published in
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let typed = "~" + published.path.dropFirst(home.count)
            let written = try await generate(
                in: workspace, yaml: "output:\n  output_dir: \"\(typed)\"\n"
                    + "  allow_absolute_paths: yes\n")
            XCTAssertEqual(written.folder, published.standardizedFileURL.path)
        }
    }

    func testAnAbsoluteOutputDirWithoutTheOptInFallsBackToGeneratedReports() async throws {
        try await withWorkspace { workspace, published in
            let lines = Lines()
            let written = try await generate(
                in: workspace, yaml: "output:\n  output_dir: \"\(published.path)\"\n",
                lines: lines)
            XCTAssertEqual(written.folder, workspace.appendingPathComponent("Generated Reports")
                .resolvingSymlinksInPath().standardizedFileURL.path)
            let warnings = lines.all.filter { $0.hasPrefix("[warn] output.output_dir") }
            XCTAssertEqual(warnings.count, 1, "\(lines.all)")
            XCTAssertTrue(warnings.first?.contains(
                "is outside the workspace and output.allow_absolute_paths is not true. Writing "
                    + "to Generated Reports in the workspace instead.") == true, "\(warnings)")
        }
    }

    func testAnOutputDirThatClimbsOutOfTheWorkspaceIsRefusedWithAWarning() async throws {
        try await withWorkspace { workspace, _ in
            let lines = Lines()
            let written = try await generate(
                in: workspace, yaml: "output:\n  output_dir: \"../elsewhere\"\n", lines: lines)
            XCTAssertEqual(written.folder, workspace.appendingPathComponent("Generated Reports")
                .resolvingSymlinksInPath().standardizedFileURL.path)
            XCTAssertEqual(lines.all.filter { $0.hasPrefix("[warn] output.output_dir") }, [
                "[warn] output.output_dir \"../elsewhere\" is not used: a relative path must "
                    + "stay inside the workspace. Writing to Generated Reports in the workspace "
                    + "instead.",
            ])
        }
    }

    func testASystemFolderIsRefusedEvenWithAllowAbsolutePaths() async throws {
        try await withWorkspace { workspace, _ in
            let lines = Lines()
            let written = try await generate(
                in: workspace, yaml: "output:\n  output_dir: \"/etc/jrc-reports\"\n"
                    + "  allow_absolute_paths: true\n", lines: lines)
            XCTAssertEqual(written.folder, workspace.appendingPathComponent("Generated Reports")
                .resolvingSymlinksInPath().standardizedFileURL.path)
            XCTAssertEqual(lines.all.filter { $0.hasPrefix("[warn] output.output_dir") }, [
                "[warn] output.output_dir \"/etc/jrc-reports\" is not used: that folder is "
                    + "reserved by macOS or holds credentials. Writing to Generated Reports in "
                    + "the workspace instead.",
            ])
        }
    }

    func testARelativeOutputDirIsUnchanged() async throws {
        try await withWorkspace { workspace, _ in
            let written = try await generate(
                in: workspace, yaml: "output:\n  output_dir: \"Team Reports/monthly\"\n")
            XCTAssertEqual(written.folder, workspace.appendingPathComponent("Team Reports/monthly")
                .resolvingSymlinksInPath().standardizedFileURL.path)
        }
    }

    // MARK: - Helpers

    private func generate(
        in workspace: URL, yaml: String, lines: Lines = Lines()
    ) async throws -> (folder: String, url: URL) {
        let configURL = workspace.appendingPathComponent("config.yaml")
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)
        let engine = ReportEngine(config: try ConfigLoader.load(from: configURL),
                                  dataDir: workspace.appendingPathComponent("jamf-cli-data"))
        let url = engine.resolveOutputURL(stem: "report", profile: profile,
                                          onLine: { lines.add($0.text) })
        try await engine.generate(csvURL: nil, outputURL: url, template: ComplianceTemplate(),
                                  locateJamfCLI: { nil })
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        return (url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path,
                url)
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// A workspaces root and a second folder, both under the home folder: the temp folder
    /// resolves under /private, which the path rules refuse even with the opt-in.
    private func withWorkspace(_ body: (URL, URL) async throws -> Void) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("jrc-test-output-\(UUID().uuidString)")
        let published = home.appendingPathComponent("jrc-test-published-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: published)
        }
        try await body(workspace, published)
    }
}

/// The GUI's HTML (and PDF) report goes to the folder the workbook goes to.
@MainActor
final class GUIReportFolderTests: XCTestCase {

    func testTheGUIHTMLReportGoesToTheAllowedOutputDir() async throws {
        try await withPublishWorkspace { workspace, published in
            let lines = try await generateHTML(
                in: workspace, yaml: "output:\n  output_dir: \"\(published.path)\"\n"
                    + "  allow_absolute_paths: true\n")
            XCTAssertEqual(try htmlFiles(in: published).count, 1, "\(lines)")
            XCTAssertTrue(lines.filter { $0.hasPrefix("[warn] output.output_dir") }.isEmpty)
        }
    }

    func testARefusedOutputDirSendsTheGUIHTMLReportToGeneratedReportsWithAWarning()
        async throws {
        try await withPublishWorkspace { workspace, published in
            let lines = try await generateHTML(
                in: workspace, yaml: "output:\n  output_dir: \"\(published.path)\"\n")
            XCTAssertEqual(try htmlFiles(in: workspace.appendingPathComponent(
                "Generated Reports")).count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: published.path))
            XCTAssertEqual(lines.filter { $0.hasPrefix("[warn] output.output_dir") }.count, 1,
                           "\(lines)")
        }
    }

    /// One Generate run writes several formats, each resolving the folder; the refused-folder
    /// warning is said once for the run (J9).
    func testARefusedOutputDirWarnsOncePerRunAcrossFormats() async throws {
        try await withPublishWorkspace { workspace, published in
            try "output:\n  output_dir: \"\(published.path)\"\n".write(
                to: workspace.appendingPathComponent("config.yaml"),
                atomically: true, encoding: .utf8)
            let lines = LineBox()
            _ = await CLIBridge().generateAll(
                types: [.html, .csv], outputDir: nil,
                profile: workspace.lastPathComponent, onLine: { lines.add($0.text) })
            XCTAssertEqual(lines.all.filter { $0.hasPrefix("[warn] output.output_dir") }.count, 1,
                           "\(lines.all)")
        }
    }

    // MARK: - Helpers

    private func generateHTML(in workspace: URL, yaml: String) async throws -> [String] {
        try yaml.write(to: workspace.appendingPathComponent("config.yaml"),
                       atomically: true, encoding: .utf8)
        let lines = LineBox()
        let result = await CLIBridge().generateAll(
            types: [.html], outputDir: nil,
            profile: workspace.lastPathComponent, onLine: { lines.add($0.text) })
        XCTAssertEqual(result.failed.count, 0, "\(lines.all)")
        return lines.all
    }

    private func htmlFiles(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".html") }
    }

    private final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// Both folders under ~: the temp folder resolves under /private, which the path rules
    /// refuse even with the opt-in.
    private func withPublishWorkspace(_ body: (URL, URL) async throws -> Void) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("jrc-test-gui-\(UUID().uuidString)")
        let published = home.appendingPathComponent("jrc-test-gui-out-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("gui", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: published)
        }
        try await body(workspace, published)
    }
}
