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

    // MARK: - Shared storage

    func testAPlainLocalFolderIsNotSharedStorage() throws {
        let folder = tempDir.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertNil(CloudStorage.sharedStorage(for: folder, volumeIsLocal: { _ in true }))
        XCTAssertFalse(CloudStorage.isSharedStorage(folder, volumeIsLocal: { _ in nil }))
    }

    func testANonLocalVolumeIsSharedStorage() throws {
        XCTAssertEqual(
            CloudStorage.sharedStorage(for: tempDir, volumeIsLocal: { _ in false }),
            .networkVolume)
    }

    func testAProviderPathBeatsTheVolumeProbe() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/CloudStorage/OneDrive-Org/jr")
        XCTAssertEqual(CloudStorage.sharedStorage(for: url, volumeIsLocal: { _ in true }),
                       .provider(.oneDrive))
    }

    func testASyncMarkerInTheFolderOrAnAncestorIsSharedStorage() throws {
        let markers: [(String, Bool)] = [
            (".stfolder", true), (".stignore", false), (".sync", true),
            (".nextcloudsync.log", false), (".owncloudsync.log", false),
            (".sync_58a3b2.db", false), ("._sync_58a3b2.db", false),
        ]
        for (marker, isDirectory) in markers {
            let top = tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let folder = top.appendingPathComponent("deep/workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = top.appendingPathComponent(marker, isDirectory: isDirectory)
            if isDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data().write(to: url)
            }
            XCTAssertEqual(
                CloudStorage.sharedStorage(for: folder, volumeIsLocal: { _ in true }),
                .syncMarker(marker), marker)
        }
    }

    func testAMarkerInTheHomeFolderOrAboveDoesNotPinAWorkspace() throws {
        let home = tempDir.appendingPathComponent("home", isDirectory: true)
        let workspace = home.appendingPathComponent("Jamf-Reports/p", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        for dir in [home, tempDir!] {
            try Data().write(to: dir.appendingPathComponent(".stignore"))
        }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".sync"), withIntermediateDirectories: true)
        XCTAssertNil(CloudStorage.sharedStorage(
            for: workspace, volumeIsLocal: { _ in true }, home: home))
    }

    func testAMarkerBetweenHomeAndTheWorkspaceStillPinsIt() throws {
        let home = tempDir.appendingPathComponent("home", isDirectory: true)
        let workspace = home.appendingPathComponent("Sync/Jamf-Reports/p", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Sync/.stfolder"), withIntermediateDirectories: true)
        XCTAssertEqual(
            CloudStorage.sharedStorage(for: workspace, volumeIsLocal: { _ in true }, home: home),
            .syncMarker(".stfolder"))
        try Data().write(to: workspace.appendingPathComponent(".stignore"))
        XCTAssertNotNil(CloudStorage.sharedStorage(
            for: workspace, volumeIsLocal: { _ in true }, home: home))
    }

    func testTheVolumeIsProbedOnTheSymlinkResolvedPath() throws {
        let mount = tempDir.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let link = tempDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: mount)
        let remote = mount.resolvingSymlinksInPath().path
        XCTAssertEqual(
            CloudStorage.sharedStorage(for: link, volumeIsLocal: { $0.path != remote }),
            .networkVolume)
    }

    func testAFileThatOnlyLooksLikeAMarkerIsNotOne() throws {
        for name in ["sync_notes.db", ".sync_notes.txt", "stfolder"] {
            try Data().write(to: tempDir.appendingPathComponent(name))
        }
        XCTAssertNil(CloudStorage.sharedStorage(for: tempDir, volumeIsLocal: { _ in true }))
    }

    // MARK: - Folders a File Provider syncs (iCloud Desktop & Documents)

    private static let iCloudDomain = "com.apple.CloudDocs.iCloudDriveFileProvider/B463EF00"

    /// A probe answering only for the folder at `domainAt` (attribute) or `ubiquitousAt`.
    private func probe(
        domainAt: URL? = nil, domain: String = iCloudDomain, ubiquitousAt: URL? = nil
    ) -> CloudStorage.SyncProbe {
        let domainPath = domainAt?.resolvingSymlinksInPath().path
        let ubiquitousPath = ubiquitousAt?.resolvingSymlinksInPath().path
        return CloudStorage.SyncProbe(
            fileProviderDomain: { $0.path == domainPath ? domain : nil },
            isUbiquitous: { $0.path == ubiquitousPath })
    }

    private func documentsWorkspace() throws -> (home: URL, documents: URL, workspace: URL) {
        let home = tempDir.appendingPathComponent("home", isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let workspace = documents.appendingPathComponent("Jamf-Reports/p", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return (home, documents, workspace)
    }

    func testAFileProviderDomainOnTheFolderIsICloudDesktopAndDocuments() throws {
        let (home, _, workspace) = try documentsWorkspace()
        XCTAssertEqual(
            CloudStorage.sharedStorage(
                for: workspace, volumeIsLocal: { _ in true },
                syncProbe: probe(domainAt: workspace), home: home),
            .provider(.iCloudDesktopAndDocuments))
        XCTAssertEqual(CloudStorage.Provider.iCloudDesktopAndDocuments.displayName,
                       "iCloud Desktop & Documents")
    }

    func testAFileProviderDomainOnAnAncestorBelowHomeCounts() throws {
        let (home, documents, workspace) = try documentsWorkspace()
        XCTAssertEqual(
            CloudStorage.sharedStorage(
                for: workspace, volumeIsLocal: { _ in true },
                syncProbe: probe(domainAt: documents), home: home),
            .provider(.iCloudDesktopAndDocuments))
        // Another provider's domain is still a synced folder, named generically.
        XCTAssertEqual(
            CloudStorage.sharedStorage(
                for: workspace, volumeIsLocal: { _ in true },
                syncProbe: probe(domainAt: documents, domain: "com.example.Sync/1"), home: home),
            .provider(.otherFileProvider))
    }

    func testAFileProviderDomainOnHomeOrAboveDoesNotCount() throws {
        let (home, _, workspace) = try documentsWorkspace()
        for folder in [home, tempDir!] {
            XCTAssertNil(CloudStorage.sharedStorage(
                for: workspace, volumeIsLocal: { _ in true },
                syncProbe: probe(domainAt: folder), home: home), folder.path)
            XCTAssertNil(CloudStorage.sharedStorage(
                for: workspace, volumeIsLocal: { _ in true },
                syncProbe: probe(ubiquitousAt: folder), home: home), folder.path)
        }
    }

    func testAUbiquitousFolderIsICloudDesktopAndDocuments() throws {
        let (home, _, workspace) = try documentsWorkspace()
        XCTAssertEqual(
            CloudStorage.sharedStorage(
                for: workspace, volumeIsLocal: { _ in true },
                syncProbe: probe(ubiquitousAt: workspace), home: home),
            .provider(.iCloudDesktopAndDocuments))
    }

    func testNeitherSignalLeavesTheFolderLocal() throws {
        let (home, _, workspace) = try documentsWorkspace()
        XCTAssertNil(CloudStorage.sharedStorage(
            for: workspace, volumeIsLocal: { _ in true }, syncProbe: probe(), home: home))
        // The live probe reads no attribute on a fresh temporary folder.
        XCTAssertNil(CloudStorage.fileProviderDomain(of: workspace))
        XCTAssertFalse(CloudStorage.SyncProbe.live.isUbiquitous(workspace))
        XCTAssertNil(CloudStorage.sharedStorage(
            for: workspace, volumeIsLocal: { _ in true }, home: home))
    }

    /// `DailySummary.collectedByHost` is written wherever the data folder is shared storage.
    func testTheCollectingHostIsRecordedOnASyncedDataFolder() {
        XCTAssertNil(ReportEngine.collectingHostLabel(dataDir: tempDir, syncProbe: probe()))
        XCTAssertEqual(
            ReportEngine.collectingHostLabel(dataDir: tempDir, syncProbe: .iCloudEverywhere),
            SharedWorkspace.currentHost.display)
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
            CloudStorage.isLikelySyncConflict(
                "summary (Tony's Mac's conflicted copy 2026-08-20).json"
            )
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

    /// `CLIBridge.backup` names a folder in UTC; the prune order and the Backups screen read it
    /// back the same way, so a backup's date is one instant on both.
    func testBackupFolderNamesReadAsUTCLikeTheBackupsScreen() throws {
        let name = "20260820T060000"
        let pruneDate = try XCTUnwrap(CloudStorage.backupDirectoryTimestamp(name: name)?.date)
        XCTAssertEqual(pruneDate, BackupRecord.dateInName(name))
        XCTAssertEqual(pruneDate, ISO8601Time.parse("2026-08-20T06:00:00Z"))
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

    func testSummaryDateComesFromTheCanonicalNameOnly() throws {
        func date(_ name: String) -> Date? {
            CloudStorage.summaryDate(of: URL(fileURLWithPath: "/x/\(name)"))
        }
        let parts = try XCTUnwrap(date("summary_2026-08-20.json").map {
            Calendar(identifier: .iso8601).dateComponents([.year, .month, .day, .hour], from: $0)
        })
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour], [2026, 8, 20, 0])
        XCTAssertNil(date("summary_2026-08-20 2.json"), "a conflict copy has no date")
        XCTAssertNil(date("summary_2026-13-45.json"))
        XCTAssertNil(date("summary_2026-02-31.json"), "no rolling over into March")
        XCTAssertNil(date("computers_20260820T000000.json"))
    }
}

extension CloudStorage.SyncProbe {
    /// Every folder reads as synced by iCloud Desktop & Documents, for the callers' tests.
    static let iCloudEverywhere = CloudStorage.SyncProbe(
        fileProviderDomain: { _ in "com.apple.CloudDocs.iCloudDriveFileProvider/B463EF00" },
        isUbiquitous: { _ in false })
}
