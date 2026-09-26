import Foundation
import Observation
import XCTest
@testable import JamfReports

/// 2.8.1 visual pass: after Collect now on OS Updates, "Data refreshed" showed while
/// the banner's button still read "Collecting…". The button flips when
/// `runTierRefresh` returns, so the toast must not land before its re-probes.
@MainActor
final class WorkspaceStoreRefreshToastTests: XCTestCase {

    func testRunTierRefreshPostsItsToastAfterTheReprobes() async throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-RefreshToast-\(UUID().uuidString)", isDirectory: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", temp.path, 1)
        defer {
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

        // What the heavy-tier re-probe had published when the toast was set.
        let seen = TierBox()
        withObservationTracking {
            _ = store.toast
        } onChange: {
            MainActor.assumeIsolated { seen.tiers = store.staleHeavyTiers }
        }

        await store.runTierRefresh(Set(CollectionTier.allCases)) { _, _, _ in
            for kind in ["computers", "update-device-failures"] {
                let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try "[]".write(to: dir.appendingPathComponent("\(kind)_fresh.json"),
                               atomically: true, encoding: .utf8)
            }
            return 0
        }

        XCTAssertEqual(store.toast?.message, "Data refreshed")
        XCTAssertEqual(seen.tiers, [],
                       "the toast must follow the re-probe, not precede it")
    }
}

private final class TierBox: @unchecked Sendable {
    var tiers: [CollectionTier]?
}
