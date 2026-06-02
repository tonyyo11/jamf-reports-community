import XCTest
@testable import JamfReports

/// v2.2.0 launch-freshness features: Overview score-card persistence,
/// heavy-tier staleness detection, and the include-audit generate preference.
final class LaunchFreshnessTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: WorkspaceStore.scoreCardsKey)
        UserDefaults.standard.removeObject(forKey: GenerateSheetState.includeAuditKey)
        super.tearDown()
    }

    // MARK: - Score-card selection persistence

    func testScoreCardSelectionRoundTrips() {
        let selection: [TrendSeries.Metric] = [
            .stability, .activeDevices, .fileVault, .patch, .securityScore, .stale,
        ]
        WorkspaceStore.persistScoreCards(selection)
        XCTAssertEqual(WorkspaceStore.loadPersistedScoreCards(), selection)
    }

    func testScoreCardLoadReturnsNilWhenNothingPersisted() {
        UserDefaults.standard.removeObject(forKey: WorkspaceStore.scoreCardsKey)
        XCTAssertNil(WorkspaceStore.loadPersistedScoreCards())
    }

    func testScoreCardLoadIgnoresUnknownMetrics() {
        UserDefaults.standard.set(
            "stability,not-a-real-metric,patch", forKey: WorkspaceStore.scoreCardsKey
        )
        XCTAssertEqual(WorkspaceStore.loadPersistedScoreCards(), [.stability, .patch])
    }

    func testScoreCardLoadReturnsNilForAllUnknownMetrics() {
        UserDefaults.standard.set("bogus,also-bogus", forKey: WorkspaceStore.scoreCardsKey)
        XCTAssertNil(WorkspaceStore.loadPersistedScoreCards())
    }

    /// More than four metrics must round-trip — the v2.2.0 change removed the
    /// CustomizeView selection cap.
    func testMoreThanFourScoreCardsPersist() {
        let all = TrendSeries.Metric.allCases
        WorkspaceStore.persistScoreCards(all)
        XCTAssertEqual(WorkspaceStore.loadPersistedScoreCards(), all)
        XCTAssertGreaterThan(all.count, 4)
    }

    // MARK: - Heavy-tier staleness

    func testStaleTiersDetectsWeekOldData() throws {
        let profile = "stalet\(Int.random(in: 10_000...99_999))"
        guard let root = WorkspacePathGuard.root(for: profile) else {
            throw XCTSkip("workspace root unavailable for test profile")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        // .inventory probe kind = "computers" (8 days old → stale)
        // .scan probe kind = "ea-results" (1 day old → fresh)
        let computersDir = dataDir.appendingPathComponent("computers", isDirectory: true)
        let eaDir = dataDir.appendingPathComponent("ea-results", isDirectory: true)
        try FileManager.default.createDirectory(at: computersDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: eaDir, withIntermediateDirectories: true)

        let oldFile = computersDir.appendingPathComponent("computers_old.json")
        try "[]".write(to: oldFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -8 * 86_400)],
            ofItemAtPath: oldFile.path
        )
        let freshFile = eaDir.appendingPathComponent("ea_fresh.json")
        try "[]".write(to: freshFile, atomically: true, encoding: .utf8)

        let stale = WorkspaceStore.staleTiers(profile: profile, olderThan: 7 * 86_400)

        XCTAssertEqual(stale, [.inventory], "8-day-old computers data is stale; 1-day ea-results is not")
    }

    func testStaleTiersIgnoresNeverCollectedTiers() throws {
        let profile = "stalen\(Int.random(in: 10_000...99_999))"
        guard let root = WorkspacePathGuard.root(for: profile) else {
            throw XCTSkip("workspace root unavailable for test profile")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        // Workspace exists but has no snapshots at all → nothing reported
        // (the per-page empty states cover the never-collected case).
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("jamf-cli-data", isDirectory: true),
            withIntermediateDirectories: true
        )

        let stale = WorkspaceStore.staleTiers(profile: profile, olderThan: 7 * 86_400)
        XCTAssertTrue(stale.isEmpty)
    }

    func testNewestSnapshotAgeNilForMissingKind() {
        XCTAssertNil(WorkspaceStore.newestSnapshotAge(
            profile: "definitely-not-a-real-profile-xyz", kind: "audit"
        ))
    }

    // MARK: - Include-audit preference

    @MainActor
    func testIncludeAuditPreferencePersists() {
        UserDefaults.standard.removeObject(forKey: GenerateSheetState.includeAuditKey)

        let state = GenerateSheetState()
        XCTAssertFalse(state.includeAudit, "defaults to off")

        state.includeAudit = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: GenerateSheetState.includeAuditKey))

        // A fresh state instance (e.g. reopening the sheet) sees the persisted value.
        let secondState = GenerateSheetState()
        XCTAssertTrue(secondState.includeAudit)
    }
}
