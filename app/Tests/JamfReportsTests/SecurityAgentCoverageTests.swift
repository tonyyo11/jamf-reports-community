import Foundation
import XCTest
@testable import JamfReports

final class SecurityAgentCoverageTests: XCTestCase {

    private func rows(_ json: String) throws -> [EAResultRow] {
        try XCTUnwrap(EAResultRow.decodeSnapshot(Data(json.utf8)).rows)
    }

    private let falcon = SecurityAgentConfig(
        name: "CrowdStrike Falcon", column: "Falcon - Status", connectedValue: "Running")

    func testCountsInstalledAndReportingMacsOncePerMac() throws {
        let data = try rows("""
        [
          {"device": "mac-1", "ea_name": "Falcon - Status", "value": "Running"},
          {"device": "MAC-1", "ea_name": "falcon - status", "value": "running"},
          {"device": "mac-2", "ea_name": "Falcon - Status", "value": "Stopped"},
          {"device": "mac-3", "ea_name": "Falcon - Status", "value": ""},
          {"device": "mac-4", "ea_name": "Other EA", "value": "Running"}
        ]
        """)

        let result = SecurityAgentCoverage.compute(rows: data, agents: [falcon])

        XCTAssertEqual(result, [
            .init(name: "CrowdStrike Falcon", column: "Falcon - Status",
                  installed: 1, reporting: 2)
        ], "mac-1 counts once; an empty value is not reporting; other EAs are ignored")
    }

    func testAnAgentWithoutAColumnIsSkipped() throws {
        let data = try rows(
            #"[{"device": "mac-1", "ea_name": "Falcon - Status", "value": "Running"}]"#)
        let blank = SecurityAgentConfig(name: "Unmapped", column: "  ", connectedValue: "Yes")

        let result = SecurityAgentCoverage.compute(rows: data, agents: [blank, falcon])

        XCTAssertEqual(result.map(\.name), ["CrowdStrike Falcon"])
    }

    func testPercentIsOverTheFleetAndUnknownForAnEmptyFleet() {
        XCTAssertEqual(SecurityAgentCoverage.percent(installed: 506, fleet: 524), 96.6)
        XCTAssertEqual(SecurityAgentCoverage.percent(installed: 0, fleet: 10), 0)
        XCTAssertNil(SecurityAgentCoverage.percent(installed: 3, fleet: 0))
    }
}
