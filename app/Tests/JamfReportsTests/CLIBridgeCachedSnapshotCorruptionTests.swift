import Foundation
import XCTest
@testable import JamfReports

// Tests for the S-01 production-side guard.
//
// silent-failure-hunter (Phase 0 + PR-1 review) surfaced that
// `CachedDataFallback.loadFromCache` has zero production callers — the
// AuditView / HealthCheckView / CustomizationWizard read path runs
// through `CLIBridge.cachedJSONSnapshots`. A JSON-structural validity
// probe in CachedDataFallback alone protected only test-only code. This
// test exercises the production path: a corrupted snapshot dropped into
// `<workspace>/jamf-cli-data/<type>/` must be filtered before reaching
// any decoder.
final class CLIBridgeCachedSnapshotCorruptionTests: XCTestCase {

    nonisolated(unsafe) private var testRoot: URL!
    nonisolated(unsafe) private var savedOverride: String?
    private let profile = "snapshot-corruption-test"

    override func setUpWithError() throws {
        try super.setUpWithError()
        testRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CLIBridgeCachedSnapshotCorruption-\(UUID().uuidString)",
                                    isDirectory: true)
        let workspacesRoot = testRoot.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)

        savedOverride = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
    }

    override func tearDownWithError() throws {
        if let saved = savedOverride {
            setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1)
        } else {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
        }
        if let dir = testRoot {
            try? FileManager.default.removeItem(at: dir)
        }
        testRoot = nil
        try super.tearDownWithError()
    }

    private func snapshotDir(type: String) throws -> URL {
        let dir = testRoot
            .appendingPathComponent("Jamf-Reports", isDirectory: true)
            .appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("jamf-cli-data", isDirectory: true)
            .appendingPathComponent(type, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Valid snapshot returns

    func testValidSnapshotIsReturned() async throws {
        let dir = try snapshotDir(type: "audit")
        let payload = Data(#"[{"section":"summary","data":{"total":42}}]"#.utf8)
        try payload.write(to: dir.appendingPathComponent("audit_20260515T120000.json"))

        let bridge = CLIBridge()
        let snapshots = await bridge.cachedJSONSnapshots(profile: profile, type: "audit", limit: 5)
        XCTAssertEqual(snapshots.count, 1, "A valid JSON snapshot must surface")
        XCTAssertEqual(snapshots.first?.data, payload, "Valid snapshot bytes must round-trip unchanged")
    }

    // MARK: - Truncated snapshot rejected

    func testTruncatedSnapshotIsFilteredOut() async throws {
        let dir = try snapshotDir(type: "audit")
        // Newer truncated file; older valid file.
        let valid = Data(#"[{"section":"summary","data":{"total":1}}]"#.utf8)
        let validURL = dir.appendingPathComponent("audit_20260101T120000.json")
        try valid.write(to: validURL)
        // Backdate the valid file so the corrupted one is "newer" on mtime.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7 * 86400)],
            ofItemAtPath: validURL.path
        )

        let truncated = #"{"summary":{"total":"#  // missing closing braces
        try Data(truncated.utf8)
            .write(to: dir.appendingPathComponent("audit_20260515T120000.json"))

        let bridge = CLIBridge()
        let snapshots = await bridge.cachedJSONSnapshots(profile: profile, type: "audit", limit: 5)
        // Forbidden outcome: truncated bytes returned to caller.
        // Acceptable outcome: corrupted file silently skipped, valid
        // older file returned.
        for snap in snapshots {
            XCTAssertNotEqual(snap.data, Data(truncated.utf8),
                              "Corrupted JSON must never reach the decoder")
        }
        XCTAssertTrue(snapshots.contains(where: { $0.data == valid }),
                      "Valid older snapshot must still be returned even when a newer one is corrupted")
    }

    // MARK: - All-corrupted → empty (does not crash)

    func testAllCorruptedReturnsEmptyWithoutCrash() async throws {
        let dir = try snapshotDir(type: "audit")
        try Data("garbage".utf8)
            .write(to: dir.appendingPathComponent("audit_20260515T120000.json"))
        try Data("{".utf8)
            .write(to: dir.appendingPathComponent("audit_20260514T120000.json"))

        let bridge = CLIBridge()
        let snapshots = await bridge.cachedJSONSnapshots(profile: profile, type: "audit", limit: 5)
        XCTAssertTrue(snapshots.isEmpty,
                      "When every candidate is corrupted, return an empty list — do not surface corrupted bytes")
    }

    // MARK: - Empty list when no snapshots present

    func testNoSnapshotsReturnsEmptyList() async throws {
        let bridge = CLIBridge()
        let snapshots = await bridge.cachedJSONSnapshots(profile: profile, type: "audit", limit: 5)
        XCTAssertTrue(snapshots.isEmpty,
                      "Before any snapshot is written, cachedJSONSnapshots must return an empty list")
    }
}
