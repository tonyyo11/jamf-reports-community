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

    @discardableResult
    private func writeSnapshot(kind: String, name: String, ageDays: Double) throws -> URL {
        let dir = root.appendingPathComponent("jamf-cli-data/\(kind)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try "[]".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -ageDays * 86_400)], ofItemAtPath: url.path
        )
        return url
    }

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
        let old = try writeSnapshot(kind: "computers", name: "c_old.json", ageDays: 400)
        let pol = SnapshotRetentionService.policy(from: nil)  // disabled
        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot, policy: pol
        )
        XCTAssertEqual(acted, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path), "nothing removed when disabled")
    }

    // MARK: - Archive mode

    func testArchiveMovesOldFilesPreservingKind() throws {
        let old = try writeSnapshot(kind: "computers", name: "c_old.json", ageDays: 400)
        let fresh = try writeSnapshot(kind: "computers", name: "c_new.json", ageDays: 1)
        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .archive, keepDays: 365)
        )
        XCTAssertEqual(acted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "old moved out")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "fresh kept")
        let archived = archiveRoot.appendingPathComponent("jamf-cli-data/computers/c_old.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path), "old now in archive")
    }

    func testDeleteModeRemovesOldFiles() throws {
        let old = try writeSnapshot(kind: "policies", name: "p_old.json", ageDays: 400)
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
        try writeSnapshot(kind: "ea-results", name: "ea1.json", ageDays: 100)
        try writeSnapshot(kind: "ea-results", name: "ea2.json", ageDays: 200)
        try writeSnapshot(kind: "ea-results", name: "ea3.json", ageDays: 300)
        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 30, keepCount: 2)
        )
        XCTAssertEqual(acted, 1, "only the single oldest beyond the 2-newest floor")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("ea-results/ea1.json").path), "newest kept")
    }

    func testAgeHorizonKeepsRecentFiles() throws {
        try writeSnapshot(kind: "computers", name: "recent.json", ageDays: 10)
        try writeSnapshot(kind: "computers", name: "old.json", ageDays: 100)
        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 30)
        )
        XCTAssertEqual(acted, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dataDir.appendingPathComponent("computers/recent.json").path))
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
        try writeSnapshot(kind: "ea-results", name: "ea1.json", ageDays: 3)
        try writeSnapshot(kind: "ea-results", name: "ea2.json", ageDays: 2)
        try writeSnapshot(kind: "ea-results", name: "ea3.json", ageDays: 1)
        let manifest = dataDir.appendingPathComponent("ea-results/manifest.json")
        try "{}".write(to: manifest, atomically: true, encoding: .utf8)

        let acted = SnapshotRetentionService.sweep(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .delete, keepDays: 30, keepCount: 3)
        )
        XCTAssertEqual(acted, 0, "keep_count 3 protects all 3 real snapshots")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path),
                      "manifest.json must never be deleted by retention")
        for name in ["ea1.json", "ea2.json", "ea3.json"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: dataDir.appendingPathComponent("ea-results/\(name)").path))
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
        try writeSnapshot(kind: "computers", name: "old.json", ageDays: 400)
        try writeSnapshot(kind: "computers", name: "new.json", ageDays: 1)
        let result = SnapshotRetentionService.sweepWithResult(
            dataDir: dataDir, summariesDir: nil, archiveRoot: archiveRoot,
            policy: policy(mode: .archive, keepDays: 365)
        )
        XCTAssertEqual(result.acted, 1)
        XCTAssertEqual(result.failed, 0)
    }

    /// `sweepWithResult` returns acted=0, failed=0 when no files are due.
    func testSweepWithResult_nothingDueIsAllZero() throws {
        try writeSnapshot(kind: "computers", name: "recent.json", ageDays: 5)
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
        let oldFile = try writeSnapshot(kind: "computers", name: "old.json", ageDays: 400)
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
        let oldFile = try writeSnapshot(kind: "computers", name: "old.json", ageDays: 400)
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
