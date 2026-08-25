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
