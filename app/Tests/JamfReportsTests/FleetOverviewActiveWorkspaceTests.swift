import Foundation
import XCTest
@testable import JamfReports

/// Fleet Overview shows the active workspace only: two workspaces can be different Jamf Pro
/// servers, so it never reads another profile's summaries.
@MainActor
final class FleetOverviewActiveWorkspaceTests: XCTestCase {

    private nonisolated(unsafe) var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-FleetActive-\(UUID().uuidString)", isDirectory: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testOnlyTheActiveWorkspaceIsRead() async throws {
        try writeWorkspace("alpha", devices: 120)
        try writeWorkspace("beta", devices: 45)
        let store = makeStore(active: "alpha")
        XCTAssertEqual(Set(store.initializedProfiles.map(\.name)), ["alpha", "beta"])

        let reads = ReadLog()
        let overview = await store.loadFleetOverview(readSummaries: reads.reader)

        XCTAssertEqual(reads.names, ["alpha"])
        XCTAssertEqual(overview.profile, "alpha")
        XCTAssertEqual(overview.summary?.totalDevices, 120)
    }

    func testSwitchingTheProfileReloadsTheOtherWorkspace() async throws {
        try writeWorkspace("alpha", devices: 120)
        try writeWorkspace("beta", devices: 45)
        let store = makeStore(active: "alpha")
        let before = store.fleetOverviewLoadKey

        store.setProfile("beta")

        XCTAssertNotEqual(store.fleetOverviewLoadKey, before,
                          "the view's task is keyed on this, so a new key reloads it")
        let reads = ReadLog()
        let overview = await store.loadFleetOverview(readSummaries: reads.reader)
        XCTAssertEqual(reads.names, ["beta"])
        XCTAssertEqual(overview.summary?.totalDevices, 45)
    }

    /// Demo mode gives the stability trend the Overview's whole history, not one point, and
    /// the latest day is the summary the tiles show.
    func testDemoFleetOverviewCarriesTheDemoHistory() async throws {
        let store = WorkspaceStore(
            demoMode: true, tickerRegistrar: StubTickerRegistrar(), jamfCLIProfileNames: { [] })
        let overview = await store.loadFleetOverview(readSummaries: { _ in
            XCTFail("demo mode never reads a workspace"); return []
        })
        XCTAssertEqual(overview.summaries.count, DemoData.trendDates.count)
        XCTAssertEqual(overview.summaries.map(\.date), DemoData.trendDates)
        XCTAssertEqual(overview.summary?.date, overview.summaries.last?.date)
        XCTAssertNotNil(overview.summary?.mobileFormFactorCounts, "the latest day has the device maps")
        XCTAssertNil(overview.summaries.first?.mobileFormFactorCounts)
        XCTAssertGreaterThan(overview.summaries.compactMap(\.stabilityIndex).count, 1)
    }

    // MARK: - Fixtures

    private func makeStore(active: String) -> WorkspaceStore {
        let store = WorkspaceStore(
            demoMode: false, tickerRegistrar: StubTickerRegistrar(), jamfCLIProfileNames: { [] }
        )
        store.profiles = [
            JamfCLIProfile(name: "alpha", url: "", schedules: 0, status: .ok),
            JamfCLIProfile(name: "beta", url: "", schedules: 0, status: .ok),
        ]
        store.profile = active
        return store
    }

    private func writeWorkspace(_ profile: String, devices: Int) throws {
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        let summaries = workspace.appendingPathComponent("snapshots/summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summaries, withIntermediateDirectories: true)
        try Data("jamf_cli:\n  profile: \"\(profile)\"\n".utf8)
            .write(to: workspace.appendingPathComponent("config.yaml"))
        let payload: [String: Any] = [
            "date": "2026-10-18", "totalDevices": devices, "source": "jamf-cli",
        ]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: summaries.appendingPathComponent("summary_2026-10-18.json"))
    }
}

/// Records which profiles were read, then reads them for real.
private final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var read: [String] = []

    var names: [String] { lock.withLock { read } }

    var reader: @Sendable (String) -> [DailySummary] {
        { [self] profile in
            lock.withLock { read.append(profile) }
            return TrendStore.readSummaries(profile: profile)
        }
    }
}
