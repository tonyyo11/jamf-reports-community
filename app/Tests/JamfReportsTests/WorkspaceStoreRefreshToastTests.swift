import Foundation
import Observation
import XCTest
@testable import JamfReports

/// 2.8.1 visual pass: after Collect now on OS Updates, "Data refreshed" showed while
/// the banner's button still read "Collecting…". Each button flips when its refresh
/// returns, so the toast must not land before the refresh's re-probes.
@MainActor
final class WorkspaceStoreRefreshToastTests: XCTestCase {

    /// A live workspace whose `computers` snapshot is 8 days old, so the heavy-tier
    /// prompt is up; returns the store and the workspace's data dir.
    private func makeStaleWorkspace() async throws -> (WorkspaceStore, URL) {
        pinSkipExpensiveCollectionsOff(self)
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-RefreshToast-\(UUID().uuidString)", isDirectory: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", temp.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: temp)
        }
        let slug = "refreshtoast"
        let root = try XCTUnwrap(ProfileService.workspaceURL(for: slug))
        let store = WorkspaceStore()
        store.demoMode = false
        store.profile = slug
        let dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        let computersDir = dataDir.appendingPathComponent("computers", isDirectory: true)
        try FileManager.default.createDirectory(at: computersDir, withIntermediateDirectories: true)
        let old = computersDir.appendingPathComponent("computers_old.json")
        try "[]".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -8 * 86_400)], ofItemAtPath: old.path
        )
        await store.checkHeavyTierStaleness()
        XCTAssertEqual(store.staleHeavyTiers, [.inventory, .scan], "precondition: prompt is up")
        return (store, dataDir)
    }

    func testRunTierRefreshPostsItsToastAfterTheReprobes() async throws {
        let (store, dataDir) = try await makeStaleWorkspace()
        let seen = watchToast(store)
        await store.runTierRefresh(Set(CollectionTier.allCases)) { _, _, _ in
            try Self.landFreshSnapshots(in: dataDir)
            return 0
        }
        XCTAssertEqual(store.toast?.message, "Data refreshed")
        XCTAssertEqual(seen.tiers, [], "the toast must follow the re-probe, not precede it")
    }

    func testRunHeavyTierRefreshPostsItsToastAfterTheReprobes() async throws {
        let (store, dataDir) = try await makeStaleWorkspace()
        let seen = watchToast(store)
        await store.runHeavyTierRefresh { _, _, _ in
            try Self.landFreshSnapshots(in: dataDir)
            return 0
        }
        XCTAssertEqual(store.toast?.style, .success)
        XCTAssertEqual(seen.tiers, [], "the toast must follow the re-probe, not precede it")
    }

    func testRunFirstCollectPostsItsToastAfterTheReprobes() async throws {
        let (store, dataDir) = try await makeStaleWorkspace()
        let seen = watchToast(store)
        await store.runFirstCollect { _, _ in
            try Self.landFreshSnapshots(in: dataDir)
            return 0
        }
        XCTAssertEqual(store.toast?.message, "Collection complete")
        XCTAssertEqual(seen.tiers, [], "the toast must follow the re-probe, not precede it")
    }

    // MARK: - Honesty: exit 0 is not "everything landed"

    private static let warningsInRunHistory = "Refresh finished with warnings — see Run History"
    private static let warningsInLogging =
        "Refresh finished with warnings — see Settings › Logging"

    /// The field case: Managed Software Update Plans off, so `update-status` records a cause,
    /// does not land, and the collect still exits 0. A fresh kind name per call keeps the
    /// process-wide `LogBuffer` search below from matching another test's line.
    private nonisolated static func unlandedLine() -> String {
        ReportEngine.unlandedSourcesLine(["update-status-\(UUID().uuidString)"], attempted: 1)
    }

    private func isInLogBuffer(_ text: String) -> Bool {
        LogBuffer.shared.snapshot(minLevel: .debug, limit: 2000).contains { $0.message == text }
    }

    private nonisolated static func line(_ text: String) -> CLIBridge.LogLine {
        CLIBridge.LogLine(timestamp: Date(), level: .warn, text: text)
    }

    /// No Run History record for a tier refresh, so the toast points at the in-app log, and
    /// the `[partial]` line must actually be there.
    func testRunTierRefreshWarnsWhenASourceDidNotLand() async throws {
        let (store, dataDir) = try await makeStaleWorkspace()
        let unlanded = Self.unlandedLine()
        await store.runTierRefresh(Set(CollectionTier.allCases)) { _, _, onLine in
            try Self.landFreshSnapshots(in: dataDir)
            onLine(Self.line(unlanded))
            return 0
        }
        XCTAssertEqual(store.toast?.message, Self.warningsInLogging)
        XCTAssertEqual(store.toast?.style, .danger)
        XCTAssertTrue(isInLogBuffer(unlanded), "the toast names Settings › Logging")
    }

    func testRunTierRefreshKeepsItsTextForAStandDown() async throws {
        let (store, dataDir) = try await makeStaleWorkspace()
        await store.runTierRefresh(Set(CollectionTier.allCases)) { _, _, onLine in
            try Self.landFreshSnapshots(in: dataDir)
            onLine(Self.line(ReportEngine.standDownLine(reason: "[info] peer collected recently")))
            return 0
        }
        XCTAssertEqual(store.toast?.message, "Data refreshed")
        XCTAssertEqual(store.toast?.style, .success)
    }

    func testRunHeavyTierRefreshWarnsWhenASourceDidNotLand() async throws {
        let (store, dataDir) = try await makeStaleWorkspace()
        let unlanded = Self.unlandedLine()
        await store.runHeavyTierRefresh { _, _, onLine in
            try Self.landFreshSnapshots(in: dataDir)
            onLine(Self.line(unlanded))
            return 0
        }
        XCTAssertEqual(store.toast?.message, Self.warningsInLogging)
        XCTAssertEqual(store.toast?.style, .danger)
        XCTAssertTrue(isInLogBuffer(unlanded), "the toast names Settings › Logging")
    }

    /// First collect is the one path with a Run History record, so it points there; the
    /// recorded log must hold the `[partial]` line.
    func testRunFirstCollectWarnsWhenASourceDidNotLand() async throws {
        let (store, dataDir) = try await makeStaleWorkspace()
        let unlanded = Self.unlandedLine()
        await store.runFirstCollect { _, onLine in
            try Self.landFreshSnapshots(in: dataDir)
            onLine(Self.line(unlanded))
            return 0
        }
        XCTAssertEqual(store.toast?.message, Self.warningsInRunHistory)
        XCTAssertEqual(store.toast?.style, .danger)
        let run = try XCTUnwrap(RunHistoryService.list(profile: store.profile).first)
        XCTAssertTrue(
            RunHistoryService.loadLog(run.logURL).contains { $0.text == unlanded },
            "the toast names Run History, so the run's log must hold the line")
    }

    func testCollectCompletedToastNamesWhereTheWarningsCanBeRead() {
        let clean = WorkspaceStore.collectCompletedToast(
            "Data refreshed", incomplete: false, warningsAt: .runHistory)
        XCTAssertEqual(clean.message, "Data refreshed")
        XCTAssertEqual(clean.style, .success)
        let cleanElsewhere = WorkspaceStore.collectCompletedToast(
            "Data refreshed", incomplete: false, warningsAt: .settingsLogging)
        XCTAssertEqual(cleanElsewhere.message, "Data refreshed")

        let inHistory = WorkspaceStore.collectCompletedToast(
            "Data refreshed", incomplete: true, warningsAt: .runHistory)
        XCTAssertEqual(inHistory.message, Self.warningsInRunHistory)
        XCTAssertEqual(inHistory.style, .danger)

        let inLogging = WorkspaceStore.collectCompletedToast(
            "Data refreshed", incomplete: true, warningsAt: .settingsLogging)
        XCTAssertEqual(inLogging.message, Self.warningsInLogging)
        XCTAssertEqual(inLogging.style, .danger)
    }

    /// A first collect whose recorder could not open has no Run History entry, so it points at
    /// the in-app log instead.
    func testFirstCollectToastPointsAtRunHistoryOnlyWhenTheRunWasRecorded() {
        let recorded = WorkspaceStore.firstCollectToast(
            exitCode: 0, runRecorded: true, incomplete: true)
        XCTAssertEqual(recorded.message, Self.warningsInRunHistory)

        let unrecorded = WorkspaceStore.firstCollectToast(
            exitCode: 0, runRecorded: false, incomplete: true)
        XCTAssertEqual(unrecorded.message, Self.warningsInLogging)

        let failed = WorkspaceStore.firstCollectToast(exitCode: 1, incomplete: true)
        XCTAssertTrue(failed.message.hasPrefix("Collect finished with errors (exit 1)"),
                      "a non-zero exit keeps its own text; got: \(failed.message)")
    }

    /// The unrecorded-first-collect fallback above is only true if first collect also feeds
    /// the in-app log, as CLAUDE.md's logging section says it does.
    func testRunFirstCollectMirrorsItsLinesIntoTheInAppLog() async throws {
        let (store, dataDir) = try await makeStaleWorkspace()
        let unlanded = Self.unlandedLine()
        await store.runFirstCollect { _, onLine in
            try Self.landFreshSnapshots(in: dataDir)
            onLine(Self.line(unlanded))
            return 0
        }
        XCTAssertTrue(isInLogBuffer(unlanded))
    }

    /// Records what the heavy-tier re-probe had published when the toast was set.
    private func watchToast(_ store: WorkspaceStore) -> TierBox {
        let seen = TierBox()
        withObservationTracking {
            _ = store.toast
        } onChange: {
            MainActor.assumeIsolated { seen.tiers = store.staleHeavyTiers }
        }
        return seen
    }

    private nonisolated static func landFreshSnapshots(in dataDir: URL) throws {
        try landHeavyTierSnapshots(in: dataDir)
    }
}

/// `UpdatesView`'s empty state prints a command to paste; `collect` requires `--profile`.
@MainActor
final class UpdatesViewCollectCommandTests: XCTestCase {
    func testCollectCommandNamesTheProfile() {
        XCTAssertEqual(
            UpdatesView.collectCommand(profile: "acme"),
            "jamf-reports collect --profile acme --tiers inventory,scan"
        )
    }
}

private final class TierBox: @unchecked Sendable {
    var tiers: [CollectionTier]?
}
