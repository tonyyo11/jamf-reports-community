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
        for kind in ["computers", "update-device-failures"] {
            let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "[]".write(to: dir.appendingPathComponent("\(kind)_fresh.json"),
                           atomically: true, encoding: .utf8)
        }
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
