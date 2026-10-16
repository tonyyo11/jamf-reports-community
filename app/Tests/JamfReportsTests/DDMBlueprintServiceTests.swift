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

    /// jamf-cli leaves the counts out of a blueprint that is not deployed (and scope and steps
    /// out when its detail fetch failed); that is not the same fact as 0.
    func testAbsentBlueprintCountsStayNil() throws {
        let url = tempDir.appendingPathComponent("blueprints-sparse.json")
        try Data(#"[{"name": "Gone", "state": "NOT_DEPLOYED"}]"#.utf8).write(to: url)
        let blueprint = try XCTUnwrap(
            DDMBlueprintService.load(blueprintsURL: url, declarationsURL: nil).blueprints.first)
        XCTAssertNil(blueprint.scope)
        XCTAssertNil(blueprint.steps)
        XCTAssertNil(blueprint.succeeded)
        XCTAssertNil(blueprint.failed)
        XCTAssertNil(blueprint.pending)
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

    // MARK: - Lenient rows

    /// One value of an unexpected type used to empty the whole list; now it costs that field.
    func testAMistypedBlueprintValueCostsItsFieldNotTheList() throws {
        let url = tempDir.appendingPathComponent("blueprints-mistyped.json")
        let json = """
        [
          {"name": "Baseline", "state": "DEPLOYED", "scope": "100", "steps": 4,
           "succeeded": 90, "failed": "ten", "pending": 0},
          {"name": "Legacy", "state": "NOT_DEPLOYED"},
          42
        ]
        """
        try Data(json.utf8).write(to: url)
        let blueprints = DDMBlueprintService.load(blueprintsURL: url, declarationsURL: nil)
            .blueprints
        XCTAssertEqual(blueprints.count, 2, "Only the entry that is not an object is skipped")
        guard blueprints.count == 2 else { return }
        XCTAssertEqual(blueprints[0].scope, 100, "A count written as text is read")
        XCTAssertNil(blueprints[0].failed, "Text that is not a number is unknown, never 0")
        XCTAssertEqual(blueprints[0].succeeded, 90)
        XCTAssertEqual(blueprints[1].name, "Legacy")
    }

    func testAMistypedDeclarationValueCostsItsFieldNotTheList() throws {
        let url = tempDir.appendingPathComponent("ddm-mistyped.json")
        let json = """
        [
          {"source": "Baseline", "type": "blueprint", "declarations": 4,
           "devices": "100", "successful": 90, "unsuccessful": true},
          {"source": 12, "type": "standalone", "declarations": 1,
           "devices": 1, "successful": 1, "unsuccessful": 0}
        ]
        """
        try Data(json.utf8).write(to: url)
        let declarations = DDMBlueprintService.load(blueprintsURL: nil, declarationsURL: url)
            .declarations
        XCTAssertEqual(declarations.count, 2)
        guard declarations.count == 2 else { return }
        XCTAssertEqual(declarations[0].devices, 100)
        XCTAssertEqual(declarations[0].unsuccessful, 0, "An unreadable count keeps its default")
        XCTAssertEqual(declarations[1].source, "12")
    }

    // MARK: - Row identity

    /// A real tenant lists one source under several types, and two blueprints can share a name
    /// or have none; every row must still get its own `ForEach` id.
    func testDeclarationsWithTheSameSourceKeepSeparateIDs() throws {
        let url = tempDir.appendingPathComponent("ddm-dupes.json")
        let json = """
        [
          {"source": "Baseline", "type": "blueprint", "declarations": 4, "devices": 9,
           "successful": 9, "unsuccessful": 0},
          {"source": "Baseline", "type": "standalone", "declarations": 1, "devices": 9,
           "successful": 9, "unsuccessful": 0},
          {"source": "Baseline", "type": "blueprint", "declarations": 2, "devices": 3,
           "successful": 1, "unsuccessful": 2},
          {"source": "", "type": "system", "declarations": 1, "devices": 1,
           "successful": 1, "unsuccessful": 0},
          {"source": "", "type": "system", "declarations": 1, "devices": 1,
           "successful": 1, "unsuccessful": 0}
        ]
        """
        try Data(json.utf8).write(to: url)
        let rows = DDMBlueprintService.load(blueprintsURL: nil, declarationsURL: url).declarations
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(Set(rows.map(\.id)).count, 5, "Every declaration row needs its own id")
        let sorted = DDMBlueprintView.sortedDeclarations(rows)
        XCTAssertEqual(Set(sorted.map(\.id)).count, 5, "Sorting must not merge rows")
    }

    func testBlueprintsWithTheSameOrNoNameKeepSeparateIDs() throws {
        let url = tempDir.appendingPathComponent("bp-dupes.json")
        let json = """
        [
          {"name": "Baseline", "state": "DEPLOYED", "scope": 3, "steps": 1},
          {"name": "Baseline", "state": "DEPLOYED", "scope": 3, "steps": 1},
          {"name": "", "state": "NOT_DEPLOYED"},
          {"state": "NOT_DEPLOYED"}
        ]
        """
        try Data(json.utf8).write(to: url)
        let rows = DDMBlueprintService.load(blueprintsURL: url, declarationsURL: nil).blueprints
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(Set(rows.map(\.id)).count, 4, "Every blueprint row needs its own id")
        XCTAssertEqual(rows.map(\.name), ["Baseline", "Baseline", "", ""],
                       "The displayed name is the file's, unchanged")
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

    // MARK: - Snapshot date

    /// A sync provider rewrites a file's mtime when it downloads it, so each
    /// stamped snapshot is dated by its name, and the screen by the newer one.
    func testSnapshotDateIsTheNewerFilenameStampNotTheMTime() throws {
        let blueprintsURL = tempDir.appendingPathComponent("blueprint-status_20260401T120000.json")
        let declarationsURL = tempDir.appendingPathComponent("ddm-status_20260402T060000.json")
        let resynced = Date(timeIntervalSinceNow: -60)
        for url in [blueprintsURL, declarationsURL] {
            try Data("[]".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: resynced],
                                                  ofItemAtPath: url.path)
        }
        let snapshot = DDMBlueprintService.load(
            blueprintsURL: blueprintsURL,
            declarationsURL: declarationsURL
        )
        let newer = try XCTUnwrap(CloudStorage.snapshotTimestamp(of: declarationsURL))
        XCTAssertEqual(snapshot.snapshotDate, newer)
        XCTAssertNotEqual(snapshot.snapshotDate, resynced)
    }
}
