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
        // .inventory probe kind = "computers" (8 days old → stale). ea-results is
        // now inventory-tier too, but inventory probes "computers", so the old
        // 8-day computers file still makes inventory stale. .scan probes
        // update-device-failures (absent here → never-collected, which #181
        // also reports as stale on an existing workspace).
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

        XCTAssertEqual(stale, [.inventory, .scan],
                       "computers (8d) makes inventory stale; never-collected scan is stale too (#181)")
    }

    /// #181: a workspace that exists but has never collected reports BOTH heavy
    /// tiers as stale, so the Overview prompt is reachable on a fresh
    /// workspace. (Inverts the pre-2.2.1 behavior, which treated never-collected
    /// as not-stale and left a new user with no collect affordance at all.)
    func testStaleTiersReportsNeverCollectedTiersWhenWorkspaceExists() throws {
        let profile = "stalen\(Int.random(in: 10_000...99_999))"
        guard let root = WorkspacePathGuard.root(for: profile) else {
            throw XCTSkip("workspace root unavailable for test profile")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("jamf-cli-data", isDirectory: true),
            withIntermediateDirectories: true
        )

        let stale = WorkspaceStore.staleTiers(profile: profile, olderThan: 7 * 86_400)
        XCTAssertEqual(stale, [.inventory, .scan],
                       "never-collected tiers must surface the prompt on an existing workspace")
    }

    /// #181 boundary: no workspace directory at all → nothing reported. The
    /// Overview "Configuration incomplete" init banner owns that state; the
    /// heavy-tier prompt must not stack on top of it.
    func testStaleTiersEmptyWhenWorkspaceMissing() {
        let profile = "stalem\(Int.random(in: 10_000...99_999))"
        XCTAssertFalse(WorkspaceStore.workspaceExists(profile: profile))
        XCTAssertTrue(WorkspaceStore.staleTiers(profile: profile, olderThan: 7 * 86_400).isEmpty)
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
