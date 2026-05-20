import Foundation
import XCTest
@testable import JamfReports

// Tests for S-01 from review/REPORT.md: CLIBridge.saveJSONSnapshot wrote
// the snapshot non-atomically while every sibling write in the file used
// .atomic. A crash, OOM, or full-disk mid-write left a truncated
// "<type>_<ts>.json" that CachedDataFallback could not distinguish from a
// valid snapshot — the next live-failure fallback path loaded partial
// data while the run rendered green.
//
// These tests exercise the read side: a truncated JSON file in the cache
// directory must be rejected, not returned as a "valid cached snapshot".
// The write side (atomic flag) is verified by inspection of the source;
// the read-side guard is the durable defense.
final class CachedDataFallbackCorruptionTests: XCTestCase {

    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CachedDataFallbackCorruptionTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Truncated JSON in flat layout

    func testTruncatedFlatLayoutSnapshotIsRejected() throws {
        // Drop a truncated JSON file matching the flat layout pattern:
        // <dataDir>/<name>_<ts>.json
        let truncated = #"{"summary": {"total_devices":"# // missing closing brace
        let file = tempDir.appendingPathComponent("overview_20260515T120000.json")
        try Data(truncated.utf8).write(to: file)

        // The cached-only path should refuse to return this file as a
        // valid snapshot. Either throw noCache (preferred) or throw a
        // dedicated corrupted-snapshot error.
        XCTAssertThrowsError(
            try CachedDataFallback.loadCachedOnly(
                cacheNames: ["overview"],
                dataDir: tempDir
            ),
            "loadCachedOnly must reject a truncated JSON snapshot rather than returning corrupted bytes"
        )
    }

    // MARK: - Truncated JSON in subdirectory layout

    func testTruncatedSubdirSnapshotIsRejected() throws {
        // Drop a truncated JSON file matching the subdirectory pattern:
        // <dataDir>/<name>/<ts>.json
        let subdir = tempDir.appendingPathComponent("overview", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let truncated = #"["#  // an open bracket with no close — clearly invalid
        let file = subdir.appendingPathComponent("20260515T120000.json")
        try Data(truncated.utf8).write(to: file)

        XCTAssertThrowsError(
            try CachedDataFallback.loadCachedOnly(
                cacheNames: ["overview"],
                dataDir: tempDir
            ),
            "loadCachedOnly must reject a truncated subdirectory-layout snapshot"
        )
    }

    // MARK: - Valid JSON still works

    func testValidSnapshotIsAccepted() throws {
        // Sanity: a syntactically valid JSON payload should still load
        // — the corruption guard must not over-reject.
        let valid = #"[{"section":"summary","data":{"total_devices":47}}]"#
        let file = tempDir.appendingPathComponent("overview_20260515T120000.json")
        try Data(valid.utf8).write(to: file)

        let (data, source) = try CachedDataFallback.loadCachedOnly(
            cacheNames: ["overview"],
            dataDir: tempDir
        )
        XCTAssertEqual(data, Data(valid.utf8),
                       "Valid JSON snapshot must be returned unmodified")
        XCTAssertEqual(source, .cachedFallback)
    }

    // MARK: - Mixed: corrupted newest, valid older — must fall to valid older

    func testCorruptedNewestFallsThroughToValidOlder() throws {
        // Two snapshots in the same cache dir; newest is corrupted, older
        // is valid. The guard should skip the corrupted file and return
        // the older valid one. (If the implementation simply throws on
        // corruption, that is also acceptable — the comment explains why
        // either behavior satisfies the safety invariant. The test marks
        // the *acceptable* behavior as: corrupted bytes never reach the
        // caller.)
        let older = #"[{"section":"summary","data":{"total_devices":1}}]"#
        let olderFile = tempDir.appendingPathComponent("overview_20260101T120000.json")
        try Data(older.utf8).write(to: olderFile)
        // Backdate the older file so the newer truncated one wins on mtime.
        let oldDate = Date().addingTimeInterval(-7 * 86400)
        try FileManager.default.setAttributes([.modificationDate: oldDate],
                                              ofItemAtPath: olderFile.path)

        let truncated = #"{"summary"#
        let newerFile = tempDir.appendingPathComponent("overview_20260515T120000.json")
        try Data(truncated.utf8).write(to: newerFile)

        // Either:
        //   (a) The implementation throws — caller gets a clear error and
        //       no corrupted bytes are returned.
        //   (b) The implementation falls through to the valid older file
        //       and returns its bytes.
        // Both are correct outcomes for the safety invariant. The
        // forbidden outcome is "returns the truncated bytes". The test
        // accepts (a) or (b) but rejects the forbidden outcome.
        do {
            let (data, _) = try CachedDataFallback.loadCachedOnly(
                cacheNames: ["overview"],
                dataDir: tempDir
            )
            XCTAssertNotEqual(data, Data(truncated.utf8),
                              "Must never return the truncated newer file as-is")
            XCTAssertEqual(data, Data(older.utf8),
                           "If fallback fell through, it must return the valid older snapshot")
        } catch {
            // Throwing is the conservative-correct behavior; accept it.
        }
    }
}
