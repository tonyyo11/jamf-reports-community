import XCTest
@testable import JamfReports

/// Covers the cloud-sync guards. Each test pins a failure mode that is silent
/// in production: wrong file chosen, duplicate ingested, backup deleted.
final class CloudStorageTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        tempDir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Canonical filename stamps

    func testSnapshotTimestampParsesCanonicalStem() {
        XCTAssertNotNil(CloudStorage.snapshotTimestamp(stem: "ea-results_20240615T120000"))
    }

    func testSnapshotTimestampParsesDashedPythonEraStem() {
        XCTAssertNotNil(CloudStorage.snapshotTimestamp(stem: "ea-results_2026-04-15T210038"))
        XCTAssertNotNil(CloudStorage.snapshotTimestamp(stem: "ea-results_2026-04-15T210038673146"))
    }

    /// The load-bearing case: a sync-conflict copy must NOT parse, because a
    /// parsed-but-wrong stamp is how a duplicate gets ranked as newest.
    func testSnapshotTimestampRejectsConflictCopyStem() {
        XCTAssertNil(CloudStorage.snapshotTimestamp(stem: "ea-results_20240615T120000 2"))
        XCTAssertNil(CloudStorage.snapshotTimestamp(stem: "ea-results_20240615T120000 (1)"))
        XCTAssertNil(CloudStorage.snapshotTimestamp(stem: "ea-results_20240615T120000 copy"))
    }

    func testConflictDetectionCoversCommonProviderForms() {
        XCTAssertTrue(CloudStorage.isLikelySyncConflict("computers_20240615T120000 2.json"))
        XCTAssertTrue(CloudStorage.isLikelySyncConflict("computers (1).json"))
        XCTAssertTrue(CloudStorage.isLikelySyncConflict("config copy.yaml"))
        XCTAssertTrue(CloudStorage.isLikelySyncConflict("config copy 3.yaml"))
        XCTAssertTrue(
            CloudStorage.isLikelySyncConflict("summary (Tony's Mac's conflicted copy 2026-08-20).json")
        )
        XCTAssertFalse(CloudStorage.isLikelySyncConflict("computers_20240615T120000.json"))
        XCTAssertFalse(CloudStorage.isLikelySyncConflict("summary_2026-08-20.json"))
    }

    func testCanonicalSummaryFilename() {
        XCTAssertTrue(CloudStorage.isCanonicalSummaryFilename("summary_2026-08-20.json"))
        XCTAssertFalse(CloudStorage.isCanonicalSummaryFilename("summary_2026-08-20 2.json"))
        XCTAssertFalse(CloudStorage.isCanonicalSummaryFilename("summary_2026-08-20.json.bak"))
        XCTAssertFalse(CloudStorage.isCanonicalSummaryFilename("summary_20260820.json"))
    }

    func testBackupDirectoryTimestampHandlesSameSecondSuffix() {
        let base = CloudStorage.backupDirectoryTimestamp(name: "20260820T060000")
        let dup = CloudStorage.backupDirectoryTimestamp(name: "20260820T060000-2")
        XCTAssertEqual(base?.sequence, 0)
        XCTAssertEqual(dup?.sequence, 2)
        XCTAssertEqual(base?.date, dup?.date)
        XCTAssertNil(CloudStorage.backupDirectoryTimestamp(name: "20260820T060000 2"))
        XCTAssertNil(CloudStorage.backupDirectoryTimestamp(name: "manual-before-upgrade"))
    }

    // MARK: - Provider detection

    func testProviderDetection() {
        let home = NSString(string: "~").expandingTildeInPath
        let oneDrive = URL(fileURLWithPath:
            "\(home)/Library/CloudStorage/OneDrive-Contoso/Team/Jamf Reports")
        XCTAssertEqual(CloudStorage.provider(for: oneDrive), .oneDrive)

        let box = URL(fileURLWithPath: "\(home)/Library/CloudStorage/Box-Box/Reports")
        XCTAssertEqual(CloudStorage.provider(for: box), .box)

        let volume = URL(fileURLWithPath: "/Volumes/TeamShare/Jamf Reports")
        XCTAssertEqual(CloudStorage.provider(for: volume), .detachedVolume)

        let local = URL(fileURLWithPath: "\(home)/Jamf-Reports/prod")
        XCTAssertNil(CloudStorage.provider(for: local))
    }

    // MARK: - Path policy

    /// `~/Library` stays denied, but the CloudStorage mount point must be
    /// reachable or "publish reports to the team folder" is impossible.
    func testCloudStorageIsNotTreatedAsSensitiveButRestOfLibraryIs() {
        let home = NSString(string: "~").expandingTildeInPath
        let cloud = URL(fileURLWithPath:
            "\(home)/Library/CloudStorage/OneDrive-Contoso/Team/Jamf Reports")
        XCTAssertFalse(WorkspacePaths.isSensitiveAbsolutePath(cloud))

        let appSupport = URL(fileURLWithPath: "\(home)/Library/Application Support/Foo")
        XCTAssertTrue(WorkspacePaths.isSensitiveAbsolutePath(appSupport))
        XCTAssertTrue(WorkspacePaths.isSensitiveAbsolutePath(
            URL(fileURLWithPath: "\(home)/.ssh")
        ))
    }

    // MARK: - Ordering

    /// Sync providers re-stamp mtimes. The newest file must be chosen by the
    /// timestamp in its NAME even when the mtimes say the opposite.
    func testNewestJSONFileIgnoresMisleadingMtimes() throws {
        let old = tempDir.appendingPathComponent("computers_20260101T010000.json")
        let new = tempDir.appendingPathComponent("computers_20260820T060000.json")
        try "{}".write(to: old, atomically: true, encoding: .utf8)
        try "{}".write(to: new, atomically: true, encoding: .utf8)
        // Provider "syncs" the older file last, giving it the freshest mtime.
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: new.path
        )

        XCTAssertEqual(
            FileManager.newestJSONFile(in: tempDir)?.lastPathComponent,
            "computers_20260820T060000.json"
        )
    }

    func testNewestJSONFileSkipsConflictCopyEvenWhenFreshest() throws {
        let real = tempDir.appendingPathComponent("computers_20260820T060000.json")
        let copy = tempDir.appendingPathComponent("computers_20260820T060000 2.json")
        try "{}".write(to: real, atomically: true, encoding: .utf8)
        try "{}".write(to: copy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: copy.path
        )

        XCTAssertEqual(
            FileManager.newestJSONFile(in: tempDir)?.lastPathComponent,
            "computers_20260820T060000.json"
        )
    }

    /// Directories with no canonical stamps keep the old mtime behaviour, so
    /// non-snapshot callers are unaffected by the ordering change.
    func testUnstampedFilesStillFallBackToMtime() throws {
        let a = tempDir.appendingPathComponent("alpha.json")
        let b = tempDir.appendingPathComponent("beta.json")
        try "{}".write(to: a, atomically: true, encoding: .utf8)
        try "{}".write(to: b, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: a.path
        )
        XCTAssertEqual(FileManager.newestJSONFile(in: tempDir)?.lastPathComponent, "beta.json")
    }

    func testStampedFileAlwaysBeatsUnstampedRegardlessOfMtime() throws {
        let stamped = tempDir.appendingPathComponent("computers_20200101T000000.json")
        let unstamped = tempDir.appendingPathComponent("scratch.json")
        try "{}".write(to: stamped, atomically: true, encoding: .utf8)
        try "{}".write(to: unstamped, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(9999)], ofItemAtPath: unstamped.path
        )
        XCTAssertEqual(
            FileManager.newestJSONFile(in: tempDir)?.lastPathComponent,
            "computers_20200101T000000.json"
        )
    }
}
