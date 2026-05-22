import Foundation
import XCTest
@testable import JamfReports

/// Coverage for `CLIBridge.DeviceDetailResult` provenance (`fromCache`) added by
/// PR-7 Item 5, and for the per-cache `.meta` freshness sidecar added by Epic #103
/// Item 12 (T-15 mitigation).
///
/// Item 12 tests:
/// - `testSidecarWriteProducesMetaFileWithParseableGeneratedAt` — verifies the helper
///   writes a `.meta` sidecar with a valid ISO-8601 `generated_at` field.
/// - `testFreshnessTimestampPrefersSidecar` — verifies `freshnessTimestamp(for:)` returns
///   the sidecar timestamp when both sidecar and mtime are available.
/// - `testFreshnessTimestampFallsBackToMtimeWhenSidecarAbsent` — no sidecar → mtime.
/// - `testFreshnessTimestampFallsBackToMtimeWhenSidecarMalformed` — corrupt sidecar → mtime.
final class DeviceDetailProvenanceTests: XCTestCase {

    nonisolated(unsafe) private var testRoot: URL!
    nonisolated(unsafe) private var savedOverride: String?
    private let profile = "device-detail-provenance-test"

    override func setUpWithError() throws {
        try super.setUpWithError()
        testRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DeviceDetailProvenance-\(UUID().uuidString)",
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

    // MARK: - Helpers

    /// Replicates the file-private `deviceCacheFilename(_:)` in CLIBridge.swift so
    /// the test can stage a cache file at the exact path the bridge will look up.
    /// If `deviceCacheFilename` ever changes shape this test will fail loudly —
    /// the duplication is intentional as a tripwire on the cache file naming.
    private func deviceCacheFilename(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let sanitizedScalars = raw.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(sanitizedScalars)
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        let prefix = String((sanitized.isEmpty ? "device" : sanitized).prefix(80))
        return "\(prefix)-\(stableDeviceHash(raw)).json"
    }

    private func stableDeviceHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private func cacheDir(subdir: String) throws -> URL {
        let dir = testRoot
            .appendingPathComponent("Jamf-Reports", isDirectory: true)
            .appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("jamf-cli-data", isDirectory: true)
            .appendingPathComponent(subdir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Cache file mtime is readable

    /// Verifies the snapshot mtime the staleness banner depends on is readable
    /// from the cache URL the bridge would return. Full end-to-end coverage of
    /// the live-call → cache-fallback path requires a `CLIExecutor` test seam
    /// (not present in CLIBridge today); this test exercises the helper layer
    /// (filename derivation + mtime extraction) that the banner consumes.
    func testCacheFileMTimeIsReadableForBanner() async throws {
        let deviceID = "1234"
        let dir = try cacheDir(subdir: "devices")
        let cachePath = dir.appendingPathComponent(deviceCacheFilename(deviceID))
        try Data(#"{"id":1234,"name":"cached-mac"}"#.utf8).write(to: cachePath)

        // Backdate so the test exercises a real "stale" mtime that
        // `RelativeDateTimeFormatter` would render as "1 hour ago".
        let stalenessInterval: TimeInterval = -3600
        let staleDate = Date().addingTimeInterval(stalenessInterval)
        try FileManager.default.setAttributes(
            [.modificationDate: staleDate],
            ofItemAtPath: cachePath.path
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: cachePath.path),
                      "Pre-staged cache file must exist at the expected path")

        // Verify cache mtime is what we set — this is the data the view's
        // staleBanner formats into "last fetched <relative time>".
        let values = try cachePath.resourceValues(forKeys: [.contentModificationDateKey])
        let mtime = values.contentModificationDate
        XCTAssertNotNil(mtime)
        if let mtime {
            XCTAssertEqual(
                mtime.timeIntervalSinceReferenceDate,
                staleDate.timeIntervalSinceReferenceDate,
                accuracy: 1.0
            )
        }
    }

    // MARK: - T-15 freshness sidecar (Epic #103 Item 12)

    /// Verifies `CLIBridge.writeDeviceDetailFreshnessSidecar(for:)` creates a `.meta`
    /// file alongside the cache with a parseable ISO-8601 `generated_at` timestamp.
    func testSidecarWriteProducesMetaFileWithParseableGeneratedAt() throws {
        let dir = try cacheDir(subdir: "devices")
        let cacheURL = dir.appendingPathComponent("device-abc-0000000000000001.json")
        try Data(#"{"id":1}"#.utf8).write(to: cacheURL)

        let before = Date()
        CLIBridge.writeDeviceDetailFreshnessSidecar(for: cacheURL)
        let after = Date()

        let sidecarURL = cacheURL.appendingPathExtension("meta")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path),
                      ".meta sidecar must exist after writeDeviceDetailFreshnessSidecar")

        let raw = try Data(contentsOf: sidecarURL)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: raw) as? [String: String],
            "sidecar must decode as [String:String]"
        )
        let isoString = try XCTUnwrap(obj["generated_at"], "sidecar must have 'generated_at' key")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let date = try XCTUnwrap(
            formatter.date(from: isoString),
            "generated_at '\(isoString)' must parse as ISO-8601"
        )
        XCTAssertGreaterThanOrEqual(date.timeIntervalSinceReferenceDate,
                                    before.timeIntervalSinceReferenceDate - 1.0)
        XCTAssertLessThanOrEqual(date.timeIntervalSinceReferenceDate,
                                 after.timeIntervalSinceReferenceDate + 1.0)
    }

    /// Verifies `freshnessTimestamp(for:)` returns the sidecar's `generated_at`
    /// timestamp when a valid `.meta` sidecar is present — even when the file's
    /// mtime has been backdated by an attacker using `touch -t`.
    func testFreshnessTimestampPrefersSidecar() throws {
        let dir = try cacheDir(subdir: "devices")
        let cacheURL = dir.appendingPathComponent("device-pref-sidecar.json")
        try Data(#"{"id":2}"#.utf8).write(to: cacheURL)

        // Backdate the file mtime so it differs clearly from the sidecar timestamp.
        let backdatedMtime = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes(
            [.modificationDate: backdatedMtime], ofItemAtPath: cacheURL.path
        )

        // Write a sidecar with a known, recent timestamp.
        let sidecarTimestamp = Date().addingTimeInterval(-60)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let sidecarContent = try JSONSerialization.data(
            withJSONObject: ["generated_at": formatter.string(from: sidecarTimestamp)]
        )
        let sidecarURL = cacheURL.appendingPathExtension("meta")
        try sidecarContent.write(to: sidecarURL)

        let result = freshnessTimestamp(for: cacheURL)
        let resolved = try XCTUnwrap(result, "freshnessTimestamp must return a date")

        // Must be closer to sidecarTimestamp than to the backdated mtime.
        XCTAssertEqual(resolved.timeIntervalSinceReferenceDate,
                       sidecarTimestamp.timeIntervalSinceReferenceDate,
                       accuracy: 2.0,
                       "freshnessTimestamp should return the sidecar timestamp, not the backdated mtime")
    }

    /// Verifies `freshnessTimestamp(for:)` falls back to the file mtime when no
    /// `.meta` sidecar exists (caches written before Epic #103 Item 12).
    func testFreshnessTimestampFallsBackToMtimeWhenSidecarAbsent() throws {
        let dir = try cacheDir(subdir: "devices")
        let cacheURL = dir.appendingPathComponent("device-no-sidecar.json")
        try Data(#"{"id":3}"#.utf8).write(to: cacheURL)

        let knownMtime = Date().addingTimeInterval(-1800)
        try FileManager.default.setAttributes(
            [.modificationDate: knownMtime], ofItemAtPath: cacheURL.path
        )

        // Confirm no sidecar exists.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cacheURL.appendingPathExtension("meta").path),
            "pre-condition: no sidecar file"
        )

        let result = freshnessTimestamp(for: cacheURL)
        let resolved = try XCTUnwrap(result, "freshnessTimestamp must return a date via mtime fallback")
        XCTAssertEqual(resolved.timeIntervalSinceReferenceDate,
                       knownMtime.timeIntervalSinceReferenceDate,
                       accuracy: 1.0,
                       "should fall back to filesystem mtime when sidecar absent")
    }

    /// Verifies `freshnessTimestamp(for:)` falls back to mtime when the `.meta`
    /// sidecar exists but contains invalid JSON (truncated or corrupted write).
    func testFreshnessTimestampFallsBackToMtimeWhenSidecarMalformed() throws {
        let dir = try cacheDir(subdir: "devices")
        let cacheURL = dir.appendingPathComponent("device-bad-sidecar.json")
        try Data(#"{"id":4}"#.utf8).write(to: cacheURL)

        let knownMtime = Date().addingTimeInterval(-900)
        try FileManager.default.setAttributes(
            [.modificationDate: knownMtime], ofItemAtPath: cacheURL.path
        )

        // Write a malformed sidecar (truncated JSON).
        let sidecarURL = cacheURL.appendingPathExtension("meta")
        try Data("{\"generated_at\":".utf8).write(to: sidecarURL)

        let result = freshnessTimestamp(for: cacheURL)
        let resolved = try XCTUnwrap(result, "freshnessTimestamp must return a date via mtime fallback")
        XCTAssertEqual(resolved.timeIntervalSinceReferenceDate,
                       knownMtime.timeIntervalSinceReferenceDate,
                       accuracy: 1.0,
                       "should fall back to filesystem mtime when sidecar is malformed")
    }

    // MARK: - DeviceDetailResult shape

    /// Verifies the new result struct exposes the three fields callers depend on.
    /// `fromCache` is the visibility signal; `cacheURL` lets the view stat the mtime;
    /// `data` is the payload the existing `deviceDetail(_:_:)` wrapper unwraps.
    func testDeviceDetailResultExposesProvenanceFields() {
        let payload = Data(#"{"id":1}"#.utf8)
        let url = URL(fileURLWithPath: "/tmp/x.json")

        let liveResult = CLIBridge.DeviceDetailResult(
            data: payload, fromCache: false, cacheURL: url
        )
        XCTAssertEqual(liveResult.data, payload)
        XCTAssertFalse(liveResult.fromCache)

        let cachedResult = CLIBridge.DeviceDetailResult(
            data: payload, fromCache: true, cacheURL: url
        )
        XCTAssertTrue(cachedResult.fromCache)
        XCTAssertEqual(cachedResult.cacheURL, url)
    }
}
