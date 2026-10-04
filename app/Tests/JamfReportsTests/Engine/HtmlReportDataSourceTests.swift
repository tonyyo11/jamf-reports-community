import Foundation
import XCTest
@testable import JamfReports

/// The HTML report reads each fact from the snapshot that carries it: security-gap wording
/// from the counts behind the tiles, agent coverage from `ea-results`, and department and
/// building names through the `departments` and `buildings` snapshots, because
/// `computers list` carries only the ids.
///
/// Fixture (invented): four Macs. FileVault is off on one. Three report the Falcon agent
/// as connected. Three sit in department 12 (Engineering), one in department 99 that no
/// snapshot lists; one is in building 3.
final class HtmlReportDataSourceTests: XCTestCase {

    private var tmpDirs: [URL] = []

    override func tearDown() {
        for dir in tmpDirs { try? FileManager.default.removeItem(at: dir) }
        tmpDirs.removeAll()
        super.tearDown()
    }

    private func write(_ kind: String, _ dataDir: URL, _ rows: [[String: Any]]) throws {
        try GoldenFleetWorkspace.writeSnapshot(
            kind: kind, dataDir: dataDir, at: GoldenFleetClock.anchorNoon(), rows: rows)
    }

    private func renderedReport() async throws -> String {
        let root = GoldenFleetWorkspace.freshRoot()
        tmpDirs.append(root)
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        try write("security", dataDir, GoldenFleetWorkspace.securitySummaryPayload(
            total: 4, filevault: 3, sip: 4, firewall: 4, gatekeeper: 4))
        let macs: [(id: String, department: String, building: String?)] = [
            ("1", "12", "3"), ("2", "12", nil), ("3", "12", nil), ("4", "99", nil),
        ]
        try write("computers", dataDir, macs.map { id, department, building -> [String: Any] in
            var location: [String: Any] = ["departmentId": department]
            if let building { location["buildingId"] = building }
            return ["id": id, "general": ["name": "Test-Mac-\(id)"],
                    "hardware": ["serialNumber": "SERIAL\(id)"], "userAndLocation": location]
        })
        try write("departments", dataDir, [["id": "12", "name": "Engineering"]])
        try write("buildings", dataDir, [["id": "3", "name": "Main Campus"]])
        try write("ea-results", dataDir, [
            ["computer_id": "1", "ea_name": "Falcon State", "value": "connected"],
            ["computer_id": "2", "ea_name": "Falcon State", "value": "connected"],
            ["computer_id": "3", "ea_name": "Falcon State", "value": "Connected"],
            ["computer_id": "4", "ea_name": "Falcon State", "value": "not installed"],
        ])
        // jamf-cli's device-compliance rows: no failure count of any kind.
        try write("device-compliance", dataDir, (1...4).map {
            ["name": "Test-Mac-\($0)", "serial": "SERIAL\($0)", "managed": true,
             "stale": false, "days_since_contact": "1"]
        })
        let config = try ConfigLoader.loadFromString("""
        security_agents:
          - name: "Falcon"
            column: "Falcon State"
            connected_value: "connected"
        """)
        let output = root.appendingPathComponent("report.html")
        try await HtmlReport(config: config, dataDir: dataDir).generate(
            outputURL: output,
            sections: [.execSummary, .agentHealth, .buildingBreakdown, .departmentBreakdown,
                       .assetMap, .complianceBands])
        return try String(contentsOf: output, encoding: .utf8)
    }

    private func section(_ id: String, in html: String) throws -> String {
        let start = try XCTUnwrap(html.range(of: "id=\"\(id)\""), "no \(id) section")
        let end = try XCTUnwrap(
            html.range(of: "</section>", range: start.upperBound..<html.endIndex))
        return String(html[start.lowerBound..<end.lowerBound])
    }

    func testExecutiveSummaryNamesTheGapsTheTilesShow() async throws {
        let html = try await renderedReport()
        let summary = try section("exec-summary", in: html)
        XCTAssertTrue(summary.contains("Security gaps to remediate: FileVault off on 1 Mac."),
                      summary)
        XCTAssertFalse(summary.contains("meet all compliance requirements"))
        XCTAssertFalse(summary.contains("require remediation"))
    }

    func testNoComplianceHeroWhenTheRowsCarryNoFailureCount() async throws {
        let html = try await renderedReport()
        XCTAssertFalse(html.contains("class=\"compliance-hero "), "no 100% claim without counts")
        XCTAssertFalse(html.contains("Device Compliance &middot;"))
    }

    func testAgentHealthReadsEAResults() async throws {
        let html = try await renderedReport()
        let agents = try section("agent-health", in: html)
        XCTAssertTrue(agents.contains("3 of 4 installed"), agents)
        XCTAssertTrue(
            agents.contains("<td>Falcon</td><td>3</td><td>1</td><td>0</td><td>75.0%</td>"), agents)
    }

    func testDepartmentsAndBuildingsAreNamedFromTheirSnapshots() async throws {
        let html = try await renderedReport()
        let departments = try section("department-breakdown", in: html)
        XCTAssertTrue(departments.contains("Engineering"), departments)
        XCTAssertTrue(departments.contains("(unassigned)"), "department 99 is in no snapshot")
        let buildings = try section("building-breakdown", in: html)
        XCTAssertTrue(buildings.contains("Main Campus"), buildings)

        let assets = try section("asset-map", in: html)
        XCTAssertTrue(assets.contains("<td>Engineering</td><td>Main Campus</td>"), assets)
    }

    // MARK: - resolvingLocationNames

    private func report() -> HtmlReport {
        HtmlReport(config: ReportConfig().withDefaults(),
                   dataDir: URL(fileURLWithPath: "/tmp/nonexistent-data"))
    }

    func testAPlainNameOnTheRecordWinsOverTheIdLookup() {
        let inventory: [[String: Any]] = [[
            "userAndLocation": ["department": "Named Here", "departmentId": "12"],
        ]]
        let resolved = report().resolvingLocationNames(
            inventory, buildings: [], departments: [["id": "12", "name": "Engineering"]])
        XCTAssertEqual(report().inventoryDepartment(resolved[0]), "Named Here")
    }

    func testIdsMatchWhetherJamfSendsThemAsNumbersOrStrings() {
        let inventory: [[String: Any]] = [["userAndLocation": ["buildingId": 3]]]
        let resolved = report().resolvingLocationNames(
            inventory, buildings: [["id": "3", "name": "Main Campus"]], departments: [])
        XCTAssertEqual(report().inventoryBuilding(resolved[0]), "Main Campus")
    }

    func testWithoutNameSnapshotsTheInventoryIsReturnedAsIs() {
        let inventory: [[String: Any]] = [["userAndLocation": ["departmentId": "12"]]]
        let resolved = report().resolvingLocationNames(inventory, buildings: [], departments: [])
        XCTAssertEqual(report().inventoryDepartment(resolved[0]), "\u{2014}")
    }
}
