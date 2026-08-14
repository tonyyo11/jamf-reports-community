import Foundation
import XCTest
import CryptoKit
@testable import JamfReports

/// Coverage for `SnapshotManifest`. Originally added in PR-7 Item 4
/// (Python manifest generation + Swift verification); extended in PR-10
/// (threat-model T-11) when `verify` gained a `VerificationResult` return
/// type so the UI can distinguish absent / corrupt / omitted / mismatch
/// from verified rather than treating all non-matches as silent no-ops.
/// The Swift side remains read-only — we never write the manifest.
///
/// These tests pin both the engine-side contract (no throw, no abort) and
/// the new UI-facing contract (each case is reported distinctly).
final class SnapshotManifestTests: XCTestCase {

    nonisolated(unsafe) private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotManifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempRoot {
            try? FileManager.default.removeItem(at: url)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Absent manifest

    func testVerifyReturnsAbsentWhenManifestMissing() throws {
        let snapshot = tempRoot.appendingPathComponent("audit_20260101T000000.json")
        let data = Data(#"{"ok":true}"#.utf8)
        try data.write(to: snapshot)

        let manifest = tempRoot.appendingPathComponent(SnapshotManifest.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))

        XCTAssertEqual(SnapshotManifest.verify(snapshot: snapshot, data: data), .absent)
    }

    // MARK: - Happy path

    func testVerifyReturnsVerifiedOnExactMatch() throws {
        let snapshot = tempRoot.appendingPathComponent("audit_20260101T000000.json")
        let data = Data(#"{"ok":true}"#.utf8)
        try data.write(to: snapshot)
        try writeManifest(files: [snapshot.lastPathComponent: sha256Hex(data)])

        XCTAssertEqual(SnapshotManifest.verify(snapshot: snapshot, data: data), .verified)
    }

    // MARK: - Tampered file

    /// PR-7 contract: Swift verifier never aborts on mismatch. The Python side
    /// owns the strict-abort policy via `--strict-manifest`. PR-10 added the
    /// `.mismatch` return so the UI can surface a warning pill.
    func testVerifyReturnsMismatchOnHashDiff() throws {
        let snapshot = tempRoot.appendingPathComponent("audit_20260101T000000.json")
        let originalData = Data(#"{"ok":true}"#.utf8)
        try originalData.write(to: snapshot)
        try writeManifest(files: [snapshot.lastPathComponent: sha256Hex(originalData)])

        let tampered = Data(#"{"ok":false}"#.utf8)
        try tampered.write(to: snapshot)

        XCTAssertEqual(SnapshotManifest.verify(snapshot: snapshot, data: tampered), .mismatch)
    }

    // MARK: - Manifest omits this file

    func testVerifyReturnsOmittedWhenManifestLacksFile() throws {
        let snapshot = tempRoot.appendingPathComponent("audit_20260101T000000.json")
        let data = Data(#"{"ok":true}"#.utf8)
        try data.write(to: snapshot)

        let other = tempRoot.appendingPathComponent("audit_20260201T000000.json")
        let otherData = Data(#"{"ok":true}"#.utf8)
        try otherData.write(to: other)
        try writeManifest(files: [other.lastPathComponent: sha256Hex(otherData)])

        XCTAssertEqual(SnapshotManifest.verify(snapshot: snapshot, data: data), .omitted)
    }

    // MARK: - Corrupt manifest

    /// PR-10 (threat-model T-11): a manifest.json that exists but is unparseable
    /// must surface as `.corrupt`, not silently fall through to `.absent`. A
    /// corrupt manifest is more suspicious than an absent one and should leave
    /// a forensic signal in AppLogger.engine.
    func testVerifyReturnsCorruptWhenManifestUnparseable() throws {
        let snapshot = tempRoot.appendingPathComponent("audit_20260101T000000.json")
        let data = Data(#"{"ok":true}"#.utf8)
        try data.write(to: snapshot)

        // Write garbage to manifest.json — valid file, invalid JSON.
        let manifest = tempRoot.appendingPathComponent(SnapshotManifest.fileName)
        try Data("not even close to json {".utf8).write(to: manifest)

        XCTAssertEqual(SnapshotManifest.verify(snapshot: snapshot, data: data), .corrupt)
    }

    /// Variant: parseable JSON but wrong schema (missing required keys).
    func testVerifyReturnsCorruptWhenManifestHasWrongSchema() throws {
        let snapshot = tempRoot.appendingPathComponent("audit_20260101T000000.json")
        let data = Data(#"{"ok":true}"#.utf8)
        try data.write(to: snapshot)

        let manifest = tempRoot.appendingPathComponent(SnapshotManifest.fileName)
        try Data(#"{"unexpected":"shape"}"#.utf8).write(to: manifest)

        XCTAssertEqual(SnapshotManifest.verify(snapshot: snapshot, data: data), .corrupt)
    }

    // MARK: - scanWorkspace (PR-10)

    /// PR-10 / threat-model T-11: AuditView feeds off scanWorkspace.
    /// Three subdirs with mixed verification outcomes — pin that each
    /// outcome lands in the matching counter.
    func testScanWorkspaceAggregatesPerSubdirectoryResults() throws {
        // dir A: verified
        let dirA = tempRoot.appendingPathComponent("audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        let snapA = dirA.appendingPathComponent("audit_20260101T000000.json")
        let dataA = Data(#"{"ok":true}"#.utf8)
        try dataA.write(to: snapA)
        try writeManifest(at: dirA, files: [snapA.lastPathComponent: sha256Hex(dataA)])

        // dir B: absent manifest
        let dirB = tempRoot.appendingPathComponent("policy", isDirectory: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try Data(#"{"ok":true}"#.utf8).write(
            to: dirB.appendingPathComponent("policy_20260101T000000.json")
        )

        // dir C: mismatch
        let dirC = tempRoot.appendingPathComponent("update", isDirectory: true)
        try FileManager.default.createDirectory(at: dirC, withIntermediateDirectories: true)
        let snapC = dirC.appendingPathComponent("update_20260101T000000.json")
        try Data(#"{"ok":true}"#.utf8).write(to: snapC)
        try writeManifest(at: dirC, files: [snapC.lastPathComponent: sha256Hex(Data(#"{"ok":false}"#.utf8))])

        let summary = SnapshotManifest.scanWorkspace(dataDir: tempRoot)
        XCTAssertEqual(summary.verified, 1)
        XCTAssertEqual(summary.absent, 1)
        XCTAssertEqual(summary.mismatch, 1)
        XCTAssertEqual(summary.corrupt, 0)
        XCTAssertEqual(summary.omitted, 0)
        XCTAssertEqual(summary.unverified, 2, "absent + mismatch")
    }

    func testScanWorkspaceReturnsZeroedSummaryWhenDataDirMissing() {
        let missing = tempRoot.appendingPathComponent("does-not-exist", isDirectory: true)
        let summary = SnapshotManifest.scanWorkspace(dataDir: missing)
        XCTAssertEqual(summary, SnapshotManifest.WorkspaceVerificationSummary())
    }

    /// PR-10 / security-reviewer SHOULD-FIX: attacker-planted files whose
    /// names end in `manifest.json` (e.g. `xmanifest.json`) must NOT be
    /// picked as snapshot candidates. Pre-fix they were, which produced
    /// misleading verification results.
    func testScanWorkspaceExcludesManifestSuffixFiles() throws {
        let dir = tempRoot.appendingPathComponent("audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Real snapshot + matching manifest = .verified.
        let snap = dir.appendingPathComponent("audit_20260101T000000.json")
        let data = Data(#"{"ok":true}"#.utf8)
        try data.write(to: snap)
        try writeManifest(at: dir, files: [snap.lastPathComponent: sha256Hex(data)])

        // Attacker-planted "xmanifest.json" — newer mtime, would have
        // been picked pre-fix and produced a misleading .omitted result
        // for the directory (manifest doesn't list it).
        let attacker = dir.appendingPathComponent("xmanifest.json")
        try Data(#"{"evil":true}"#.utf8).write(to: attacker)

        let summary = SnapshotManifest.scanWorkspace(dataDir: tempRoot)
        XCTAssertEqual(summary.verified, 1, "real snapshot must be picked, not xmanifest.json")
        XCTAssertEqual(summary.omitted, 0, "xmanifest.json must not become the candidate")
    }

    /// Only the newest JSON per subdir is checked — a single missing-
    /// manifest dir must not double-count if it has multiple snapshots.
    func testScanWorkspacePicksNewestPerSubdirectory() throws {
        let dir = tempRoot.appendingPathComponent("audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let older = dir.appendingPathComponent("audit_20260101T000000.json")
        let newer = dir.appendingPathComponent("audit_20260201T000000.json")
        try Data(#"{"ok":true}"#.utf8).write(to: older)
        try Data(#"{"ok":true}"#.utf8).write(to: newer)
        // Force older to have older mtime (Date in the past).
        let past = Date(timeIntervalSinceNow: -86400)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: older.path)

        let summary = SnapshotManifest.scanWorkspace(dataDir: tempRoot)
        XCTAssertEqual(summary.absent, 1, "exactly one dir with no manifest = one absent")
        XCTAssertEqual(summary.verified, 0)
    }

    /// P2 review: mtime lies on synced storage (iCloud/SharePoint re-stamp
    /// files on sync), so the newest-pick must order by the FILENAME
    /// timestamp like `ReportEngine.loadLatestSnapshotData` — not raw mtime
    /// — or the strict-manifest gate can verify a different file than the
    /// one generate actually renders.
    func testScanWorkspacePicksNewestByFilenameNotMtime() throws {
        let dir = tempRoot.appendingPathComponent("audit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = Data(#"{"ok":true}"#.utf8)

        // Older FILENAME timestamp, stamped with the NEWER mtime.
        let olderName = dir.appendingPathComponent("audit_20260101T000000.json")
        try data.write(to: olderName)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: olderName.path
        )

        // Newer FILENAME timestamp, stamped with the OLDER mtime.
        let newerName = dir.appendingPathComponent("audit_20260201T000000.json")
        try data.write(to: newerName)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -86400)], ofItemAtPath: newerName.path
        )

        // Manifest lists only the newer-FILENAME file — the reader's pick.
        try writeManifest(at: dir, files: [newerName.lastPathComponent: sha256Hex(data)])

        let summary = SnapshotManifest.scanWorkspace(dataDir: tempRoot)
        XCTAssertEqual(summary.verified, 1, "must pick the file the reader would render")
        XCTAssertEqual(summary.omitted, 0)
    }

    // MARK: - Helpers

    private func writeManifest(files: [String: String]) throws {
        try writeManifest(at: tempRoot, files: files)
    }

    private func writeManifest(at directory: URL, files: [String: String]) throws {
        let url = directory.appendingPathComponent(SnapshotManifest.fileName)
        let payload: [String: Any] = ["algorithm": "sha256", "files": files]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: url)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
