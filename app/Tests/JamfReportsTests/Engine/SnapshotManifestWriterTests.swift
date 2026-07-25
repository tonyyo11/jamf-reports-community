import Foundation
import XCTest
import CryptoKit
@testable import JamfReports

/// Coverage for the `SnapshotManifest.record` WRITER (2.6 accuracy track).
///
/// Before this writer existed, no Swift code produced snapshot manifests
/// (the only writer was the removed Python collector), so every
/// app-collected snapshot verified `.absent` and the `.mismatch` state was
/// unreachable — the `jamf_cli.require_manifest` strict-mode gate had nothing
/// to satisfy. These tests pin the load-bearing contract: a write→verify
/// round-trip yields `.verified`, tampering after a record yields the
/// previously-unreachable `.mismatch`, and the read-modify-write preserves
/// sibling entries + tolerates a corrupt existing manifest without throwing.
///
/// Fully self-contained: temp dirs + in-memory `Data`; no repo fixtures.
final class SnapshotManifestWriterTests: XCTestCase {

    nonisolated(unsafe) private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotManifestWriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let url = tempRoot {
            try? FileManager.default.removeItem(at: url)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Round-trip: write → verify → .verified

    func testRecordThenVerifyReturnsVerified() throws {
        let snapshot = tempRoot.appendingPathComponent("audit_20260101T000000.json")
        let data = Data(#"{"ok":true}"#.utf8)
        try data.write(to: snapshot)

        try SnapshotManifest.record(snapshotFile: snapshot, data: data)

        let manifestURL = tempRoot.appendingPathComponent(SnapshotManifest.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertEqual(SnapshotManifest.verify(snapshot: snapshot, data: data), .verified)
    }

    // MARK: - The previously-unreachable state: tamper after record → .mismatch

    func testTamperAfterRecordYieldsMismatch() throws {
        let snapshot = tempRoot.appendingPathComponent("security_20260101T000000.json")
        let original = Data(#"{"total_devices":100}"#.utf8)
        try original.write(to: snapshot)

        try SnapshotManifest.record(snapshotFile: snapshot, data: original)

        let tampered = Data(#"{"total_devices":1}"#.utf8)
        try tampered.write(to: snapshot)

        XCTAssertEqual(
            SnapshotManifest.verify(snapshot: snapshot, data: tampered),
            .mismatch
        )
    }

    // MARK: - Schema of the written manifest

    func testWrittenManifestSchema() throws {
        let snapshot = tempRoot.appendingPathComponent("overview_20260101T000000.json")
        let data = Data(#"[1,2,3]"#.utf8)
        try data.write(to: snapshot)

        try SnapshotManifest.record(snapshotFile: snapshot, data: data)

        let manifestURL = tempRoot.appendingPathComponent(SnapshotManifest.fileName)
        let raw = try Data(contentsOf: manifestURL)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: raw) as? [String: Any]
        )

        XCTAssertEqual(obj["version"] as? Int, SnapshotManifest.currentSchemaVersion)
        XCTAssertEqual(obj["algorithm"] as? String, "SHA256")
        let files = try XCTUnwrap(obj["files"] as? [String: String])
        XCTAssertEqual(files[snapshot.lastPathComponent], sha256Hex(data))
        XCTAssertEqual(files.count, 1)
    }

    // MARK: - Read-modify-write preserves sibling entries

    func testSecondRecordPreservesFirstEntry() throws {
        let first = tempRoot.appendingPathComponent("patch-status_20260101T000000.json")
        let firstData = Data(#"{"a":1}"#.utf8)
        try firstData.write(to: first)
        try SnapshotManifest.record(snapshotFile: first, data: firstData)

        let second = tempRoot.appendingPathComponent("patch-status_20260201T000000.json")
        let secondData = Data(#"{"a":2}"#.utf8)
        try secondData.write(to: second)
        try SnapshotManifest.record(snapshotFile: second, data: secondData)

        // Both snapshots verify against the single shared manifest.
        XCTAssertEqual(SnapshotManifest.verify(snapshot: first, data: firstData), .verified)
        XCTAssertEqual(SnapshotManifest.verify(snapshot: second, data: secondData), .verified)

        let manifestURL = tempRoot.appendingPathComponent(SnapshotManifest.fileName)
        let raw = try Data(contentsOf: manifestURL)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let files = try XCTUnwrap(obj["files"] as? [String: String])
        XCTAssertEqual(files.count, 2)
    }

    // MARK: - Re-recording a listed file updates its hash

    func testReRecordUpdatesHash() throws {
        let snapshot = tempRoot.appendingPathComponent("inventory_20260101T000000.json")
        let v1 = Data(#"{"v":1}"#.utf8)
        try v1.write(to: snapshot)
        try SnapshotManifest.record(snapshotFile: snapshot, data: v1)

        // Legitimate re-write of the SAME filename (rare, but the read-modify-
        // write must update the entry rather than keep the stale hash).
        let v2 = Data(#"{"v":2}"#.utf8)
        try v2.write(to: snapshot)
        try SnapshotManifest.record(snapshotFile: snapshot, data: v2)

        XCTAssertEqual(SnapshotManifest.verify(snapshot: snapshot, data: v2), .verified)
        XCTAssertEqual(SnapshotManifest.verify(snapshot: snapshot, data: v1), .mismatch)

        let manifestURL = tempRoot.appendingPathComponent(SnapshotManifest.fileName)
        let raw = try Data(contentsOf: manifestURL)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let files = try XCTUnwrap(obj["files"] as? [String: String])
        XCTAssertEqual(files.count, 1, "re-record must update, not append")
    }

    // MARK: - Corrupt existing manifest → recover, do not throw

    func testCorruptExistingManifestRecovers() throws {
        let snapshot = tempRoot.appendingPathComponent("policies_20260101T000000.json")
        let data = Data(#"{"ok":true}"#.utf8)
        try data.write(to: snapshot)

        // Plant an unparseable manifest.json in the snapshot's dir.
        let manifestURL = tempRoot.appendingPathComponent(SnapshotManifest.fileName)
        try Data("not valid json {".utf8).write(to: manifestURL)

        // Must not throw — a corrupt manifest cannot be allowed to abort collect.
        XCTAssertNoThrow(try SnapshotManifest.record(snapshotFile: snapshot, data: data))

        // The fresh manifest verifies the snapshot.
        XCTAssertEqual(SnapshotManifest.verify(snapshot: snapshot, data: data), .verified)
    }

    // MARK: - Newest-picker must skip the manifest it just wrote (security fix)

    /// After `record`, `manifest.json` is the newest-by-mtime file in the
    /// snapshot-kind dir. `FileManager.newestJSONFile` (the picker behind ~15
    /// dashboard services) must return the SNAPSHOT, not the manifest — else
    /// every consumer decodes the manifest as its data and empties the view.
    func testNewestJSONFileSkipsManifestAfterRecord() throws {
        let snapshot = tempRoot.appendingPathComponent("patch-status_20260101T000000.json")
        let data = Data(#"[{"title":"Firefox"}]"#.utf8)
        try data.write(to: snapshot)

        // record writes manifest.json AFTER the snapshot, so it is newest by mtime.
        try SnapshotManifest.record(snapshotFile: snapshot, data: data)
        let manifestURL = tempRoot.appendingPathComponent(SnapshotManifest.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        // Belt-and-suspenders: force the manifest's mtime strictly newer.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: manifestURL.path
        )

        let newest = FileManager.newestJSONFile(in: tempRoot)
        XCTAssertEqual(newest?.lastPathComponent, snapshot.lastPathComponent)
        XCTAssertNotEqual(newest?.lastPathComponent, SnapshotManifest.fileName)
    }

    /// A directory containing ONLY `manifest.json` has no snapshot to pick — the
    /// picker must return nil, not the manifest.
    func testNewestJSONFileReturnsNilWhenOnlyManifest() throws {
        let manifestURL = tempRoot.appendingPathComponent(SnapshotManifest.fileName)
        try Data(#"{"version":2,"algorithm":"SHA256","files":{}}"#.utf8).write(to: manifestURL)

        XCTAssertNil(FileManager.newestJSONFile(in: tempRoot))
    }

    /// `ReportEngine.loadLatestSnapshotData` applies the same exclusion, but it is
    /// `private static` and not reachable from tests. Its filter is byte-identical
    /// to `newestJSONFile`'s (`lastPathComponent.lowercased() != fileName`), so the
    /// two tests above cover the shared contract. This test pins that the picker's
    /// exclusion is case-insensitive, matching `loadLatestSnapshotData`'s form, so a
    /// `MANIFEST.JSON` on a case-insensitive volume is still skipped.
    func testNewestJSONFileExclusionIsCaseInsensitive() throws {
        let snapshot = tempRoot.appendingPathComponent("security_20260101T000000.json")
        try Data(#"[{"section":"summary"}]"#.utf8).write(to: snapshot)
        let upperManifest = tempRoot.appendingPathComponent("MANIFEST.JSON")
        try Data(#"{"files":{}}"#.utf8).write(to: upperManifest)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: upperManifest.path
        )

        XCTAssertEqual(
            FileManager.newestJSONFile(in: tempRoot)?.lastPathComponent,
            snapshot.lastPathComponent
        )
    }

    // MARK: - Helpers

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
