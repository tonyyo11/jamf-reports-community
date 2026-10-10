import XCTest
@testable import JamfReports

/// Retention on a folder several Macs write to. The rule that matters: we only
/// ever delete a backup we can prove this machine made.
final class BackupMaintenanceHostScopeTests: XCTestCase {

    private var root: URL!
    private let profile = "backupscope"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-BackupScope-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile).appendingPathComponent("backups"),
            withIntermediateDirectories: true
        )
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var backupsDir: URL {
        ProfileService.workspaceURL(for: profile)!.appendingPathComponent("backups")
    }

    @discardableResult
    private func makeBackup(_ name: String, owner: String?) throws -> URL {
        let dir = backupsDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"label":"scheduled-20260825"}"#
            .write(to: dir.appendingPathComponent("manifest.json"),
                   atomically: true, encoding: .utf8)
        if let owner {
            try owner.write(to: dir.appendingPathComponent(BackupMaintenance.ownerStampName),
                            atomically: true, encoding: .utf8)
        }
        return dir
    }

    func testOwnershipStampRoundTrips() throws {
        let dir = try makeBackup("20260825T010000", owner: nil)
        XCTAssertNil(BackupMaintenance.ownerHostID(of: dir))
        BackupMaintenance.stampOwnership(of: dir)
        XCTAssertEqual(
            BackupMaintenance.ownerHostID(of: dir), SharedWorkspace.currentHost.id
        )
    }

    func testUnstampedBackupHasNoOwner() throws {
        let dir = try makeBackup("20260825T020000", owner: "   \n")
        XCTAssertNil(
            BackupMaintenance.ownerHostID(of: dir),
            "a blank stamp is no stamp — it must not read as a real host"
        )
    }

    /// On local storage nothing changes: a single-Mac install that has never
    /// stamped a backup must keep pruning exactly as it did before.
    func testLocalStoragePrunesUnstampedBackups() throws {
        for hour in 1...5 {
            try makeBackup(String(format: "20260825T0%d0000", hour), owner: nil)
        }
        BackupMaintenance.pruneScheduledBackups(profile: profile, keep: 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: backupsDir.path)
        XCTAssertEqual(left.count, 2, "local retention must not depend on ownership stamps")
        XCTAssertTrue(left.contains("20260825T050000"), "the newest must survive")
    }

    /// The stamp is what makes the newest-backup attribution work after a run.
    func testStampNewestPicksTheLatestByName() throws {
        try makeBackup("20260825T010000", owner: nil)
        try makeBackup("20260825T090000", owner: nil)
        try makeBackup("20260825T050000", owner: nil)
        BackupMaintenance.stampNewestScheduledBackup(profile: profile)

        XCTAssertEqual(
            BackupMaintenance.ownerHostID(
                of: backupsDir.appendingPathComponent("20260825T090000")
            ),
            SharedWorkspace.currentHost.id
        )
        XCTAssertNil(
            BackupMaintenance.ownerHostID(
                of: backupsDir.appendingPathComponent("20260825T050000")
            ),
            "only the backup that just finished is ours to claim"
        )
    }

    // MARK: - Synced-volume pruning

    /// Redirects `JRC_TEST_WORKSPACES_ROOT` at a path shaped like a provider mount
    /// (`<home>/Library/CloudStorage/<Provider>/...`) under the temporary folder, so
    /// `CloudStorage.provider(for:)`, which matches `/Library/CloudStorage/` anywhere in a path,
    /// recognizes it and `pruneScheduledBackups` takes the host-scoped branch. Nothing is made
    /// in the real `~/Library/CloudStorage`.
    @discardableResult
    private func makeSyncedWorkspaceRoot() throws -> URL {
        let cloudRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-backupscope-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = cloudRoot
            .appendingPathComponent("Library/CloudStorage/OneDrive-JRCTest/Jamf-Reports",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile).appendingPathComponent("backups"),
            withIntermediateDirectories: true
        )
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: cloudRoot) }
        return workspacesRoot
    }

    /// On a folder shared by several Macs, retention must only ever spend this
    /// machine's `keep` budget on backups it can prove it made.
    func testSyncedProviderPrunesOnlyThisMachinesScheduledBackups() throws {
        try makeSyncedWorkspaceRoot()
        try makeBackup("20260825T010000", owner: SharedWorkspace.currentHost.id)
        try makeBackup("20260825T020000", owner: "some-other-host-abc123")
        try makeBackup("20260825T030000", owner: nil)

        BackupMaintenance.pruneScheduledBackups(profile: profile, keep: 0)

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: backupsDir.path))
        XCTAssertFalse(remaining.contains("20260825T010000"), "our own backup is prunable")
        XCTAssertTrue(remaining.contains("20260825T020000"), "another host's backup must survive")
        XCTAssertTrue(remaining.contains("20260825T030000"), "an unstamped backup must survive")
    }

    /// An unparseable name among candidates already scoped to this machine
    /// must still abort the whole prune — ownership scoping narrows WHICH
    /// backups are considered, not the safety rule for ordering them.
    func testSyncedProviderAbortsWholePruneWhenOwnBackupNameIsUnparseable() throws {
        try makeSyncedWorkspaceRoot()
        let mine = SharedWorkspace.currentHost.id
        try makeBackup("20260825T010000", owner: mine)
        // A OneDrive conflict-copy name — still ours, but not orderable.
        try makeBackup("20260825T010000 2", owner: mine)
        try makeBackup("20260825T020000", owner: "some-other-host-abc123")

        BackupMaintenance.pruneScheduledBackups(profile: profile, keep: 0)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: backupsDir.path)
        XCTAssertEqual(remaining.count, 3, "ambiguous ordering must abort the whole prune")
    }

    // MARK: - Shared storage the path alone does not reveal

    private func seedMixedOwnerBackups() throws {
        try makeBackup("20260825T010000", owner: SharedWorkspace.currentHost.id)
        try makeBackup("20260825T020000", owner: "some-other-host-abc123")
        try makeBackup("20260825T030000", owner: nil)
    }

    private func assertOnlyOwnBackupPruned(
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: backupsDir.path))
        XCTAssertFalse(remaining.contains("20260825T010000"), "our own is prunable",
                       file: file, line: line)
        XCTAssertTrue(remaining.contains("20260825T020000"), "another host's survives",
                      file: file, line: line)
        XCTAssertTrue(remaining.contains("20260825T030000"), "an unstamped one survives",
                      file: file, line: line)
    }

    /// An NFS or autofs mount outside `/Volumes` looks local by path.
    func testANonLocalVolumeIsScopedToThisMachine() throws {
        try seedMixedOwnerBackups()
        BackupMaintenance.pruneScheduledBackups(
            profile: profile, keep: 0, volumeIsLocal: { _ in false })
        try assertOnlyOwnBackupPruned()
    }

    func testSharedWorkspaceEnabledInConfigYamlIsRead() throws {
        try seedMixedOwnerBackups()
        try "shared_workspace:\n  enabled: true\n".write(
            to: ProfileService.workspaceURL(for: profile)!.appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)
        BackupMaintenance.pruneScheduledBackups(profile: profile, keep: 0)
        try assertOnlyOwnBackupPruned()
    }

    /// Unreadable bytes make `ConfigLoader.load` throw. The file may well say `enabled: true`,
    /// so the prune stays scoped to this Mac rather than risk another Mac's backups.
    func testAConfigThatExistsButWillNotLoadReadsAsShared() throws {
        try seedMixedOwnerBackups()
        try Data([0xFF, 0xFE, 0xFD, 0x00]).write(
            to: ProfileService.workspaceURL(for: profile)!.appendingPathComponent("config.yaml"))
        BackupMaintenance.pruneScheduledBackups(profile: profile, keep: 0)
        try assertOnlyOwnBackupPruned()
    }

    func testAMissingConfigIsNotShared() throws {
        try seedMixedOwnerBackups()
        BackupMaintenance.pruneScheduledBackups(profile: profile, keep: 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backupsDir.path), [])
    }

    func testLocalStorageNotMarkedSharedStillPrunesEverything() throws {
        try seedMixedOwnerBackups()
        try "shared_workspace:\n  enabled: false\n".write(
            to: ProfileService.workspaceURL(for: profile)!.appendingPathComponent("config.yaml"),
            atomically: true, encoding: .utf8)
        BackupMaintenance.pruneScheduledBackups(profile: profile, keep: 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backupsDir.path), [])
    }

    func testStagingDirsOnSharedStorageAreNotSweptWhateverThePath() throws {
        let stale = backupsDir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: stale.path)

        XCTAssertEqual(
            BackupMaintenance.cleanStaleTempDirs(profile: profile, volumeIsLocal: { _ in false }),
            [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(BackupMaintenance.cleanStaleTempDirs(profile: profile).count, 1)
    }

    /// Ordering is by folder name, never mtime — the whole reason this is safe
    /// on a volume where a sync provider rewrites modification dates.
    func testNewestIsChosenByNameNotModificationDate() throws {
        let older = try makeBackup("20260825T010000", owner: nil)
        try makeBackup("20260825T090000", owner: nil)
        // Make the OLDER folder look freshly modified, as a provider would.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: older.path
        )
        BackupMaintenance.stampNewestScheduledBackup(profile: profile)
        XCTAssertNil(
            BackupMaintenance.ownerHostID(of: older),
            "a re-stamped mtime must not make an old backup look like the newest"
        )
    }
}
