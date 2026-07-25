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

    // MARK: - Final-directory name collision (#213)

    /// A free name is returned verbatim — BackupsView and BackupMaintenance read
    /// these directories, so the normal-case format must not change.
    func test_uniqueBackupDirectoryName_returnsBaseWhenFree() throws {
        let dir = try makeTempDir()
        XCTAssertEqual(
            CLIBridge.uniqueBackupDirectoryName(base: "20260725T120000", in: dir),
            "20260725T120000"
        )
    }

    /// Two backups finishing inside the same second produce the same 1-second
    /// timestamp. Without uniquifying, `moveItem` throws EEXIST and the catch
    /// deletes the just-completed staging dir — a good backup lost as a "failure".
    func test_uniqueBackupDirectoryName_appendsSuffixOnCollision() throws {
        let dir = try makeTempDir()
        let base = "20260725T120000"
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(base, isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(
            CLIBridge.uniqueBackupDirectoryName(base: base, in: dir),
            "\(base)-2"
        )
    }

    /// Suffixes keep counting when earlier ones are taken.
    func test_uniqueBackupDirectoryName_walksPastTakenSuffixes() throws {
        let dir = try makeTempDir()
        let base = "20260725T120000"
        for name in [base, "\(base)-2", "\(base)-3"] {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        XCTAssertEqual(
            CLIBridge.uniqueBackupDirectoryName(base: base, in: dir),
            "\(base)-4"
        )
    }

    // MARK: - Backup's path guard must use the UNRESOLVED root

    /// Pins why `backup()` passes the raw `ProfileService.workspaceURL` to
    /// `WorkspacePathGuard.validate`, while every other caller passes the resolved
    /// `WorkspacePathGuard.root(for:)`.
    ///
    /// `resolvingSymlinksInPath()` follows symlinks only for a path that fully
    /// exists; for a path that does not exist yet it returns the path with its
    /// symlinks intact. Backup validates two directories it is about to CREATE, so
    /// its candidates stay unresolved — and comparing an unresolved candidate to a
    /// RESOLVED root fails on any workspace behind a symlink (iCloud / OneDrive /
    /// SharePoint, an external volume, a symlinked home).
    ///
    /// This was briefly "fixed" the wrong way round while investigating #213, which
    /// would have broken backup on exactly those workspaces. The two assertions
    /// below fail if anyone inverts it again.
    func test_pathGuardAcceptsNotYetCreatedPathUnderSymlinkedWorkspace() throws {
        let container = try makeTempDir()
        let realRoot = container.appendingPathComponent("real-root", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        let linkedRoot = container.appendingPathComponent("linked-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)

        setenv("JRC_TEST_WORKSPACES_ROOT", linkedRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        let profile = "backup-symlink-\(UUID().uuidString.prefix(8).lowercased())"
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        // Same shape as backup()'s staging dir: <workspace>/backups/.tmp-<uuid>
        let candidate = workspace
            .appendingPathComponent("backups", isDirectory: true)
            .appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)

        // What backup() actually does — and must keep doing.
        XCTAssertNotNil(
            WorkspacePathGuard.validate(candidate, under: workspace),
            "the UNRESOLVED root must accept a not-yet-created path inside the "
                + "workspace — this is what backup() relies on"
        )

        // The inverse, which reads like the safer choice and is not: a resolved
        // root cannot match a candidate that Foundation left unresolved.
        let resolvedRoot = try XCTUnwrap(WorkspacePathGuard.root(for: profile))
        XCTAssertNil(
            WorkspacePathGuard.validate(candidate, under: resolvedRoot),
            "a RESOLVED root rejects the not-yet-created path — switching backup() "
                + "to root(for:) would break every symlinked workspace"
        )

        // The rule itself: resolution depends on the path existing.
        let existing = workspace.appendingPathComponent("already-there", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        XCTAssertFalse(
            existing.resolvingSymlinksInPath().path.contains("linked-root"),
            "an existing path resolves through the symlink"
        )
        XCTAssertTrue(
            candidate.resolvingSymlinksInPath().path.contains("linked-root"),
            "a not-yet-created path keeps its symlinks"
        )
    }

    // MARK: - jamf-cli profile resolution for -p

    /// No config.yaml — fall back to the workspace slug (today's behavior).
    func test_resolvedCLIProfile_fallsBackToSlugWithoutConfig() throws {
        let profile = try makeWorkspace(configYAML: nil)
        XCTAssertEqual(CLIBridge.resolvedCLIProfile(forWorkspace: profile), profile)
    }

    /// A hand-edited multi-tenant config points `jamf_cli.profile` somewhere other
    /// than the workspace slug; `-p` must follow the config, not the slug.
    func test_resolvedCLIProfile_usesConfiguredProfile() throws {
        let profile = try makeWorkspace(configYAML: "jamf_cli:\n  profile: \"tenant-b\"\n")
        XCTAssertEqual(CLIBridge.resolvedCLIProfile(forWorkspace: profile), "tenant-b")
    }

    /// An empty value must not become `-p ""`.
    func test_resolvedCLIProfile_fallsBackWhenConfiguredProfileEmpty() throws {
        let profile = try makeWorkspace(configYAML: "jamf_cli:\n  profile: \"\"\n")
        XCTAssertEqual(CLIBridge.resolvedCLIProfile(forWorkspace: profile), profile)
    }

    /// A leading-dash value would be re-read by jamf-cli as a flag.
    func test_resolvedCLIProfile_fallsBackOnLeadingDashProfile() throws {
        let profile = try makeWorkspace(configYAML: "jamf_cli:\n  profile: \"--output\"\n")
        XCTAssertEqual(CLIBridge.resolvedCLIProfile(forWorkspace: profile), profile)
    }

    // MARK: - Helpers

    /// Creates a temp workspaces root, points `JRC_TEST_WORKSPACES_ROOT` at it,
    /// and returns the profile slug of a workspace containing `configYAML`
    /// (no config.yaml written when nil).
    private func makeWorkspace(configYAML: String?) throws -> String {
        let root = try makeTempDir()
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        let profile = "backup-cliprofile-\(UUID().uuidString.prefix(8).lowercased())"
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        if let configYAML {
            try configYAML.write(
                to: workspace.appendingPathComponent("config.yaml"),
                atomically: true,
                encoding: .utf8
            )
        }
        return profile
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIBridgeBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
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
