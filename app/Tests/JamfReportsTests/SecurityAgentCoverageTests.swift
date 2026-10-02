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
          {"computer_id": "1", "ea_name": "Falcon - Status", "value": "Running"},
          {"computer_id": "1", "ea_name": "falcon - status", "value": "running"},
          {"computer_id": "2", "ea_name": "Falcon - Status", "value": "Stopped"},
          {"computer_id": "3", "ea_name": "Falcon - Status", "value": ""},
          {"computer_id": "4", "ea_name": "Other EA", "value": "Running"}
        ]
        """)

        let result = SecurityAgentCoverage.compute(rows: data, agents: [falcon])

        XCTAssertEqual(result, [
            .init(name: "CrowdStrike Falcon", column: "Falcon - Status",
                  installed: 1, reporting: 2)
        ], "Mac 1 counts once; an empty value is not reporting; other EAs are ignored")
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

    /// Config's Add agent leaves connected_value blank, and Config Doctor says any value then
    /// counts as connected. The daily summary recorded 0% EDR coverage instead.
    func testABlankConnectedValueCountsAnyValueAsConnected() throws {
        let data = try rows("""
        [
          {"device": "mac-1", "ea_name": "Falcon - Status", "value": "Running"},
          {"device": "mac-2", "ea_name": "Falcon - Status", "value": "Stopped"},
          {"device": "mac-3", "ea_name": "Falcon - Status", "value": ""}
        ]
        """)
        let unset = SecurityAgentConfig(
            name: "CrowdStrike Falcon", column: "Falcon - Status", connectedValue: " ")

        let result = SecurityAgentCoverage.compute(rows: data, agents: [unset])

        XCTAssertEqual(result.first?.installed, 2)
        XCTAssertEqual(result.first?.reporting, 2, "an empty value is still not reporting")
    }

    /// ea-results and the security report land on different cadences, so the count can
    /// briefly exceed a fleet that shrank in between.
    func testPercentNeverPassesOneHundred() {
        XCTAssertEqual(SecurityAgentCoverage.percent(installed: 12, fleet: 10), 100)
    }

    /// jamf-cli 1.31.1 rows carry `{definition_id, device, ea_name, value}` and no id, so
    /// keying by `device` (the computer name) counted two Macs called "MacBook Pro" as one.
    func testRowsWithoutAnIDAreSeparateMacs() throws {
        let data = try rows("""
        [
          {"definition_id": "4", "device": "MacBook Pro",
           "ea_name": "Falcon - Status", "value": "Running"},
          {"definition_id": "4", "device": "MacBook Pro",
           "ea_name": "Falcon - Status", "value": "Running"},
          {"definition_id": "4", "device": "mac-3",
           "ea_name": "Falcon - Status", "value": "Stopped"},
          {"definition_id": "4", "device": "mac-4", "ea_name": "Falcon - Status", "value": ""}
        ]
        """)

        let result = SecurityAgentCoverage.compute(rows: data, agents: [falcon])

        XCTAssertEqual(result.first?.installed, 2, "two Macs share a name; both are connected")
        XCTAssertEqual(result.first?.reporting, 3, "an empty value is still not reporting")
    }

    /// A row that carries a computer id still counts once per id, however many rows it has.
    func testRowsWithAnIDCountOncePerID() throws {
        let data = try rows("""
        [
          {"computer_id": "7", "computer_name": "MacBook Pro",
           "ea_name": "Falcon - Status", "value": "Running"},
          {"computer_id": "7", "computer_name": "MacBook Pro",
           "ea_name": "Falcon - Status", "value": "Running"},
          {"computer_id": "8", "computer_name": "MacBook Pro",
           "ea_name": "Falcon - Status", "value": "Stopped"}
        ]
        """)

        let result = SecurityAgentCoverage.compute(rows: data, agents: [falcon])

        XCTAssertEqual(result.first?.installed, 1)
        XCTAssertEqual(result.first?.reporting, 2)
    }
}
