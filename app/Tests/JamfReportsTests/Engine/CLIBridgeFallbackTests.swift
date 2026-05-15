import XCTest
@testable import JamfReports

final class CLIBridgeFallbackTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIBridgeFallbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSnapshot(_ data: Data, to dir: URL, name: String) throws {
        let subdir = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try data.write(to: subdir.appendingPathComponent("\(name)_20240101T120000.json"))
    }

    // MARK: - latestCachedJSON

    func testLatestCachedJSONFindsSubdirFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let subdir = dir.appendingPathComponent("security", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let file = subdir.appendingPathComponent("security_20240101.json")
        try Data("{}".utf8).write(to: file)

        let result = CachedDataFallback.latestCachedJSON(cacheNames: ["security"], dataDir: dir)
        XCTAssertEqual(result?.lastPathComponent, "security_20240101.json")
    }

    func testLatestCachedJSONExcludesPartialFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let subdir = dir.appendingPathComponent("overview", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: subdir.appendingPathComponent("overview_partial.json.partial"))
        try Data("{}".utf8).write(to: subdir.appendingPathComponent("overview_20240102.json"))

        let result = CachedDataFallback.latestCachedJSON(cacheNames: ["overview"], dataDir: dir)
        XCTAssertEqual(result?.lastPathComponent, "overview_20240102.json")
    }

    func testLatestCachedJSONReturnsNilWhenNoneExist() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString)", isDirectory: true)
        let result = CachedDataFallback.latestCachedJSON(cacheNames: ["missing"], dataDir: dir)
        XCTAssertNil(result)
    }

    func testLatestCachedJSONPicksNewestByMtime() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let subdir = dir.appendingPathComponent("patch-status", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let older = subdir.appendingPathComponent("patch-status_older.json")
        let newer = subdir.appendingPathComponent("patch-status_newer.json")
        try Data("old".utf8).write(to: older)
        // Small sleep to ensure mtime difference; or set explicit attributes.
        let futureDate = Date().addingTimeInterval(60)
        try Data("new".utf8).write(to: newer)
        try FileManager.default.setAttributes(
            [.modificationDate: futureDate], ofItemAtPath: newer.path
        )

        let result = CachedDataFallback.latestCachedJSON(cacheNames: ["patch-status"], dataDir: dir)
        XCTAssertEqual(result?.lastPathComponent, "patch-status_newer.json")
    }

    // MARK: - runWithFallback: live succeeds

    func testRunWithFallbackUsesLiveDataOnSuccess() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let expected = Data("live-result".utf8)

        let (data, mode) = try await CachedDataFallback.runWithFallback(
            useCachedData: true,
            cacheNames: ["overview"],
            dataDir: dir,
            liveFetch: { expected },
            saveSnapshot: { _ in }
        )
        XCTAssertEqual(data, expected)
        XCTAssertEqual(mode, .live)
    }

    // MARK: - runWithFallback: live fails, use_cached_data=true

    func testRunWithFallbackLoadsCacheOnLiveFailure() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // S-01: CachedDataFallback now rejects non-JSON cached bytes via
        // a structural validity probe. The fixture must be valid JSON
        // for this test to exercise the fallback path rather than the
        // corruption-reject path.
        let cachedPayload = Data(#"["cached-result"]"#.utf8)
        try writeSnapshot(cachedPayload, to: dir, name: "overview")

        let (data, mode) = try await CachedDataFallback.runWithFallback(
            useCachedData: true,
            cacheNames: ["overview"],
            dataDir: dir,
            liveFetch: { throw URLError(.cannotConnectToHost) },
            saveSnapshot: { _ in }
        )
        XCTAssertEqual(data, cachedPayload)
        XCTAssertEqual(mode, .cachedFallback)
    }

    // MARK: - runWithFallback: live fails, use_cached_data=false

    func testRunWithFallbackRethrowsWhenCacheDisabled() async {
        let dir = FileManager.default.temporaryDirectory
        do {
            _ = try await CachedDataFallback.runWithFallback(
                useCachedData: false,
                cacheNames: ["overview"],
                dataDir: dir,
                liveFetch: { throw URLError(.cannotConnectToHost) },
                saveSnapshot: { _ in }
            )
            XCTFail("Expected error to be thrown")
        } catch {
            // Should rethrow the original error, not a CLIFallbackError.noCache.
            XCTAssertTrue(error is URLError)
        }
    }

    // MARK: - runWithFallback: live fails, no cache available

    func testRunWithFallbackThrowsNoCacheWhenCacheMissing() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-cache-\(UUID().uuidString)", isDirectory: true)
        do {
            _ = try await CachedDataFallback.runWithFallback(
                useCachedData: true,
                cacheNames: ["missing-kind"],
                dataDir: dir,
                liveFetch: { throw URLError(.cannotConnectToHost) },
                saveSnapshot: { _ in }
            )
            XCTFail("Expected CLIFallbackError.noCache")
        } catch CachedDataFallback.CLIFallbackError.noCache {
            // Expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - runWithFallback: cache age limit exceeded

    func testRunWithFallbackThrowsCacheExpiredWhenTooOld() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let subdir = dir.appendingPathComponent("security", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let file = subdir.appendingPathComponent("security_old.json")
        try Data("{}".utf8).write(to: file)
        // Set mtime to 48 hours ago.
        let oldDate = Date().addingTimeInterval(-48 * 3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)

        do {
            _ = try await CachedDataFallback.runWithFallback(
                useCachedData: true,
                maxCacheAgeHours: 24,
                cacheNames: ["security"],
                dataDir: dir,
                liveFetch: { throw URLError(.cannotConnectToHost) },
                saveSnapshot: { _ in }
            )
            XCTFail("Expected CLIFallbackError.cacheExpired")
        } catch CachedDataFallback.CLIFallbackError.cacheExpired {
            // Expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - maxCacheAgeHours=0 means no limit

    func testRunWithFallbackZeroAgeHoursMeansNoLimit() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let subdir = dir.appendingPathComponent("security", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let file = subdir.appendingPathComponent("security_veryold.json")
        try Data("{\"ok\":true}".utf8).write(to: file)
        // Set mtime to 1 year ago.
        let oldDate = Date().addingTimeInterval(-365 * 24 * 3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)

        let (_, mode) = try await CachedDataFallback.runWithFallback(
            useCachedData: true,
            maxCacheAgeHours: 0, // no limit
            cacheNames: ["security"],
            dataDir: dir,
            liveFetch: { throw URLError(.cannotConnectToHost) },
            saveSnapshot: { _ in }
        )
        XCTAssertEqual(mode, .cachedFallback)
    }
}
