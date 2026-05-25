import XCTest
@testable import JamfReports

/// Tests for ``DDMBlueprintService``. Covers the empty path (no cached
/// snapshots on disk), parser round-trip from canonical jamf-cli JSON
/// shapes for both `blueprint-status` and `ddm-status`, aggregate
/// computations, and ``CacheSource`` freshness derivation so
/// `StaleDataBanner` shows the right state.
@MainActor
final class DDMBlueprintServiceTests: XCTestCase {

    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DDMBlueprintServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    // MARK: - Empty paths

    func testLoadWithNonexistentProfileReturnsEmpty() {
        let snapshot = DDMBlueprintService.load(profile: "does-not-exist-\(UUID())")
        XCTAssertEqual(snapshot, DDMBlueprintService.Snapshot.empty)
        XCTAssertEqual(snapshot.totalBlueprints, 0)
        XCTAssertEqual(snapshot.totalDeclarationSources, 0)
    }

    func testLoadWithBothURLsNilReturnsEmptyContent() {
        let snapshot = DDMBlueprintService.load(blueprintsURL: nil, declarationsURL: nil)
        XCTAssertEqual(snapshot.totalBlueprints, 0)
        XCTAssertEqual(snapshot.totalDeclarationSources, 0)
        XCTAssertNil(snapshot.snapshotDate)
    }

    // MARK: - Parser round-trip

    func testLoadDecodesCanonicalBlueprintsShape() throws {
        let blueprintsURL = tempDir.appendingPathComponent("blueprints.json")
        let json = """
        [
          {"name": "Baseline", "state": "DEPLOYED", "scope": 100, "steps": 4,
           "succeeded": 90, "failed": 10, "pending": 0},
          {"name": "Legacy", "state": "NOT_DEPLOYED", "scope": 50, "steps": 1}
        ]
        """
        try Data(json.utf8).write(to: blueprintsURL)
        let snapshot = DDMBlueprintService.load(
            blueprintsURL: blueprintsURL,
            declarationsURL: nil
        )
        XCTAssertEqual(snapshot.blueprints.count, 2)
        XCTAssertEqual(snapshot.blueprints[0].name, "Baseline")
        XCTAssertEqual(snapshot.blueprints[0].failed, 10)
        XCTAssertNil(snapshot.blueprints[1].failed,
                     "Absent `failed` must decode to nil, not 0")
        XCTAssertNil(snapshot.blueprints[1].pending,
                     "Absent `pending` must decode to nil")
    }

    func testLoadDecodesCanonicalDeclarationsShape() throws {
        let declarationsURL = tempDir.appendingPathComponent("ddm.json")
        let json = """
        [
          {"source": "Baseline", "type": "blueprint", "declarations": 4,
           "devices": 100, "successful": 90, "unsuccessful": 10},
          {"source": "", "type": "system", "declarations": 1,
           "devices": 100, "successful": 100, "unsuccessful": 0}
        ]
        """
        try Data(json.utf8).write(to: declarationsURL)
        let snapshot = DDMBlueprintService.load(
            blueprintsURL: nil,
            declarationsURL: declarationsURL
        )
        XCTAssertEqual(snapshot.declarations.count, 2)
        XCTAssertEqual(snapshot.declarations[0].unsuccessful, 10)
        XCTAssertEqual(snapshot.declarations[1].source, "",
                       "Empty source must round-trip without nilling the row")
    }

    // MARK: - Aggregates

    func testAdoptionRateZeroWhenNoBlueprints() {
        XCTAssertEqual(DDMBlueprintService.Snapshot.empty.adoptionRate, 0,
                       "No blueprints means rate is exactly 0 (not NaN)")
    }

    func testAdoptionRateCountsOnlyDeployedState() throws {
        let blueprintsURL = tempDir.appendingPathComponent("bp.json")
        let json = """
        [
          {"name": "A", "state": "DEPLOYED", "scope": 10, "steps": 1},
          {"name": "B", "state": "DEPLOYED", "scope": 10, "steps": 1},
          {"name": "C", "state": "NOT_DEPLOYED", "scope": 10, "steps": 1},
          {"name": "D", "state": "OUT_OF_DATE", "scope": 10, "steps": 1}
        ]
        """
        try Data(json.utf8).write(to: blueprintsURL)
        let snapshot = DDMBlueprintService.load(
            blueprintsURL: blueprintsURL,
            declarationsURL: nil
        )
        XCTAssertEqual(snapshot.adoptionRate, 0.5,
                       "2 of 4 blueprints are DEPLOYED; OUT_OF_DATE does not count")
    }

    func testBlueprintAggregateCountsAllFourBuckets() throws {
        let blueprintsURL = tempDir.appendingPathComponent("bp.json")
        let json = """
        [
          {"name": "A", "state": "DEPLOYED", "scope": 10, "steps": 1,
           "succeeded": 9, "failed": 1, "pending": 0},
          {"name": "B", "state": "DEPLOYED", "scope": 10, "steps": 1,
           "succeeded": 8, "failed": 0, "pending": 2},
          {"name": "C", "state": "NOT_DEPLOYED", "scope": 10, "steps": 1}
        ]
        """
        try Data(json.utf8).write(to: blueprintsURL)
        let snapshot = DDMBlueprintService.load(
            blueprintsURL: blueprintsURL,
            declarationsURL: nil
        )
        let agg = snapshot.blueprintAggregate
        XCTAssertEqual(agg.deployed, 2)
        XCTAssertEqual(agg.notDeployed, 1)
        XCTAssertEqual(agg.failing, 1, "Only A has failed > 0")
        XCTAssertEqual(agg.pending, 1, "Only B has pending > 0")
    }

    func testDeclarationAggregateCountsIssuesAndTotals() throws {
        let declarationsURL = tempDir.appendingPathComponent("ddm.json")
        let json = """
        [
          {"source": "A", "type": "blueprint", "declarations": 4,
           "devices": 10, "successful": 7, "unsuccessful": 3},
          {"source": "B", "type": "system", "declarations": 1,
           "devices": 10, "successful": 10, "unsuccessful": 0},
          {"source": "C", "type": "blueprint", "declarations": 2,
           "devices": 5, "successful": 4, "unsuccessful": 1}
        ]
        """
        try Data(json.utf8).write(to: declarationsURL)
        let snapshot = DDMBlueprintService.load(
            blueprintsURL: nil,
            declarationsURL: declarationsURL
        )
        let agg = snapshot.declarationAggregate
        XCTAssertEqual(agg.sourcesWithIssues, 2, "A and C have unsuccessful > 0")
        XCTAssertEqual(agg.unsuccessfulTotal, 4, "3 + 0 + 1 = 4")
    }

    // MARK: - CacheSource

    func testCacheSourceNeverFetchedWhenNoSnapshotDate() {
        XCTAssertEqual(DDMBlueprintService.Snapshot.empty.cacheSource, .neverFetchedLive)
    }

    func testCacheSourceFreshWithinWindow() throws {
        let blueprintsURL = tempDir.appendingPathComponent("bp.json")
        try Data("[]".utf8).write(to: blueprintsURL)
        let recent = Date(timeIntervalSinceNow: -1800)
        try FileManager.default.setAttributes([.modificationDate: recent],
                                              ofItemAtPath: blueprintsURL.path)
        let snapshot = DDMBlueprintService.load(
            blueprintsURL: blueprintsURL,
            declarationsURL: nil
        )
        XCTAssertEqual(snapshot.cacheSource, .fresh)
    }

    func testCacheSourceStaleBeyondWindow() throws {
        let blueprintsURL = tempDir.appendingPathComponent("bp.json")
        try Data("[]".utf8).write(to: blueprintsURL)
        let stale = Date(timeIntervalSinceNow: -48 * 3600)
        try FileManager.default.setAttributes([.modificationDate: stale],
                                              ofItemAtPath: blueprintsURL.path)
        let snapshot = DDMBlueprintService.load(
            blueprintsURL: blueprintsURL,
            declarationsURL: nil
        )
        if case .stale = snapshot.cacheSource { /* expected */ } else {
            XCTFail("Expected .stale, got \(snapshot.cacheSource)")
        }
    }
}
