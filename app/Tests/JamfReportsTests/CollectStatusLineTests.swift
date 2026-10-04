import XCTest
@testable import JamfReports

/// The status bar said "Ready" while a toolbar collect ran: the collect's line lived in the
/// shared `globalStatus`, which any screen sets and clears for its own work (Fleet Overview did
/// on every visit). The collect's line now lives with the collect, for as long as it runs.
@MainActor
final class CollectStatusLineTests: XCTestCase {

    private let profile = "alpha"

    private func makeStore() throws -> WorkspaceStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-status-line-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "".write(to: workspace.appendingPathComponent("config.yaml"),
                     atomically: true, encoding: .utf8)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        _ = useTemporaryTickLock()
        let store = WorkspaceStore(
            demoMode: false, tickerRegistrar: StubTickerRegistrar(),
            jamfCLIProfileNames: { [] }, discoverProfiles: { [] }, jamfCLIInstallation: { nil })
        store.profile = profile
        store.resolveAuthMethod = { _ in nil }
        return store
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testTheStatusBarNamesARunningCollectUntilItEnds() async throws {
        let store = try makeStore()
        XCTAssertNil(store.statusLine, "Ready")
        let started = Flag()
        let finish = Flag()
        defer { finish.set() }
        let refresh = Task { @MainActor in
            await store.runTierRefresh(Set(CollectionTier.allCases)) { _, _, _ in
                started.set()
                while !finish.isSet { try await Task.sleep(for: .milliseconds(10)) }
                return 0
            }
        }
        try await waitUntil { started.isSet }
        XCTAssertEqual(store.statusLine, "refreshing data · profile=\(profile)")

        // Another screen sets and clears its own line, as Fleet Overview did on every visit.
        store.globalStatus = "Aggregating multi-profile summaries..."
        XCTAssertEqual(store.statusLine, "Aggregating multi-profile summaries...")
        store.globalStatus = nil
        XCTAssertEqual(store.statusLine, "refreshing data · profile=\(profile)",
                       "the collect's line is back, not Ready")

        finish.set()
        await refresh.value
        XCTAssertNil(store.statusLine)
    }

    func testEveryStoreCollectKeepsItsLine() async throws {
        let store = try makeStore()
        let seen = Recorder()
        store.staleHeavyTiers = [.inventory, .scan]
        await store.runHeavyTierRefresh { _, _, _ in
            let line = await store.statusLine
            seen.record(line)
            return 0
        }
        await store.runFirstCollect { _, _ in
            let line = await store.statusLine
            seen.record(line)
            return 0
        }
        XCTAssertEqual(seen.values, [
            "refreshing Inventory + Scan data · profile=\(profile)",
            "collecting jamf-cli data · profile=\(profile)",
        ])
        XCTAssertNil(store.statusLine)
    }

    /// Self-remediation and catch-up are collects too: the bar says so while they run.
    func testAnAutomaticCollectShowsItsLineToo() async throws {
        let store = try makeStore()
        AutomationHealthModel.shared.freshnessIssues = [DataFreshnessIssue(
            snapshotKind: "security", tier: .refresh, kind: .stale,
            lastSuccess: Date(timeIntervalSince1970: 1_700_000_000),
            consecutiveFailures: 0, lastFailure: nil)]
        defer { AutomationHealthModel.shared.freshnessIssues = [] }
        let seen = Recorder()
        let attempted = await store.remediateStaleDataIfNeeded { _, _, _ in
            let line = await store.statusLine
            seen.record(line)
        }
        XCTAssertTrue(attempted)
        XCTAssertEqual(seen.values, ["re-collecting stale data · profile=\(profile)"])
        XCTAssertNil(store.statusLine)
    }

    func testTheLineSurvivesUntilTheLastMarkEnds() throws {
        let store = try makeStore()
        store.beginCollect(for: "alpha", status: "first")
        store.beginCollect(for: "beta", status: "second")
        store.endCollect(for: "alpha")
        XCTAssertEqual(store.statusLine, "second", "a collect is still running")
        store.endCollect(for: "beta")
        XCTAssertNil(store.statusLine)
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.withLock { recorded } }
    func record(_ value: String?) { lock.withLock { recorded.append(value ?? "nil") } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isSet: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
