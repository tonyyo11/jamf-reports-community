import Foundation
import XCTest
@testable import JamfReports

/// Visual review 2026-10-04: the Overview's agent drill-down printed "Trend: Flat" for every
/// agent because the live loader hard-coded it. Only the first configured agent has a daily
/// series (the summary's EDR figure), so it alone gets a direction; the rest have none and the
/// tile is not drawn.
final class AgentTrendTests: XCTestCase {

    private func agent(_ name: String, trend: SecurityAgent.Trend? = nil) -> SecurityAgent {
        SecurityAgent(name: name, installed: 90, pct: 90, column: "\(name) - Status", trend: trend)
    }

    func testDirectionOfTheLastTwoValues() {
        XCTAssertNil(OverviewLiveDataLoader.trend(of: []))
        XCTAssertNil(OverviewLiveDataLoader.trend(of: [95.6]), "one point is no direction")
        XCTAssertEqual(OverviewLiveDataLoader.trend(of: [90.0, 95.6, 95.7]), .up)
        XCTAssertEqual(OverviewLiveDataLoader.trend(of: [90.0, 95.7, 95.6]), .down)
        XCTAssertEqual(OverviewLiveDataLoader.trend(of: [10.0, 95.6, 95.6]), .flat)
    }

    func testTwoValuesThatPrintTheSameAreFlat() {
        // Both read 95.6% on the card.
        XCTAssertEqual(OverviewLiveDataLoader.trend(of: [95.61, 95.64]), .flat)
    }

    func testOnlyTheEDRAgentGetsATrend() {
        let cards = OverviewLiveDataLoader.agents(
            [agent("Falcon"), agent("Scanner")], overFleet: 100,
            edrAgentName: "Falcon", edrSeries: [93.0, 95.0])
        XCTAssertEqual(cards.map(\.trend), [.up, nil])
    }

    func testNoSeriesMeansNoTrendEvenForTheEDRAgent() {
        let cards = OverviewLiveDataLoader.agents(
            [agent("Falcon", trend: .up)], overFleet: 100,
            edrAgentName: "Falcon", edrSeries: [95.0])
        XCTAssertEqual(cards.map(\.trend), [nil])
    }

    func testTheShareStillFollowsTheFleetWhenItIsKnown() {
        let known = OverviewLiveDataLoader.agents([agent("Falcon")], overFleet: 120)
        XCTAssertEqual(known.first?.pct, 75.0)
        let unknown = OverviewLiveDataLoader.agents([agent("Falcon")], overFleet: 0)
        XCTAssertEqual(unknown.first?.pct, 90)
    }

    /// The live loader no longer stamps every agent "flat".
    func testLoaderLeavesTheTrendToTheSeries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JRC-AgentTrend-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("acme", isDirectory: true)
        let eaDir = workspace.appendingPathComponent("jamf-cli-data/ea-results", isDirectory: true)
        try FileManager.default.createDirectory(at: eaDir, withIntermediateDirectories: true)
        try Data("""
            security_agents:
              - name: "Falcon"
                column: "Falcon State"
                connected_value: "connected"
            """.utf8).write(to: workspace.appendingPathComponent("config.yaml"))
        let rows: [[String: Any]] = [
            ["device": "mac-1", "ea_name": "Falcon State", "value": "connected"],
            ["device": "mac-2", "ea_name": "Falcon State", "value": "error"],
        ]
        try JSONSerialization.data(withJSONObject: rows)
            .write(to: eaDir.appendingPathComponent("ea-results_20261004T100000.json"))
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        let live = try await OverviewLiveDataLoader.load(
            profile: "acme", sections: [.securityAgents])

        XCTAssertEqual(live.agents.map(\.name), ["Falcon"])
        XCTAssertEqual(live.agents.map(\.installed), [1])
        XCTAssertEqual(live.agents.map(\.trend), [nil])
    }
}
