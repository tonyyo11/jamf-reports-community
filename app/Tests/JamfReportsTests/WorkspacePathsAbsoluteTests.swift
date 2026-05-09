import XCTest
@testable import JamfReports

/// Track B Wave 2 — B-05 default-deny absolute paths in WorkspacePaths.
///
/// Previously, any absolute path (e.g. `/Volumes/Share/...`,
/// `/Users/<other>/Public/...`) outside the workspace was accepted as long
/// as it didn't match the dotfile/system blocklist. Now absolute paths
/// outside the workspace are refused unless the workspace's `config.yaml`
/// opts in via `output.allow_absolute_paths: true`. Sensitive locations
/// remain refused even with the opt-in.
final class WorkspacePathsAbsoluteTests: XCTestCase {

    private let fileManager = FileManager.default

    private func makeWorkspace(profile: String, configBody: String) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config = workspace.appendingPathComponent("config.yaml")
        try configBody.write(to: config, atomically: true, encoding: .utf8)
        return workspace
    }

    func test_absolutePath_rejectedByDefault() throws {
        // Place the "outside" target under the user's home so it is not
        // rejected by `isSensitiveAbsolutePath` (which denies /var, /tmp,
        // and other system roots, including the macOS temp dir which
        // canonicalizes under /private/var).
        let outside = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".jrc-test-outside-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }

        let body = """
        output:
          output_dir: \(outside.path)
        """
        _ = try makeWorkspace(profile: "absdefault", configBody: body)

        XCTAssertThrowsError(try WorkspacePaths.outputDir(for: "absdefault")) { error in
            guard case WorkspacePaths.PathError.disallowedAbsolutePath = error else {
                return XCTFail("expected disallowedAbsolutePath, got \(error)")
            }
        }
    }

    func test_absolutePath_acceptedWithOptIn() throws {
        // Place the "outside" target under the user's home so it is not
        // rejected by `isSensitiveAbsolutePath` (which denies /var, /tmp,
        // and other system roots, including the macOS temp dir which
        // canonicalizes under /private/var).
        let outside = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".jrc-test-outside-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }

        let body = """
        output:
          output_dir: \(outside.path)
          allow_absolute_paths: true
        """
        _ = try makeWorkspace(profile: "absoptin", configBody: body)

        let resolved = try WorkspacePaths.outputDir(for: "absoptin")
        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            outside.standardizedFileURL.path
        )
    }

    func test_sensitivePath_rejectedEvenWithOptIn() throws {
        let body = """
        output:
          output_dir: /etc/passwd
          allow_absolute_paths: true
        """
        _ = try makeWorkspace(profile: "abssensitive", configBody: body)

        XCTAssertThrowsError(try WorkspacePaths.outputDir(for: "abssensitive")) { error in
            guard case WorkspacePaths.PathError.disallowedAbsolutePath = error else {
                return XCTFail("expected disallowedAbsolutePath, got \(error)")
            }
        }
    }
}
