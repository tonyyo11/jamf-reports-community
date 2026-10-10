import XCTest
@testable import JamfReports

/// v2.2.0 admin-controlled snapshot retention. The core `sweep` is exercised
/// with explicit temp dirs; the once-per-day wiring is not.
final class SnapshotRetentionServiceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Retention ranks and ages a snapshot by the stamp in its name, so the stamp is made from
    /// `ageDays`; the mtime is set to match unless a test passes its own.
    @discardableResult
    private func writeSnapshot(kind: String, ageDays: Double, ext: String = "json",
                               modifiedDaysAgo: Double? = nil) throws -> URL {
        let dir = root.appendingPathComponent("jamf-cli-data/\(kind)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: Date(timeIntervalSinceNow: -ageDays * 86_400))
        let url = dir.appendingPathComponent("\(kind)_\(stamp).\(ext)")
        try "[]".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -(modifiedDaysAgo ?? ageDays) * 86_400)],
            ofItemAtPath: url.path
        )
        return url
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var dataDir: URL { root.appendingPathComponent("jamf-cli-data", isDirectory: true) }
    private var archiveRoot: URL { root.appendingPathComponent("_archive", isDirectory: true) }

    private func policy(mode: SnapshotRetentionService.Mode = .archive,
                        keepDays: Int = 30, keepCount: Int = 0,
                        includeSummaries: Bool = false) -> SnapshotRetentionService.Policy {
        .init(enabled: true, mode: mode, keepDays: keepDays,
              keepCount: keepCount, includeSummaries: includeSummaries)
    }

    // MARK: - Default off

    func testDisabledPolicyIsNoOp() throws {
        let old = try writeSnapshot(kind: "computers", ageDays: 400)
        let pol = SnapshotRetentionService.policy(from: nil)  // disabled
        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot, policy: pol
        )
        XCTAssertEqual(acted, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "nothing removed when disabled")
    }

    // MARK: - Archive mode

    func testArchiveMovesOldFilesPreservingKind() throws {
        let old = try writeSnapshot(kind: "computers", ageDays: 400)
        let fresh = try writeSnapshot(kind: "computers", ageDays: 1)
        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .archive, keepDays: 365)
        )
        XCTAssertEqual(acted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "old moved out")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "fresh kept")
        let archived = archiveRoot
            .appendingPathComponent("jamf-cli-data/computers/\(old.lastPathComponent)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path), "old now in archive")
    }

    func testDeleteModeRemovesOldFiles() throws {
        let old = try writeSnapshot(kind: "policies", ageDays: 400)
        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 365)
        )
        XCTAssertEqual(acted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: archiveRoot.path),
            "delete mode does not create an archive"
        )
    }

    // MARK: - Keep rules

    func testKeepCountProtectsNewestRegardlessOfAge() throws {
        // All three are old; keepCount 2 protects the two newest.
        let newest = try writeSnapshot(kind: "ea-results", ageDays: 100)
        try writeSnapshot(kind: "ea-results", ageDays: 200)
        try writeSnapshot(kind: "ea-results", ageDays: 300)
        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 30, keepCount: 2)
        )
        XCTAssertEqual(acted, 1, "only the single oldest beyond the 2-newest floor")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path), "newest kept")
    }

    func testAgeHorizonKeepsRecentFiles() throws {
        let recent = try writeSnapshot(kind: "computers", ageDays: 10)
        try writeSnapshot(kind: "computers", ageDays: 100)
        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 30)
        )
        XCTAssertEqual(acted, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    // MARK: - Ordered by the stamp in the name, not the mtime

    /// A sync provider restamps mtime on download, so old files it just fetched look newest.
    func testKeepCountRanksByTheNameStampNotTheMtime() throws {
        let newer = try writeSnapshot(kind: "computers", ageDays: 5, modifiedDaysAgo: 300)
        let older = try writeSnapshot(kind: "computers", ageDays: 200, modifiedDaysAgo: 0)
        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 0, keepCount: 1)
        )
        XCTAssertEqual(acted, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path), "newest-stamped kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: older.path))
    }

    func testAgeHorizonUsesTheNameStampNotTheMtime() throws {
        let stale = try writeSnapshot(kind: "computers", ageDays: 200, modifiedDaysAgo: 0)
        let fresh = try writeSnapshot(kind: "policies", ageDays: 2, modifiedDaysAgo: 300)
        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 30)
        )
        XCTAssertEqual(acted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testSummariesAreAgedByTheDateInTheirName() throws {
        let summariesDir = root.appendingPathComponent("snapshots/summaries", isDirectory: true)
        func summary(daysAgo: Double, modifiedDaysAgo: Double) throws -> URL {
            let date = Date(timeIntervalSinceNow: -daysAgo * 86_400)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let url = summariesDir
                .appendingPathComponent("summary_\(formatter.string(from: date)).json")
            try writeFile(url, ageDays: modifiedDaysAgo)
            return url
        }
        let recent = try summary(daysAgo: 2, modifiedDaysAgo: 400)
        let old = try summary(daysAgo: 400, modifiedDaysAgo: 0)

        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: summariesDir, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 30, includeSummaries: true))

        XCTAssertEqual(acted, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    // MARK: - Skip-list

    func testNonSnapshotSubdirsAndArchiveNeverSwept() throws {
        // state + sofa hold old files but must never be touched.
        let stateFile = root.appendingPathComponent("jamf-cli-data/state/overview.last")
        let sofaFile = root.appendingPathComponent("jamf-cli-data/sofa/macos.json")
        for url in [stateFile, sofaFile] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -400 * 86_400)], ofItemAtPath: url.path)
        }
        // A `_`-prefixed dir (e.g. a stray archive) is also skipped.
        let underscoreFile = root.appendingPathComponent("jamf-cli-data/_archive/old.json")
        try FileManager.default.createDirectory(
            at: underscoreFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: underscoreFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -400 * 86_400)], ofItemAtPath: underscoreFile.path)

        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 30)
        )
        XCTAssertEqual(acted, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sofaFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: underscoreFile.path))
    }

    // MARK: - manifest.json is never a retention candidate

    /// manifest.json is written last (hence always the newest file in its kind
    /// dir). If it counted as a snapshot it would occupy a keep_count slot and
    /// could itself be archived/deleted, ahead of a real (older) snapshot.
    func testManifestJSONNeverCountsAsSnapshot() throws {
        let snapshots = try [3.0, 2, 1].map { try writeSnapshot(kind: "ea-results", ageDays: $0) }
        let manifest = dataDir.appendingPathComponent("ea-results/manifest.json")
        try "{}".write(to: manifest, atomically: true, encoding: .utf8)

        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 30, keepCount: 3)
        )
        XCTAssertEqual(acted, 0, "keep_count 3 protects all 3 real snapshots")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path),
                      "manifest.json must never be deleted by retention")
        for url in snapshots {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    // MARK: - Summaries

    func testSummariesUntouchedUnlessIncluded() throws {
        let summariesDir = root.appendingPathComponent("snapshots/summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)
        let oldSummary = summariesDir.appendingPathComponent("summary_2024-01-01.json")
        try "{}".write(to: oldSummary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -400 * 86_400)], ofItemAtPath: oldSummary.path)

        // include_summaries default false → not passed → untouched.
        _ = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 30))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldSummary.path))

        // include_summaries true → summariesDir passed → swept.
        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: summariesDir, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 30, includeSummaries: true))
        XCTAssertEqual(acted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldSummary.path))
    }

    // MARK: - Only canonical snapshot files are candidates

    private func writeFile(_ url: URL, ageDays: Double) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -ageDays * 86_400)],
            ofItemAtPath: url.path)
    }

    /// A peer-edited `jamf_cli.data_dir` can point at a folder of personal files.
    func testOnlyStampedSnapshotsMoveFromADataDirHoldingOtherFiles() throws {
        let snapshot = try writeSnapshot(kind: "computers", ageDays: 400)
        let dashboard = try writeSnapshot(kind: "dashboard", ageDays: 400, ext: "html")
        let kindDir = dataDir.appendingPathComponent("computers")
        let others = ["notes.docx", "photo.png", "report_20240101T000000.pdf",
                      "computers_20240101T000000 2.json", "manifest.json"]
            .map { kindDir.appendingPathComponent($0) }
        for url in others { try writeFile(url, ageDays: 400) }

        let result = SnapshotRetentionService.sweepWithResult(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .archive, keepDays: 30))

        XCTAssertEqual(result.acted, 2)
        XCTAssertEqual(result.failed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dashboard.path))
        for url in others {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(url.lastPathComponent) is not a snapshot and must stay")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveRoot
            .appendingPathComponent("jamf-cli-data/computers/\(snapshot.lastPathComponent)").path))
    }

    /// Files that are not snapshots must not take a keep_count slot either.
    func testNonSnapshotFilesDoNotCountTowardKeepCount() throws {
        try writeSnapshot(kind: "computers", ageDays: 400)
        let newer = try writeSnapshot(kind: "computers", ageDays: 399)
        try writeFile(dataDir.appendingPathComponent("computers/notes.docx"), ageDays: 1)

        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 30, keepCount: 1))

        XCTAssertEqual(acted, 1, "notes.docx is no snapshot, so it takes no keep_count slot")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path))
    }

    func testOnlyCanonicalSummariesAreSwept() throws {
        let summariesDir = root.appendingPathComponent("snapshots/summaries", isDirectory: true)
        let summary = summariesDir.appendingPathComponent("summary_2024-01-01.json")
        let others = ["notes.docx", "summary_2024-01-01 2.json", "summary_20240101T000000.json"]
            .map { summariesDir.appendingPathComponent($0) }
        try writeFile(summary, ageDays: 400)
        for url in others { try writeFile(url, ageDays: 400) }

        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: summariesDir, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 30, includeSummaries: true))

        XCTAssertEqual(acted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: summary.path))
        for url in others {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(url.lastPathComponent) is not a summary and must stay")
        }
    }

    // MARK: - Policy mapping

    func testPolicyMappingDefaultsAndOverrides() throws {
        XCTAssertFalse(SnapshotRetentionService.policy(from: nil).enabled)
        let json = #"{"enabled":true,"mode":"delete","snapshot_keep_days":90,"snapshot_keep_count":5}"#
        let cfg = try JSONDecoder().decode(RetentionConfig.self, from: Data(json.utf8))
        let pol = SnapshotRetentionService.policy(from: cfg)
        XCTAssertTrue(pol.enabled)
        XCTAssertEqual(pol.mode, .delete)
        XCTAssertEqual(pol.keepDays, 90)
        XCTAssertEqual(pol.keepCount, 5)
        XCTAssertTrue(pol.isActive)
    }

    // MARK: - SweepWithResult failure tracking

    /// `sweepWithResult` returns acted=1, failed=0 on a clean archive.
    func testSweepWithResult_cleanSweepReturnsZeroFailed() throws {
        try writeSnapshot(kind: "computers", ageDays: 400)
        try writeSnapshot(kind: "computers", ageDays: 1)
        let result = SnapshotRetentionService.sweepWithResult(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .archive, keepDays: 365)
        )
        XCTAssertEqual(result.acted, 1)
        XCTAssertEqual(result.failed, 0)
    }

    /// `sweepWithResult` returns acted=0, failed=0 when no files are due.
    func testSweepWithResult_nothingDueIsAllZero() throws {
        try writeSnapshot(kind: "computers", ageDays: 5)
        let result = SnapshotRetentionService.sweepWithResult(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 365)
        )
        XCTAssertEqual(result.acted, 0)
        XCTAssertEqual(result.failed, 0)
    }

    // MARK: - Marker stamping conditioned on clean sweep

    /// `sweep` (the public API) still returns acted count and archive works correctly
    /// regardless of the marker logic — the existing archive/delete tests above cover this.
    /// These tests verify the `sweepWithResult` result struct propagates correctly
    /// through the failure-count channel.

    /// When a delete fails (file made read-only), sweepWithResult reports failed > 0.
    func testSweepWithResult_deleteFailureIsCountedInFailed() throws {
        let oldFile = try writeSnapshot(kind: "computers", ageDays: 400)
        // Make the file's parent directory read-only so the delete cannot succeed.
        let dir = oldFile.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o555))], ofItemAtPath: dir.path
        )
        defer {
            // Restore permissions so tearDown can clean up.
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: dir.path
            )
        }
        let result = SnapshotRetentionService.sweepWithResult(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 30)
        )
        XCTAssertEqual(result.acted, 0)
        XCTAssertGreaterThan(result.failed, 0, "permission-denied delete must be counted as a failure")
    }

    /// Failure messages are routed through `onLine` so run logs surface them.
    func testActFailureIsEmittedThroughOnLine() throws {
        let oldFile = try writeSnapshot(kind: "computers", ageDays: 400)
        let dir = oldFile.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o555))], ofItemAtPath: dir.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: dir.path
            )
        }

        let collector = RetentionLineCollector()
        _ = SnapshotRetentionService.sweepWithResult(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 30),
            onLine: { line in collector.append(line.text) }
        )
        let lines = collector.texts
        XCTAssertTrue(
            lines.contains { $0.contains("[warn]") && $0.contains("retention") },
            "a failure through onLine must contain [warn] and 'retention': got \(lines)"
        )
    }
}

/// Thread-safe collector for streamed log-line text. The `onLine` closure is
/// `@Sendable`, so a plainly captured `var` is not allowed under Swift 6.
private final class RetentionLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _texts: [String] = []

    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        _texts.append(text)
    }

    var texts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _texts
    }
}
