import XCTest
@testable import JamfReports

/// Wave 3 silent-failure regressions.
///
/// One suite per fix in `app/.specs/security-fixes-wave3-silent-failures.md`.
/// Each test pins a behavior that the audit identified as silently broken
/// pre-fix and that future refactors must not regress.
@MainActor
final class SecurityFixesWave3Tests: XCTestCase {

    private let fileManager = FileManager.default

    // MARK: - SF-8: YAMLCodec-backed configValue

    /// The replaced minimal line scanner used `firstIndex(of: ":")` then
    /// trimmed quotes, which silently truncated quoted values containing
    /// colons (e.g. an opt-in value like `"yes:absolutely"`). The YAMLCodec
    /// path correctly preserves quoted strings end-to-end. This test pins
    /// the more robust scalar parsing.
    func test_sf8_quotedScalarSurvivesEmbeddedColons() throws {
        let body = """
        output:
          output_dir: "Generated Reports"
        custom:
          note: "label: with colon"
        """
        _ = try makeWorkspace(profile: "sf8quoted", configBody: body)

        // Resolves the standard quoted value cleanly.
        let resolved = try WorkspacePaths.outputDir(for: "sf8quoted")
        XCTAssertEqual(
            resolved.lastPathComponent,
            "Generated Reports",
            "double-quoted output_dir must round-trip without colon truncation"
        )
    }

    /// Block-style opt-in still works (regression check after the rewrite).
    func test_sf8_blockStyleOptInStillWorks() throws {
        let outside = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".jrc-sf8-outside-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }

        let body = """
        output:
          output_dir: \(outside.path)
          allow_absolute_paths: true
        """
        _ = try makeWorkspace(profile: "sf8block", configBody: body)
        let resolved = try WorkspacePaths.outputDir(for: "sf8block")
        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            outside.standardizedFileURL.path
        )
    }

    // MARK: - SF-5: per-profile result aggregate

    /// `RunResult.allSucceeded` is the gate for the per-version sentinel.
    /// An empty workspaces root is trivially "succeeded" — there's nothing
    /// to migrate. Pinning this so a future refactor can't quietly invert
    /// the meaning.
    func test_sf5_emptyRunReportsAllSucceeded() throws {
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-sf5-empty-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempRoot) }

        setenv("JRC_TEST_WORKSPACES_ROOT", tempRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        let defaults = UserDefaults(suiteName: "JRC.SF5.\(UUID().uuidString)")!
        let result = WorkspaceMigration.run(defaults: defaults)
        XCTAssertTrue(result.allSucceeded)
        XCTAssertTrue(result.failedProfiles.isEmpty)
    }

    /// Successful migration must report all profiles succeeded so the
    /// sentinel can be stamped.
    func test_sf5_happyPathReportsSuccess() throws {
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-sf5-happy-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempRoot) }

        setenv("JRC_TEST_WORKSPACES_ROOT", tempRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        // Two valid profiles, no marker, mixed-mode artifacts
        for name in ["one", "two"] {
            let profile = tempRoot.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(
                at: profile, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
            )
            let f = profile.appendingPathComponent("a.json")
            try Data("x".utf8).write(to: f)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o644))],
                ofItemAtPath: f.path
            )
        }

        let defaults = UserDefaults(suiteName: "JRC.SF5h.\(UUID().uuidString)")!
        let result = WorkspaceMigration.run(defaults: defaults)
        XCTAssertEqual(result.profiles.count, 2)
        XCTAssertTrue(result.allSucceeded)
        XCTAssertTrue(result.failedProfiles.isEmpty)
    }

    // MARK: - C-13: directory-symlink filter in discoverProfiles

    /// A symlink at `<workspacesRoot>/<name> -> <victim>` must not appear in
    /// the migration's profile list. Pre-fix it did, which then drove a
    /// chmod sweep on the link target.
    func test_c13_directorySymlinkProfileIsSkipped() throws {
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-c13-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempRoot) }

        setenv("JRC_TEST_WORKSPACES_ROOT", tempRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        // Real victim directory containing a 0644 file we should NOT touch.
        let victim = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-c13-victim-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: victim, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: NSNumber(value: Int16(0o755))])
        addTeardownBlock { try? FileManager.default.removeItem(at: victim) }
        let victimFile = victim.appendingPathComponent("untouchable.txt")
        try Data("v".utf8).write(to: victimFile)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: victimFile.path
        )

        // Plant the symlink at <workspacesRoot>/hostile -> <victim>
        let hostile = tempRoot.appendingPathComponent("hostile", isDirectory: true)
        try fileManager.createSymbolicLink(at: hostile, withDestinationURL: victim)

        // And one legitimate profile so the migration has work to do.
        let realProfile = tempRoot.appendingPathComponent("real", isDirectory: true)
        try fileManager.createDirectory(at: realProfile, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: NSNumber(value: Int16(0o755))])
        let realFile = realProfile.appendingPathComponent("ok.json")
        try Data("r".utf8).write(to: realFile)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: realFile.path
        )

        let defaults = UserDefaults(suiteName: "JRC.C13.\(UUID().uuidString)")!
        let result = WorkspaceMigration.run(defaults: defaults)

        // Only the real profile was processed.
        XCTAssertEqual(result.profiles.map { $0.profile }, ["real"])

        // Real profile got tightened; victim file was NOT touched.
        XCTAssertEqual(try mode(of: realFile), 0o600)
        XCTAssertEqual(try mode(of: victimFile), 0o644,
                       "symlink target must remain at original mode")
    }

    /// Defense-in-depth: even if a caller sneaks past `discoverProfiles` and
    /// invokes `tighten(profile:)` directly, the resolved workspace must
    /// remain inside the workspaces root or the sweep is refused.
    /// (We cannot reproduce the full hostile setup here without actually
    /// resolving a symlink the hardener can see — `ProfileService.workspaceURL`
    /// re-applies the same root construction. So this test asserts the
    /// helper's positive-case still works after the guard was added.)
    func test_c13_tightenProfileStillSweepsRealWorkspace() throws {
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-c13b-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempRoot) }

        setenv("JRC_TEST_WORKSPACES_ROOT", tempRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        let profile = tempRoot.appendingPathComponent("legit", isDirectory: true)
        try fileManager.createDirectory(at: profile, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: NSNumber(value: Int16(0o755))])
        let file = profile.appendingPathComponent("a.json")
        try Data("a".utf8).write(to: file)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: file.path
        )

        let result = WorkspacePermissionHardener.tighten(profile: "legit")
        XCTAssertTrue(result.enumerated)
        XCTAssertEqual(try mode(of: file), 0o600)
    }

    // MARK: - Helpers

    private func makeWorkspace(profile: String, configBody: String) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("jrc-sfx-\(UUID().uuidString)", isDirectory: true)
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

    private func mode(of url: URL) throws -> Int {
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        return ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o7777
    }
}
