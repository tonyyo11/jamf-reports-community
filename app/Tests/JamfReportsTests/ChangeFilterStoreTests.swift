import XCTest
@testable import JamfReports

/// `WorkspaceStore.resolveChangeFilter` on a seeded workspace: the session cache, one shared
/// comparison per snapshot pair, a cancelled caller, and a profile switch mid-comparison.
@MainActor
final class ChangeFilterStoreTests: XCTestCase {

    private let profile = "changefilterprof"
    private let anchor = GoldenFleetClock.anchorNoon()
    private let rule = StaleRule(days: 30)
    private let policy = SecurityControlPolicy()

    private func stamp(_ day: Int) -> String {
        GoldenFleetClock.stamp(
            GoldenFleetClock.timestamp(dayOffset: day, hour: 6, minute: 0, relativeTo: anchor))
    }

    /// A workspace with two `computers` snapshots a day apart, and a store showing it.
    private func store() throws -> WorkspaceStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-ChangeFilter-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let folder = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent("computers", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (day, ids) in [(-1, ["1", "2"]), (0, ["1", "3", "4"])] {
            let rows = ids.map { ["id": $0] }
            try JSONSerialization.data(withJSONObject: rows).write(
                to: folder.appendingPathComponent("computers_\(stamp(day)).json"))
        }
        let store = WorkspaceStore(
            demoMode: false, jamfCLIProfileNames: { [] }, discoverProfiles: { [] },
            jamfCLIInstallation: { nil })
        store.profile = profile
        return store
    }

    private func filter(_ kind: ChangeKind = .joined) -> ChangeFilter {
        ChangeFilter(kind: kind, currentStamp: stamp(0), baselineStamp: stamp(-1))
    }

    private func resolve(_ store: WorkspaceStore, _ kind: ChangeKind = .joined)
        -> Task<ChangeFilterResult, Never> {
        let (filter, rule, policy) = (filter(kind), rule, policy)
        return Task { await store.resolveChangeFilter(filter, rule: rule, policy: policy) }
    }

    /// Yields until a comparison is in flight, so the next step happens while it runs.
    private func untilInFlight(_ store: WorkspaceStore) async {
        for _ in 0..<1_000 where store.changeFilterInFlight.isEmpty { await Task.yield() }
        XCTAssertFalse(store.changeFilterInFlight.isEmpty, "a comparison started")
    }

    func testASecondVisitIsServedFromTheCache() async throws {
        let store = try store()
        let first = await resolve(store).value
        XCTAssertEqual(first.outcome, .macs([MacKey(jamfID: "3"), MacKey(jamfID: "4")]))
        XCTAssertEqual(store.changeFilterCache.count, 1)
        try FileManager.default.removeItem(
            at: try WorkspacePaths.dataDir(for: profile).appendingPathComponent("computers"))
        let again = await resolve(store).value
        XCTAssertEqual(again, first, "no disk read the second time")
        let left = await resolve(store, .left).value
        XCTAssertEqual(left.outcome, .left([ComputerDates(jamfID: "2")]),
                       "one comparison fills every kind")
    }

    func testTwoCallersShareOneComparison() async throws {
        let store = try store()
        let joined = resolve(store)
        await untilInFlight(store)
        let left = resolve(store, .left)
        await Task.yield()
        XCTAssertEqual(store.changeFilterInFlight.count, 1)
        let a = await joined.value
        let b = await left.value
        XCTAssertEqual(a.outcome, .macs([MacKey(jamfID: "3"), MacKey(jamfID: "4")]))
        XCTAssertEqual(b.outcome, .left([ComputerDates(jamfID: "2")]))
        XCTAssertTrue(store.changeFilterInFlight.isEmpty)
        XCTAssertEqual(store.changeFilterCache.count, 1)
    }

    /// The first caller's cancel stops the shared comparison; the other runs it again.
    func testACancelledCallerDoesNotCancelTheOther() async throws {
        let store = try store()
        let first = resolve(store)
        await untilInFlight(store)
        let second = resolve(store, .osChanged)
        await Task.yield()
        first.cancel()
        let cancelled = await first.value
        XCTAssertEqual(cancelled.outcome, .cancelled)
        let result = await second.value
        XCTAssertNotEqual(result.outcome, .cancelled)
        XCTAssertEqual(result.outcome, .macs([]))
    }

    func testAProfileSwitchMidComparisonCachesNothing() async throws {
        let store = try store()
        let pending = resolve(store)
        await untilInFlight(store)
        store.profile = "otherprofile"
        let result = await pending.value
        XCTAssertNotEqual(result.outcome, .cancelled)
        XCTAssertTrue(store.changeFilterCache.isEmpty, "written for a profile no longer shown")
    }

    func testSetProfileEmptiesTheCache() async throws {
        let store = try store()
        _ = await resolve(store).value
        XCTAssertFalse(store.changeFilterCache.isEmpty)
        store.setProfile("otherprofile")
        XCTAssertTrue(store.changeFilterCache.isEmpty)
    }

    func testAnUndecodableReadIsTriedAgain() async throws {
        let store = try store()
        let baseline = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent("computers/computers_\(stamp(-1)).json")
        let good = try Data(contentsOf: baseline)
        try Data("{bad".utf8).write(to: baseline)
        let broken = await resolve(store).value
        XCTAssertEqual(broken.outcome, .unreadable(.undecodable))
        XCTAssertTrue(store.changeFilterCache.isEmpty)
        try good.write(to: baseline)
        let fixed = await resolve(store).value
        XCTAssertEqual(fixed.outcome, .macs([MacKey(jamfID: "3"), MacKey(jamfID: "4")]))
    }
}
