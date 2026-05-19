import XCTest
import CryptoKit
@testable import JamfReports

/// PR-22 T-14: state files participate in the snapshot-manifest scheme so
/// a tampered `.last` is caught the same way a tampered JSON snapshot is.
///
/// Pinned semantics:
/// - `recordRun` rewrites `<state-dir>/manifest.json` atomically with
///   SHA-256 hashes of every `.last` file in the dir.
/// - The manifest format matches `SnapshotManifest`'s reader exactly so
///   the existing `verify(snapshot:data:)` works on `.last` files with
///   zero new code paths.
/// - Schema version is bumped to 2 to indicate state-aware manifests;
///   v1 (Python-written, no `version` field) still decodes for
///   pre-PR-22 workspaces.
/// - Backward compat: a workspace with no state files generates no
///   manifest — strict-mode preflight must NOT fail on the missing file.
final class StateFileManifestTests: XCTestCase {

    private let fm = FileManager.default
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("sfm-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Manifest is written after recordRun

    func testRecordRunWritesManifest() throws {
        let store = StateFileStore(directory: tempDir)
        try store.recordRun(report: "overview", at: Date(timeIntervalSince1970: 1_700_000_000))

        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        XCTAssertTrue(fm.fileExists(atPath: manifestURL.path),
                      "recordRun must rewrite manifest.json after every state write")
    }

    func testManifestSchemaMatchesSnapshotManifestReader() throws {
        let store = StateFileStore(directory: tempDir)
        try store.recordRun(report: "overview", at: Date(timeIntervalSince1970: 1_700_000_000))

        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["algorithm"] as? String, "sha256")
        XCTAssertEqual(json?["version"] as? Int, 2,
                       "Bumped from implicit v1 (Python) to v2 (state-aware)")
        let files = json?["files"] as? [String: String]
        XCTAssertNotNil(files?["overview.last"], "overview.last should appear in files map")
    }

    func testManifestHashesAllCurrentLastFiles() throws {
        let store = StateFileStore(directory: tempDir)
        try store.recordRun(report: "overview", at: Date(timeIntervalSince1970: 1_700_000_000))
        try store.recordRun(report: "security", at: Date(timeIntervalSince1970: 1_700_086_400))

        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let files = json?["files"] as? [String: String]
        XCTAssertEqual(files?.count, 2, "Both .last files must appear in the manifest")
        XCTAssertNotNil(files?["overview.last"])
        XCTAssertNotNil(files?["security.last"])
    }

    func testManifestHashMatchesActualFileContents() throws {
        let store = StateFileStore(directory: tempDir)
        try store.recordRun(report: "overview", at: Date(timeIntervalSince1970: 1_700_000_000))

        let lastURL = tempDir.appendingPathComponent("overview.last")
        let lastData = try Data(contentsOf: lastURL)
        let expectedHash = SHA256.hash(data: lastData)
            .map { String(format: "%02x", $0) }
            .joined()

        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let json = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        let files = json?["files"] as? [String: String]
        XCTAssertEqual(files?["overview.last"]?.lowercased(), expectedHash.lowercased())
    }

    // MARK: - SnapshotManifest.verify works on .last files

    func testVerifyAcceptsCleanStateFile() throws {
        let store = StateFileStore(directory: tempDir)
        try store.recordRun(report: "overview", at: Date(timeIntervalSince1970: 1_700_000_000))

        let lastURL = tempDir.appendingPathComponent("overview.last")
        let data = try Data(contentsOf: lastURL)
        XCTAssertEqual(SnapshotManifest.verify(snapshot: lastURL, data: data), .verified)
    }

    func testVerifyDetectsTamperedStateFile() throws {
        let store = StateFileStore(directory: tempDir)
        try store.recordRun(report: "overview", at: Date(timeIntervalSince1970: 1_700_000_000))

        // Attacker rewrites overview.last to push the timestamp back by
        // a year, deferring the next refresh indefinitely.
        let lastURL = tempDir.appendingPathComponent("overview.last")
        try "2200-01-01T00:00:00Z".write(to: lastURL, atomically: true, encoding: .utf8)

        let tamperedData = try Data(contentsOf: lastURL)
        XCTAssertEqual(SnapshotManifest.verify(snapshot: lastURL, data: tamperedData), .mismatch)
    }

    // MARK: - Backward compat

    func testNoStateFilesMeansNoManifest() throws {
        // Pre-PR-22 workspace — state dir doesn't exist yet. No manifest
        // is written until recordRun is called, so audit/preflight must
        // not flag the absence as a failure.
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        XCTAssertFalse(fm.fileExists(atPath: manifestURL.path))
    }

    func testManifestRewriteFromEmptyDirCleansUpStaleManifest() throws {
        // Simulate: an operator manually deleted all .last files but the
        // stale manifest.json is still there. A fresh recordRun for a new
        // report should leave only that one report in the manifest, not
        // resurrect ghost entries from the stale file.
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        let stale = """
        {"version": 2, "algorithm": "sha256", "files": {"ghost.last": "0000"}}
        """
        try stale.write(to: manifestURL, atomically: true, encoding: .utf8)

        let store = StateFileStore(directory: tempDir)
        try store.recordRun(report: "overview", at: Date(timeIntervalSince1970: 1_700_000_000))

        let data = try Data(contentsOf: manifestURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let files = json?["files"] as? [String: String]
        XCTAssertEqual(files?.count, 1)
        XCTAssertNotNil(files?["overview.last"])
        XCTAssertNil(files?["ghost.last"],
                     "Rewrite must source files from disk, not merge with prior manifest contents")
    }

    // MARK: - scanStateDir for the audit view

    func testScanStateDirCountsCleanFilesAsVerified() throws {
        let store = StateFileStore(directory: tempDir)
        try store.recordRun(report: "overview", at: Date(timeIntervalSince1970: 1_700_000_000))
        try store.recordRun(report: "security", at: Date(timeIntervalSince1970: 1_700_086_400))

        let summary = SnapshotManifest.scanStateDir(tempDir)
        XCTAssertEqual(summary.verified, 2)
        XCTAssertEqual(summary.unverified, 0)
    }

    func testScanStateDirCountsTamperedFilesAsMismatch() throws {
        let store = StateFileStore(directory: tempDir)
        try store.recordRun(report: "overview", at: Date(timeIntervalSince1970: 1_700_000_000))
        try store.recordRun(report: "security", at: Date(timeIntervalSince1970: 1_700_086_400))

        // Tamper one of them.
        try "2200-01-01T00:00:00Z".write(
            to: tempDir.appendingPathComponent("overview.last"),
            atomically: true, encoding: .utf8
        )

        let summary = SnapshotManifest.scanStateDir(tempDir)
        XCTAssertEqual(summary.verified, 1, "Untampered file still verifies")
        XCTAssertEqual(summary.mismatch, 1, "Tampered file flagged as mismatch")
        XCTAssertEqual(summary.unverified, 1)
    }

    func testScanStateDirOnMissingDirReturnsZeros() {
        let missing = tempDir.appendingPathComponent("nope", isDirectory: true)
        let summary = SnapshotManifest.scanStateDir(missing)
        XCTAssertEqual(summary.verified, 0)
        XCTAssertEqual(summary.unverified, 0,
                       "Missing state dir is not an audit failure — pre-PR-22 workspaces")
    }

    func testScanStateDirIgnoresNonLastFiles() throws {
        // The state dir holds only .last files plus manifest.json. A
        // stray file (e.g., an editor swap file) must not be counted.
        let store = StateFileStore(directory: tempDir)
        try store.recordRun(report: "overview", at: Date(timeIntervalSince1970: 1_700_000_000))
        try "irrelevant".write(
            to: tempDir.appendingPathComponent("overview.last.swp"),
            atomically: true, encoding: .utf8
        )

        let summary = SnapshotManifest.scanStateDir(tempDir)
        XCTAssertEqual(summary.verified, 1)
        XCTAssertEqual(summary.unverified, 0)
    }

    func testV1ManifestStillDecodes() throws {
        // Python writes v1 manifests with no `version` field. SnapshotManifest
        // must still verify them — operators on PR-7..PR-21 mid-upgrade should
        // not see audit failures while their Python collect still owns the
        // manifest.
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        let v1Body = """
        {"algorithm": "sha256", "files": {"overview.last": "%HASH%"}}
        """
        // Write the state file first, then the v1 manifest with its hash.
        let lastURL = tempDir.appendingPathComponent("overview.last")
        try "2023-11-14T22:13:20Z".write(to: lastURL, atomically: true, encoding: .utf8)
        let lastData = try Data(contentsOf: lastURL)
        let hash = SHA256.hash(data: lastData)
            .map { String(format: "%02x", $0) }.joined()
        try v1Body
            .replacingOccurrences(of: "%HASH%", with: hash)
            .write(to: manifestURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            SnapshotManifest.verify(snapshot: lastURL, data: lastData),
            .verified,
            "v1 manifest without version field must still verify cleanly"
        )
    }
}
