import XCTest
@testable import JamfReports

/// Tests for ``ComplianceBenchmarksService``. Covers the empty path
/// (no cached snapshots on disk), parser round-trip from canonical
/// jamf-cli JSON shapes, and ``CacheSource`` freshness derivation so
/// `StaleDataBanner` shows the right state.
@MainActor
final class ComplianceBenchmarksServiceTests: XCTestCase {

    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComplianceBenchmarksServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    // MARK: - Empty paths

    func testLoadWithNonexistentProfileReturnsEmpty() {
        let snapshot = ComplianceBenchmarksService.load(profile: "does-not-exist-\(UUID())")
        XCTAssertEqual(snapshot, ComplianceBenchmarksService.Snapshot.empty)
        XCTAssertEqual(snapshot.totalRules, 0)
        XCTAssertEqual(snapshot.totalDevices, 0)
    }

    func testLoadWithBothURLsNilReturnsEmptyContent() {
        let snapshot = ComplianceBenchmarksService.load(rulesURL: nil, devicesURL: nil)
        XCTAssertEqual(snapshot.totalRules, 0)
        XCTAssertEqual(snapshot.totalDevices, 0)
        XCTAssertNil(snapshot.snapshotDate)
    }

    // MARK: - Parser round-trip

    func testLoadDecodesCanonicalRulesShape() throws {
        let rulesURL = tempDir.appendingPathComponent("rules.json")
        let json = """
        [
          {"rule": "FileVault", "passed": 90, "failed": 10, "unknown": 0,
           "devices": 100, "passRate": "90%"},
          {"rule": "Gatekeeper", "passed": 80, "unknown": 0,
           "devices": 100, "passRate": ""}
        ]
        """
        try Data(json.utf8).write(to: rulesURL)
        let snapshot = ComplianceBenchmarksService.load(rulesURL: rulesURL, devicesURL: nil)
        XCTAssertEqual(snapshot.rules.count, 2)
        XCTAssertEqual(snapshot.rules[0].rule, "FileVault")
        XCTAssertEqual(snapshot.rules[0].failed, 10)
        XCTAssertNil(snapshot.rules[1].failed, "Absent `failed` must decode to nil, not 0")
    }

    func testLoadDecodesCanonicalDevicesShape() throws {
        let devicesURL = tempDir.appendingPathComponent("devices.json")
        let json = """
        [
          {"device": "MacA", "deviceId": "1", "rulesFailed": 2, "rulesPassed": 8,
           "compliance": "80%"},
          {"device": "MacB", "deviceId": "2", "rulesPassed": 10, "compliance": "100%"}
        ]
        """
        try Data(json.utf8).write(to: devicesURL)
        let snapshot = ComplianceBenchmarksService.load(rulesURL: nil, devicesURL: devicesURL)
        XCTAssertEqual(snapshot.devices.count, 2)
        XCTAssertEqual(snapshot.devices[0].rulesFailed, 2)
        XCTAssertNil(snapshot.devices[1].rulesFailed,
                     "Absent rulesFailed must decode to nil so the view can show 'unknown'")
    }

    // MARK: - Aggregates

    func testRuleAggregateCountsPassedFailedUnknownWithoutDoubleCount() throws {
        let rulesURL = tempDir.appendingPathComponent("rules.json")
        let json = """
        [
          {"rule": "FileVault", "passed": 90, "failed": 10, "unknown": 0,
           "devices": 100, "passRate": "90%"},
          {"rule": "Firewall", "passed": 80, "failed": 18, "unknown": 2,
           "devices": 100, "passRate": "80%"},
          {"rule": "SecureBoot", "passed": 0, "unknown": 100,
           "devices": 100, "passRate": ""}
        ]
        """
        try Data(json.utf8).write(to: rulesURL)
        let snapshot = ComplianceBenchmarksService.load(rulesURL: rulesURL, devicesURL: nil)
        let agg = snapshot.ruleAggregate
        XCTAssertEqual(agg.passed, 170, "FileVault 90 + Firewall 80 = 170")
        XCTAssertEqual(agg.failed, 28, "FileVault 10 + Firewall 18 = 28")
        // SecureBoot has absent `failed`: 0 passed + 100 unknown = 100.
        // Firewall has present `failed`: only its explicit unknown=2 folds in.
        // FileVault has present `failed`: explicit unknown=0.
        // Total unknown must be 102, never 202 (the pre-fix double-count would inflate).
        XCTAssertEqual(agg.unknown, 102, "Per-rule unknown must not double-count")
    }

    func testDeviceAggregateCountsThreeStates() throws {
        let devicesURL = tempDir.appendingPathComponent("devices.json")
        let json = """
        [
          {"device": "A", "deviceId": "1", "rulesFailed": 3, "rulesPassed": 7, "compliance": "70%"},
          {"device": "B", "deviceId": "2", "rulesFailed": 0, "rulesPassed": 10, "compliance": "100%"},
          {"device": "C", "deviceId": "3", "rulesPassed": 0, "compliance": ""}
        ]
        """
        try Data(json.utf8).write(to: devicesURL)
        let snapshot = ComplianceBenchmarksService.load(rulesURL: nil, devicesURL: devicesURL)
        let agg = snapshot.deviceAggregate
        XCTAssertEqual(agg.failing, 1)
        XCTAssertEqual(agg.passing, 1)
        XCTAssertEqual(agg.unknown, 1)
    }

    // MARK: - CacheSource

    func testCacheSourceNeverFetchedWhenNoSnapshotDate() {
        XCTAssertEqual(ComplianceBenchmarksService.Snapshot.empty.cacheSource, .neverFetchedLive)
    }

    func testCacheSourceFreshWithinWindow() throws {
        let rulesURL = tempDir.appendingPathComponent("rules.json")
        try Data("[]".utf8).write(to: rulesURL)
        let recent = Date(timeIntervalSinceNow: -1800)
        try FileManager.default.setAttributes([.modificationDate: recent],
                                              ofItemAtPath: rulesURL.path)
        let snapshot = ComplianceBenchmarksService.load(rulesURL: rulesURL, devicesURL: nil)
        XCTAssertEqual(snapshot.cacheSource, .fresh)
    }

    func testCacheSourceStaleBeyondWindow() throws {
        let rulesURL = tempDir.appendingPathComponent("rules.json")
        try Data("[]".utf8).write(to: rulesURL)
        let stale = Date(timeIntervalSinceNow: -48 * 3600)
        try FileManager.default.setAttributes([.modificationDate: stale],
                                              ofItemAtPath: rulesURL.path)
        let snapshot = ComplianceBenchmarksService.load(rulesURL: rulesURL, devicesURL: nil)
        if case .stale = snapshot.cacheSource { /* expected */ } else {
            XCTFail("Expected .stale, got \(snapshot.cacheSource)")
        }
    }
}
