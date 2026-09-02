import XCTest
@testable import JamfReports

final class PeriodMetricCatalogTests: XCTestCase {

    private func summary(date: String, fileVault: Double?, patch: Double?) -> DailySummary {
        DailySummary(
            date: date, totalDevices: 100, fileVaultPct: fileVault, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: patch,
            source: "test", provenance: nil, sipPct: nil, firewallPct: nil,
            gatekeeperPct: nil, secureBootPct: nil, bootstrapPct: nil, xprotectPct: nil,
            cvePct: nil, mscpScorePct: nil, securityScore: nil, noBaselineActive: nil,
            complianceIsProxy: nil)
    }

    private func eaRow(_ name: String, _ value: String) throws -> EAResultRow {
        let json = Data("""
        {"computer_id":"1","ea_name":"\(name)","value":"\(value)"}
        """.utf8)
        return try JSONDecoder().decode(EAResultRow.self, from: json)
    }

    /// A metric nil across the whole period is not offered — the app does not
    /// invite an operator to report on data it does not have.
    func testMetricNilThroughoutIsNotOffered() {
        let s = [summary(date: "2026-04-01", fileVault: 90, patch: nil),
                 summary(date: "2026-04-02", fileVault: 92, patch: nil)]
        let names = PeriodMetricCatalog.fleetMetrics(in: s).map(\.id)
        XCTAssertTrue(names.contains("fileVaultPct"))
        XCTAssertFalse(
            names.contains("patchPct"), "a metric with no data anywhere must not be offered"
        )
    }

    func testTotalDevicesIsAlwaysOffered() {
        let names = PeriodMetricCatalog.fleetMetrics(
            in: [summary(date: "2026-04-01", fileVault: nil, patch: nil)]).map(\.id)
        XCTAssertTrue(names.contains("totalDevices"))
    }

    /// An org with no EAs gets a working catalogue and nothing looks broken.
    func testProfileWithNoEAsStillYieldsFleetMetrics() {
        let c = PeriodMetricCatalog.build(
            summaries: [summary(date: "2026-04-01", fileVault: 90, patch: nil)],
            eaRows: [], config: nil)
        XCTAssertFalse(c.isEmpty)
        XCTAssertTrue(c.allSatisfy { $0.source == .fleet })
    }

    /// An unconfigured EA is offered as a distribution.
    func testUnconfiguredEAIsOfferedAsDistribution() throws {
        let rows = [try eaRow("Widget Status", "On"), try eaRow("Widget Status", "Off")]
        let m = try XCTUnwrap(PeriodMetricCatalog.eaMetrics(
            rows: rows, customEAs: [], securityAgents: []).first)
        XCTAssertEqual(m.label, "Widget Status")
        guard case .extensionAttribute(_, let match) = m.source else {
            return XCTFail("expected an EA metric")
        }
        XCTAssertNil(match, "an unconfigured EA has no target value")
        XCTAssertEqual(m.unit, .distribution)
    }

    /// The same EA, once configured, becomes a single headline figure.
    func testConfiguredEABecomesAMatchCount() throws {
        let rows = [try eaRow("Widget Status", "On")]
        let agent = try JSONDecoder().decode(SecurityAgentConfig.self, from: Data("""
        {"name":"Widget","column":"Widget Status","connected_value":"On"}
        """.utf8))
        let m = try XCTUnwrap(PeriodMetricCatalog.eaMetrics(
            rows: rows, customEAs: [], securityAgents: [agent]).first)
        guard case .extensionAttribute(_, let match) = m.source else {
            return XCTFail("expected an EA metric")
        }
        XCTAssertEqual(match, "On")
        XCTAssertEqual(m.unit, .count)
    }

    func testEAMetricsAreDeduplicatedByName() throws {
        let rows = [try eaRow("Widget Status", "On"), try eaRow("Widget Status", "Off"),
                    try eaRow("Other Thing", "1")]
        XCTAssertEqual(PeriodMetricCatalog.eaMetrics(
            rows: rows, customEAs: [], securityAgents: []).count, 2)
    }

    func testEARowsWithNoNameAreIgnored() throws {
        let row = try JSONDecoder().decode(
            EAResultRow.self, from: Data(#"{"computer_id":"1","value":"x"}"#.utf8))
        XCTAssertTrue(PeriodMetricCatalog.eaMetrics(
            rows: [row], customEAs: [], securityAgents: []).isEmpty)
    }

    /// The name-only overload exists so a caller holding grouped values does not
    /// have to rebuild rows just to have them counted again.
    func testNameOverloadMatchesTheRowOverload() throws {
        let rows = [try eaRow("Widget Status", "On")]
        XCTAssertEqual(
            PeriodMetricCatalog.eaMetrics(rows: rows, customEAs: [], securityAgents: []),
            PeriodMetricCatalog.eaMetrics(
                names: ["Widget Status"], customEAs: [], securityAgents: []
            ))
    }
}
