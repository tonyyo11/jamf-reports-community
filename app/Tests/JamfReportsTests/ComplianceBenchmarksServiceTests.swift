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

    // MARK: - Lenient rows

    /// One value of an unexpected type used to empty the whole list (`try?` around a strict
    /// array decode); now it costs that field, and a non-object entry costs only itself.
    func testAMistypedValueCostsItsFieldNotTheList() throws {
        let rulesURL = tempDir.appendingPathComponent("rules-mistyped.json")
        let json = """
        [
          {"rule": "FileVault", "passed": "90", "failed": 10, "unknown": 0,
           "devices": 100, "passRate": 90},
          {"rule": "Gatekeeper", "passed": 80, "failed": {"n": 1}, "devices": 100,
           "passRate": "80%"},
          "not a row",
          {"rule": 7, "passed": 1, "failed": null, "devices": 1}
        ]
        """
        try Data(json.utf8).write(to: rulesURL)
        let rules = ComplianceBenchmarksService.load(rulesURL: rulesURL, devicesURL: nil).rules
        XCTAssertEqual(rules.count, 3, "Only the entry that is not an object is skipped")
        guard rules.count == 3 else { return }
        XCTAssertEqual(rules[0].passed, 90, "A count written as text is read")
        XCTAssertEqual(rules[0].passRate, "90", "A number where text is expected reads as text")
        XCTAssertEqual(rules[0].failed, 10)
        XCTAssertNil(rules[1].failed, "An unreadable count is unknown, never 0")
        XCTAssertEqual(rules[1].passRate, "80%")
        XCTAssertEqual(rules[2].rule, "7")
        XCTAssertNil(rules[2].failed)
    }

    func testAMistypedDeviceValueCostsItsFieldNotTheList() throws {
        let devicesURL = tempDir.appendingPathComponent("devices-mistyped.json")
        let json = """
        [
          {"device": "MacA", "deviceId": 1, "rulesPassed": "8", "rulesFailed": "2",
           "compliance": 80},
          {"device": "MacB", "deviceId": "2", "rulesPassed": 10, "rulesFailed": [],
           "compliance": "100%"}
        ]
        """
        try Data(json.utf8).write(to: devicesURL)
        let devices = ComplianceBenchmarksService.load(rulesURL: nil, devicesURL: devicesURL)
            .devices
        XCTAssertEqual(devices.count, 2)
        guard devices.count == 2 else { return }
        XCTAssertEqual(devices[0].deviceId, "1")
        XCTAssertEqual(devices[0].rulesPassed, 8)
        XCTAssertEqual(devices[0].rulesFailed, 2)
        XCTAssertEqual(devices[0].compliance, "80")
        XCTAssertNil(devices[1].rulesFailed)
    }

    func testAFileThatIsNotAListReadsAsNoRows() throws {
        let rulesURL = tempDir.appendingPathComponent("rules-object.json")
        try Data(#"{"error": "permission denied"}"#.utf8).write(to: rulesURL)
        let snapshot = ComplianceBenchmarksService.load(rulesURL: rulesURL, devicesURL: nil)
        XCTAssertTrue(snapshot.rules.isEmpty)
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

    // MARK: - Snapshot date

    /// A sync provider rewrites a file's mtime when it downloads it, so a
    /// stamped snapshot is dated by its name; only an unstamped file uses mtime.
    func testSnapshotDateIsTheFilenameStampNotTheMTime() throws {
        let rulesURL = tempDir.appendingPathComponent("compliance-rules_20260401T120000.json")
        try Data("[]".utf8).write(to: rulesURL)
        let resynced = Date(timeIntervalSinceNow: -60)
        try FileManager.default.setAttributes([.modificationDate: resynced],
                                              ofItemAtPath: rulesURL.path)
        let snapshot = ComplianceBenchmarksService.load(rulesURL: rulesURL, devicesURL: nil)
        let stamp = try XCTUnwrap(CloudStorage.snapshotTimestamp(of: rulesURL))
        XCTAssertEqual(snapshot.snapshotDate, stamp)
        XCTAssertNotEqual(snapshot.snapshotDate, resynced)
        if case .stale = snapshot.cacheSource { /* expected */ } else {
            XCTFail("An April snapshot is stale however recent its mtime")
        }
    }

    // MARK: - Per-benchmark rows (2.8.1)

    func testRowsKeepTheirBenchmarkAndStayUniqueAcrossBenchmarks() throws {
        let rulesURL = tempDir.appendingPathComponent("rules.json")
        let json = """
        [
          {"benchmark": "CIS", "rule": "FileVault", "ruleId": "r1", "passed": 9, "failed": 1,
           "unknown": 0, "devices": 10, "passRate": "90.0%"},
          {"benchmark": "STIG", "rule": "FileVault", "ruleId": "r1", "passed": 5, "failed": 5,
           "unknown": 0, "devices": 10, "passRate": "50.0%"}
        ]
        """
        try Data(json.utf8).write(to: rulesURL)
        let snapshot = ComplianceBenchmarksService.load(rulesURL: rulesURL, devicesURL: nil)
        XCTAssertEqual(snapshot.rules.map(\.benchmark), ["CIS", "STIG"])
        XCTAssertEqual(Set(snapshot.rules.map(\.id)).count, 2,
                       "duplicate ForEach IDs crash SwiftUI (#185)")
        XCTAssertEqual(snapshot.benchmarks, ["CIS", "STIG"])
    }

    func testFilteredKeepsOneBenchmarksRows() throws {
        let devicesURL = tempDir.appendingPathComponent("devices.json")
        let json = """
        [
          {"benchmark": "CIS", "device": "MacA", "deviceId": "1", "rulesPassed": 9,
           "rulesFailed": 1, "compliance": "90%"},
          {"benchmark": "STIG", "device": "MacA", "deviceId": "1", "rulesPassed": 5,
           "rulesFailed": 5, "compliance": "50%"}
        ]
        """
        try Data(json.utf8).write(to: devicesURL)
        let snapshot = ComplianceBenchmarksService.load(rulesURL: nil, devicesURL: devicesURL)
        let stig = snapshot.filtered(to: "STIG")
        XCTAssertEqual(stig.devices.map(\.benchmark), ["STIG"])
        XCTAssertEqual(stig.totalDevices, 1)
    }

    func testSnapshotsWithoutABenchmarkFieldHaveNoBenchmarks() throws {
        let rulesURL = tempDir.appendingPathComponent("rules.json")
        try Data(#"[{"rule": "FileVault", "passed": 1}]"#.utf8).write(to: rulesURL)
        let snapshot = ComplianceBenchmarksService.load(rulesURL: rulesURL, devicesURL: nil)
        XCTAssertEqual(snapshot.benchmarks, [])
    }

    // MARK: - Ranking

    private func rule(_ name: String, failed: Int?) -> ComplianceBenchmarksService.Snapshot.Rule {
        .init(rule: name, passed: 5, failed: failed, unknown: 0, devices: 5, passRate: "")
    }

    private func device(_ name: String,
                        failed: Int?) -> ComplianceBenchmarksService.Snapshot.Device {
        .init(device: name, deviceId: name, rulesPassed: 5, rulesFailed: failed, compliance: "")
    }

    func testRulesRankMostFailuresFirstUnknownLastTiesByName() {
        let ranked = ComplianceBenchmarksService.rankedRules([
            rule("zeta", failed: 0),
            rule("unknown-b", failed: nil),
            rule("Beta", failed: 3),
            rule("alpha", failed: 3),
            rule("worst", failed: 12),
            rule("unknown-a", failed: nil),
        ])
        XCTAssertEqual(ranked.map(\.rule),
                       ["worst", "alpha", "Beta", "zeta", "unknown-a", "unknown-b"])
    }

    func testRankedRulesKeepEveryRowAndBreakNameTiesByID() {
        let twin = { (id: String) in
            ComplianceBenchmarksService.Snapshot.Rule(
                rule: "Same", passed: 1, failed: 2, unknown: 0, devices: 1, passRate: "",
                ruleId: id, benchmark: "CIS")
        }
        let ranked = ComplianceBenchmarksService.rankedRules([twin("b"), twin("a")])
        XCTAssertEqual(ranked.map(\.ruleId), ["a", "b"])
    }

    func testDevicesRankMostFailedRulesFirstUnknownLastTiesByName() {
        let ranked = ComplianceBenchmarksService.rankedDevices([
            device("Mac-Z", failed: 0),
            device("Mac-U", failed: nil),
            device("mac-b", failed: 4),
            device("Mac-A", failed: 4),
            device("Mac-W", failed: 20),
        ])
        XCTAssertEqual(ranked.map(\.device), ["Mac-W", "Mac-A", "mac-b", "Mac-Z", "Mac-U"])
    }

    /// A failing rule that jamf-cli listed past the screen's cut still makes the cut.
    func testFailingRuleBeyondTheCutIsRankedIntoTheTopTwenty() {
        let rules = (0..<30).map { rule("rule-\($0)", failed: $0 == 27 ? 9 : 0) }
        let shownNames = ComplianceBenchmarksService.rankedRules(rules).prefix(20).map(\.rule)
        XCTAssertEqual(shownNames.first, "rule-27")
    }
}
