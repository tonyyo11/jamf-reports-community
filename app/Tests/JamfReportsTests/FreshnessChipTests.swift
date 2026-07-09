import XCTest
@testable import JamfReports

/// 2.6 trust trio #3: per-kind freshness + a real `max_cache_age_hours`.
/// Covers the config decode + resolved-default semantics, the
/// CachedDataFallback age gate, per-kind `sourceDates` population, and the
/// pure relative-label formatter behind `FreshnessChipRow`.
final class FreshnessChipTests: XCTestCase {

    // MARK: - JamfCLIConfig.resolvedMaxCacheAgeHours

    func testMaxCacheAgeHoursPresentDecodes() throws {
        let json = #"{"max_cache_age_hours": 72}"#
        let cfg = try JSONDecoder().decode(JamfCLIConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.maxCacheAgeHours, 72)
        XCTAssertEqual(cfg.resolvedMaxCacheAgeHours, 72)
    }

    func testMaxCacheAgeHoursAbsentDefaultsTo168() throws {
        let json = #"{"profile": "acme"}"#
        let cfg = try JSONDecoder().decode(JamfCLIConfig.self, from: Data(json.utf8))
        XCTAssertNil(cfg.maxCacheAgeHours)
        // New default: ancient cache surfaces instead of rendering as current.
        XCTAssertEqual(cfg.resolvedMaxCacheAgeHours, 168)
    }

    func testMaxCacheAgeHoursZeroMeansUnlimited() throws {
        let json = #"{"max_cache_age_hours": 0}"#
        let cfg = try JSONDecoder().decode(JamfCLIConfig.self, from: Data(json.utf8))
        // 0 is returned verbatim; downstream treats <= 0 as no age limit.
        XCTAssertEqual(cfg.resolvedMaxCacheAgeHours, 0)
    }

    func testMaxCacheAgeHoursNegativeReturnedVerbatim() throws {
        let json = #"{"max_cache_age_hours": -1}"#
        let cfg = try JSONDecoder().decode(JamfCLIConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.resolvedMaxCacheAgeHours, -1)
    }

    // MARK: - CachedDataFallback age gate (temp-dir fixture)

    private func makeCacheDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreshnessChipTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeSnapshot(in dir: URL, kind: String, ageHours: Double) throws -> URL {
        let subdir = dir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let file = subdir.appendingPathComponent("\(kind)_fixture.json")
        try Data(#"{"ok": true}"#.utf8).write(to: file)
        let mtime = Date().addingTimeInterval(-ageHours * 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: mtime], ofItemAtPath: file.path
        )
        return file
    }

    func testCacheWithinLimitLoads() async throws {
        let dir = try makeCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeSnapshot(in: dir, kind: "security", ageHours: 2)

        let (_, mode) = try await CachedDataFallback.runWithFallback(
            useCachedData: true,
            maxCacheAgeHours: 168,
            cacheNames: ["security"],
            dataDir: dir,
            liveFetch: { throw URLError(.cannotConnectToHost) },
            saveSnapshot: { _ in }
        )
        XCTAssertEqual(mode, .cachedFallback)
    }

    func testCacheOlderThanLimitThrowsExpired() async throws {
        let dir = try makeCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 200h old exceeds the 168h limit.
        _ = try writeSnapshot(in: dir, kind: "security", ageHours: 200)

        do {
            _ = try await CachedDataFallback.runWithFallback(
                useCachedData: true,
                maxCacheAgeHours: 168,
                cacheNames: ["security"],
                dataDir: dir,
                liveFetch: { throw URLError(.cannotConnectToHost) },
                saveSnapshot: { _ in }
            )
            XCTFail("Expected CLIFallbackError.cacheExpired")
        } catch CachedDataFallback.CLIFallbackError.cacheExpired(_, let limit) {
            XCTAssertEqual(limit, 168)
        }
    }

    func testCacheZeroLimitNeverExpires() async throws {
        let dir = try makeCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A year old, but the limit is 0 (unlimited) so it still loads.
        _ = try writeSnapshot(in: dir, kind: "security", ageHours: 24 * 365)

        let (_, mode) = try await CachedDataFallback.runWithFallback(
            useCachedData: true,
            maxCacheAgeHours: 0,
            cacheNames: ["security"],
            dataDir: dir,
            liveFetch: { throw URLError(.cannotConnectToHost) },
            saveSnapshot: { _ in }
        )
        XCTAssertEqual(mode, .cachedFallback)
    }

    // MARK: - Per-kind sourceDates (UpdateStatusService — easiest to drive file-based)

    func testUpdateStatusSummaryOnlyPopulatesSingleSourceDate() throws {
        let json = """
        [
          {
            "total": 10,
            "status_summary": [{"status": "COMPLETED", "count": 10}],
            "plan_total": 2,
            "plan_state_summary": [{"state": "PlanCompleted", "count": 2}]
          }
        ]
        """
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-status-src-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let snapshot = try XCTUnwrap(UpdateStatusService.load(from: tmp))
        XCTAssertFalse(snapshot.scanFailuresAvailable)
        // Summary-only carries the update-status kind; not the scan kind.
        XCTAssertNotNil(snapshot.sourceDates["update-status"])
        XCTAssertNil(snapshot.sourceDates["update-device-failures"])
    }

    func testUpdateStatusScanFailuresPopulatesBothSourceDates() throws {
        let json = """
        [
          {
            "total": 10,
            "status_summary": [{"status": "ERROR", "count": 3}],
            "error_devices": [
              {"name": "Mac-1", "serial": "S1", "device_type": "computer",
               "os_version": "15.0", "username": "u", "status": "ERROR",
               "product_key": "k", "updated": "2026-07-01"}
            ],
            "plan_total": 2,
            "plan_state_summary": [{"state": "PlanFailed", "count": 1}],
            "failed_plans": [
              {"name": "Mac-1", "serial": "S1", "device_type": "computer",
               "os_version": "15.0", "username": "u", "state": "PlanFailed",
               "action": "a", "version": "1", "error": "e", "last_event": "2026-07-01"}
            ]
          }
        ]
        """
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-scan-src-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let snapshot = try XCTUnwrap(UpdateStatusService.load(from: tmp))
        XCTAssertTrue(snapshot.scanFailuresAvailable)
        XCTAssertNotNil(snapshot.sourceDates["update-status"])
        XCTAssertNotNil(snapshot.sourceDates["update-device-failures"])
    }

    // MARK: - FreshnessChipRow pure formatting

    func testRelativeLabelJustNow() {
        let now = Date()
        XCTAssertEqual(
            FreshnessChipRow.relativeLabel(for: now.addingTimeInterval(-600), now: now),
            "just now"
        )
    }

    func testRelativeLabelHours() {
        let now = Date()
        XCTAssertEqual(
            FreshnessChipRow.relativeLabel(for: now.addingTimeInterval(-5 * 3600), now: now),
            "5h ago"
        )
    }

    func testRelativeLabelDays() {
        let now = Date()
        XCTAssertEqual(
            FreshnessChipRow.relativeLabel(for: now.addingTimeInterval(-3 * 24 * 3600), now: now),
            "3d ago"
        )
    }

    func testRelativeLabelFutureClampsToJustNow() {
        let now = Date()
        // A future mtime (clock skew) must not produce a negative label.
        XCTAssertEqual(
            FreshnessChipRow.relativeLabel(for: now.addingTimeInterval(3600), now: now),
            "just now"
        )
    }

    // MARK: - FreshnessChipRow.chipModels (2.6 — absent-kind "never" chips)

    func testChipModelsExpectedAndPresentYieldsPresentChip() {
        let now = Date()
        let date = now.addingTimeInterval(-3600)
        let models = FreshnessChipRow.chipModels(
            sourceDates: ["security": date],
            expectedKinds: ["security"],
            now: now
        )
        XCTAssertEqual(models, [FreshnessChipRow.ChipModel(kind: "security", state: .present(date))])
    }

    func testChipModelsExpectedAndAbsentYieldsNeverChip() {
        let models = FreshnessChipRow.chipModels(
            sourceDates: [:],
            expectedKinds: ["patch-device-failures"]
        )
        XCTAssertEqual(
            models,
            [FreshnessChipRow.ChipModel(kind: "patch-device-failures", state: .absent)]
        )
    }

    func testChipModelsNotExpectedAndAbsentYieldsNoChip() {
        // A kind that's simply not read by this screen (not in expectedKinds)
        // must not appear at all — only present or expected-but-missing kinds render.
        let models = FreshnessChipRow.chipModels(
            sourceDates: [:],
            expectedKinds: []
        )
        XCTAssertTrue(models.isEmpty)
    }

    func testChipModelsMixedPresentAndAbsentSortedByKind() {
        let now = Date()
        let date = now.addingTimeInterval(-7200)
        let models = FreshnessChipRow.chipModels(
            sourceDates: ["update-status": date],
            expectedKinds: ["update-status", "update-device-failures"],
            now: now
        )
        XCTAssertEqual(models, [
            FreshnessChipRow.ChipModel(kind: "update-device-failures", state: .absent),
            FreshnessChipRow.ChipModel(kind: "update-status", state: .present(date)),
        ])
    }
}
