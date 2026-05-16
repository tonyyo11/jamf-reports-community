import Foundation
import XCTest
import CryptoKit
@testable import JamfReports

/// Coverage for `SnapshotManifest` added by PR-7 Item 4 (Python manifest
/// generation + Swift verification). The Swift side is read-only; we never
/// write the manifest. These tests verify:
///   - Manifest absent → verify is a silent no-op (legacy snapshots).
///   - Manifest matches → verify is a silent no-op (happy path).
///   - Manifest mismatches → verify does not throw (Swift warns rather than
///     aborts; strict mode lives on the Python collector).
///   - Manifest missing this filename → silent no-op (partial collect).
///
/// We cannot directly assert on `AppLogger.engine` output from XCTest, so the
/// shape these tests pin is "no throw, no crash" — the behavioral contract
/// for the Swift side.
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

    // MARK: - Absent manifest = no-op

    func testVerifyNoOpWhenManifestAbsent() throws {
        let snapshot = tempRoot.appendingPathComponent("audit_20260101T000000.json")
        let data = Data(#"{"ok":true}"#.utf8)
        try data.write(to: snapshot)

        let manifest = tempRoot.appendingPathComponent(SnapshotManifest.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))

        // Must not throw, must not crash.
        SnapshotManifest.verify(snapshot: snapshot, data: data)
    }

    // MARK: - Happy path

    func testVerifyAcceptsMatchingHash() throws {
        let snapshot = tempRoot.appendingPathComponent("audit_20260101T000000.json")
        let data = Data(#"{"ok":true}"#.utf8)
        try data.write(to: snapshot)
        try writeManifest(files: [snapshot.lastPathComponent: sha256Hex(data)])

        SnapshotManifest.verify(snapshot: snapshot, data: data)
    }

    // MARK: - Tampered file → does not throw

    /// PR-7 contract: Swift verifier never aborts on mismatch. The Python side
    /// owns the strict-abort policy via `--strict-manifest`. This test pins the
    /// Swift behavior so a future "abort on mismatch" change is caught.
    func testVerifyDoesNotThrowOnMismatch() throws {
        let snapshot = tempRoot.appendingPathComponent("audit_20260101T000000.json")
        let originalData = Data(#"{"ok":true}"#.utf8)
        try originalData.write(to: snapshot)
        try writeManifest(files: [snapshot.lastPathComponent: sha256Hex(originalData)])

        // Tamper after manifest write — pass mutated data to verify.
        let tampered = Data(#"{"ok":false}"#.utf8)
        try tampered.write(to: snapshot)

        // No throw expected — only AppLogger.engine warning is fired.
        SnapshotManifest.verify(snapshot: snapshot, data: tampered)
    }

    // MARK: - Missing entry

    func testVerifyNoOpWhenManifestOmitsThisFile() throws {
        let snapshot = tempRoot.appendingPathComponent("audit_20260101T000000.json")
        let data = Data(#"{"ok":true}"#.utf8)
        try data.write(to: snapshot)

        let other = tempRoot.appendingPathComponent("audit_20260201T000000.json")
        let otherData = Data(#"{"ok":true}"#.utf8)
        try otherData.write(to: other)
        // Manifest only lists "other"; current snapshot has no entry.
        try writeManifest(files: [other.lastPathComponent: sha256Hex(otherData)])

        SnapshotManifest.verify(snapshot: snapshot, data: data)
    }

    // MARK: - Helpers

    private func writeManifest(files: [String: String]) throws {
        let url = tempRoot.appendingPathComponent(SnapshotManifest.fileName)
        let payload: [String: Any] = ["algorithm": "sha256", "files": files]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: url)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
