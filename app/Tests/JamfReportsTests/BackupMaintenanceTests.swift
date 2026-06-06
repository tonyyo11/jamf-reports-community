import XCTest
@testable import JamfReports

/// BackupMaintenance: scheduled-backup retention + abandoned staging cleanup.
/// Production accumulated a months-old `.tmp-*` dir from an interrupted backup.
final class BackupMaintenanceTests: XCTestCase {

    private var profile = ""
    private var backupsRoot: URL!

    override func setUpWithError() throws {
        profile = "bktest\(Int.random(in: 10_000...99_999))"
        guard let root = WorkspacePathGuard.root(for: profile) else {
            throw XCTSkip("workspace root unavailable for test profile")
        }
        backupsRoot = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
        let rootCopy = root
        addTeardownBlock { try? FileManager.default.removeItem(at: rootCopy) }
    }

    private func makeBackup(name: String, label: String, age: TimeInterval) throws {
        let dir = backupsRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["label": label, "created_at": "2026-06-01T00:00:00Z"]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: dir.appendingPathComponent("manifest.json"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: dir.path
        )
    }

    // MARK: - RunMode

    func testBackupRunModeRoundTripsRawValue() {
        XCTAssertEqual(Schedule.RunMode(rawValue: "backup"), .backup)
        XCTAssertEqual(Schedule.RunMode.backup.rawValue, "backup")
        XCTAssertTrue(Schedule.RunMode.allCases.contains(.backup))
        XCTAssertTrue(Schedule.RunMode.backup.defaultTiers.isEmpty, "backup never collects")
    }

    // MARK: - Retention

    func testPruneKeepsNewestScheduledAndAllManualBackups() throws {
        // 4 scheduled (oldest..newest) + 1 manual, keep 2 scheduled.
        try makeBackup(name: "20260501T010101", label: "scheduled-20260501", age: 4 * 86_400)
        try makeBackup(name: "20260502T010101", label: "scheduled-20260502", age: 3 * 86_400)
        try makeBackup(name: "20260503T010101", label: "scheduled-20260503", age: 2 * 86_400)
        try makeBackup(name: "20260504T010101", label: "scheduled-20260504", age: 1 * 86_400)
        try makeBackup(name: "20260430T010101", label: "pre-migration-keeper", age: 30 * 86_400)

        BackupMaintenance.pruneScheduledBackups(profile: profile, keep: 2)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: backupsRoot.path).sorted()
        XCTAssertTrue(remaining.contains("20260504T010101"), "newest scheduled kept")
        XCTAssertTrue(remaining.contains("20260503T010101"), "second-newest scheduled kept")
        XCTAssertFalse(remaining.contains("20260502T010101"), "older scheduled pruned")
        XCTAssertFalse(remaining.contains("20260501T010101"), "oldest scheduled pruned")
        XCTAssertTrue(
            remaining.contains("20260430T010101"),
            "manual backups are never pruned regardless of age"
        )
    }

    func testPruneNoOpsUnderKeepCount() throws {
        try makeBackup(name: "20260504T010101", label: "scheduled-20260504", age: 86_400)
        BackupMaintenance.pruneScheduledBackups(profile: profile, keep: 10)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: backupsRoot.path)
        XCTAssertEqual(remaining.count, 1)
    }

    // MARK: - Stale staging cleanup

    func testCleanStaleTempDirsRemovesOnlyOldStagingDirs() throws {
        // Old abandoned staging dir (the production case).
        let oldTemp = backupsRoot.appendingPathComponent(".tmp-OLD123", isDirectory: true)
        try FileManager.default.createDirectory(at: oldTemp, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)], ofItemAtPath: oldTemp.path
        )
        // In-flight staging dir (a backup running right now).
        let freshTemp = backupsRoot.appendingPathComponent(".tmp-FRESH456", isDirectory: true)
        try FileManager.default.createDirectory(at: freshTemp, withIntermediateDirectories: true)
        // A real backup (never touched).
        try makeBackup(name: "20260504T010101", label: "scheduled-20260504", age: 5 * 86_400)

        let removed = BackupMaintenance.cleanStaleTempDirs(profile: profile)

        XCTAssertEqual(removed, [".tmp-OLD123"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshTemp.path),
                      "in-flight staging dirs are left alone")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: backupsRoot.appendingPathComponent("20260504T010101").path
        ))
    }

    func testCleanStaleTempDirsNoOpsForMissingWorkspace() {
        XCTAssertEqual(
            BackupMaintenance.cleanStaleTempDirs(profile: "no-such-profile-xyz"), []
        )
    }

    func testDateStampFormat() {
        let stamp = BackupMaintenance.dateStamp(now: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(stamp.count, 8)
        XCTAssertTrue(stamp.allSatisfy(\.isNumber))
    }

    // MARK: - Post-success housekeeping (GUI/headless parity)

    /// `performPostSuccessHousekeeping` must prune scheduled backups beyond
    /// `keep` AND sweep abandoned `.tmp-*` dirs in a single call — the same
    /// operations `main.swift` and `CLIBridge+Run` both delegate to this helper.
    func testPerformPostSuccessHousekeepingPrunesAndSweeps() throws {
        // Two scheduled backups where keep=1 → oldest pruned.
        try makeBackup(name: "20260501T010101", label: "scheduled-20260501", age: 2 * 86_400)
        try makeBackup(name: "20260502T010101", label: "scheduled-20260502", age: 1 * 86_400)

        // Stale staging dir (>24 h old) — should be swept.
        let staleTemp = backupsRoot.appendingPathComponent(".tmp-STALE001", isDirectory: true)
        try FileManager.default.createDirectory(at: staleTemp, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -2 * 86_400)], ofItemAtPath: staleTemp.path
        )

        BackupMaintenance.performPostSuccessHousekeeping(profile: profile, keep: 1)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: backupsRoot.path).sorted()
        XCTAssertTrue(remaining.contains("20260502T010101"), "newest scheduled backup kept")
        XCTAssertFalse(remaining.contains("20260501T010101"), "older scheduled backup pruned")
        XCTAssertFalse(
            remaining.contains(".tmp-STALE001"),
            "stale staging dir swept by housekeeping"
        )
    }
}
