import XCTest
@testable import JamfReports

/// What each score factor measures, from hand-built snapshot rows: the `computers` record
/// fields the score reads, and `SecurityScoreInputs.measures` per kind. A Mac a factor cannot
/// judge is left out of that factor's denominator, never counted as failing.
final class SecurityScoreMeasuresTests: XCTestCase {

    private typealias Factor = SecurityScoreFactor
    private typealias Measure = SecurityScoreMeasure
    private typealias Sources = SecurityScoreInputs.Sources

    private static let now = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z") ?? .now

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func facts(_ json: String) throws -> [ComputerScoreFacts] {
        try XCTUnwrap(ComputerScoreFacts.decodeSnapshot(Data(json.utf8)))
    }

    private func measures(
        _ factors: [Factor], fleet: SecurityFleetCounts? = nil, sources: Sources = .none,
        yaml: String? = nil
    ) throws -> [String: Measure] {
        let config = try yaml.map { try ConfigLoader.loadFromString($0) }
        return SecurityScoreInputs.measures(
            for: factors, fleet: fleet, sources: sources, config: config, now: Self.now)
    }

    private func computer(
        secureBoot: Bool? = nil, bootstrap: Bool? = nil, xprotect: Int? = nil,
        os: String? = nil
    ) -> ComputerScoreFacts {
        ComputerScoreFacts(
            secureBootFull: secureBoot, bootstrapEscrowed: bootstrap, xprotectVersion: xprotect,
            osVersion: os)
    }

    // MARK: - The computers record

    func testSecureBootLevels() throws {
        let rows = try facts("""
            [{"security": {"secureBootLevel": "FULL_SECURITY"}},
             {"security": {"secureBootLevel": "full_security"}},
             {"security": {"secureBootLevel": "MEDIUM_SECURITY"}},
             {"security": {"secureBootLevel": "NO_SECURITY"}},
             {"security": {"secureBootLevel": "NOT_SUPPORTED"}},
             {"security": {"secureBootLevel": ""}},
             {"security": {}},
             {}]
            """)
        XCTAssertEqual(rows.map(\.secureBootFull),
                       [true, true, false, false, nil, nil, nil, nil])
    }

    /// The status wins; the older Bool key is read only when the status says nothing.
    func testBootstrapTokenStatusAndTheLegacyBool() throws {
        let rows = try facts("""
            [{"security": {"bootstrapTokenEscrowedStatus": "ESCROWED"}},
             {"security": {"bootstrapTokenEscrowedStatus": "NOT_ESCROWED"}},
             {"security": {"bootstrapTokenEscrowedStatus": "NOT_SUPPORTED"}},
             {"security": {"bootstrapTokenEscrowed": true}},
             {"security": {"bootstrapTokenEscrowed": false}},
             {"security": {"bootstrapTokenEscrowedStatus": "ESCROWED",
                           "bootstrapTokenEscrowed": false}},
             {"security": {"bootstrapTokenEscrowed": "yes"}},
             {}]
            """)
        XCTAssertEqual(rows.map(\.bootstrapEscrowed),
                       [true, false, nil, true, false, true, nil, nil])
    }

    func testXProtectVersionIsAStringReadAsAnInteger() throws {
        let rows = try facts("""
            [{"security": {"xprotectVersion": "5363"}},
             {"security": {"xprotectVersion": " 5363 "}},
             {"security": {"xprotectVersion": "abc"}},
             {"security": {"xprotectVersion": "53.63"}},
             {"security": {"xprotectVersion": ""}},
             {"security": {"xprotectVersion": 5363}},
             {}]
            """)
        XCTAssertEqual(rows.map(\.xprotectVersion), [5363, 5363, nil, nil, nil, nil, nil])
    }

    func testOSVersionIsReadAndTrimmed() throws {
        let rows = try facts("""
            [{"operatingSystem": {"version": "26.6.2"}},
             {"operatingSystem": {"version": " 26.6 "}},
             {"operatingSystem": {"version": 26}},
             {"operatingSystem": {}},
             {}]
            """)
        XCTAssertEqual(rows.map(\.osVersion), ["26.6.2", "26.6", nil, nil, nil])
    }

    /// A section or a record of the wrong type costs that record its fields, not the snapshot
    /// its other records: the count of Macs is unchanged.
    func testARecordOrSectionOfTheWrongTypeReadsNilAndKeepsTheRest() throws {
        let rows = try facts("""
            [{"security": "oops", "operatingSystem": 5},
             42,
             "text",
             {"security": {"secureBootLevel": "FULL_SECURITY"},
              "operatingSystem": {"version": "26.6.2"}}]
            """)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0], computer())
        XCTAssertEqual(rows[1], computer())
        XCTAssertEqual(rows[2], computer())
        XCTAssertEqual(rows[3], computer(secureBoot: true, os: "26.6.2"))
    }

    func testASnapshotIsABareArrayOrAResultsEnvelope() throws {
        let record = "{\"security\": {\"secureBootLevel\": \"FULL_SECURITY\"}}"
        XCTAssertEqual(try facts("[\(record), \(record)]").count, 2)
        XCTAssertEqual(try facts("{\"results\": [\(record)]}").count, 1)
        XCTAssertEqual(try facts("[]"), [])
        XCTAssertEqual(try facts("{\"results\": []}"), [])
        XCTAssertNil(ComputerScoreFacts.decodeSnapshot(Data("{\"nodes\": [1]}".utf8)))
        XCTAssertNil(ComputerScoreFacts.decodeSnapshot(Data("not json".utf8)))
    }

    // MARK: - Secure Boot and bootstrap token

    func testSecureBootIsTheMacsAtFullSecurityOverTheMacsThatReportALevel() throws {
        let sources = Sources(computers: [
            computer(secureBoot: true), computer(secureBoot: true),
            computer(secureBoot: false), computer(secureBoot: nil),
        ])
        let result = try measures([Factor(.secureBoot, weight: 5)], sources: sources)
        XCTAssertEqual(result["secure_boot"], Measure(passing: 2, evaluated: 3),
                       "the Mac that reports no level is left out, not failing")
    }

    func testBootstrapTokenIsTheEscrowedMacsOverTheMacsThatReportAStatus() throws {
        let sources = Sources(computers: [
            computer(bootstrap: true), computer(bootstrap: false), computer(bootstrap: false),
            computer(bootstrap: nil), computer(bootstrap: nil),
        ])
        let result = try measures([Factor(.bootstrapToken, weight: 5)], sources: sources)
        XCTAssertEqual(result["bootstrap_token"], Measure(passing: 1, evaluated: 3))
    }

    func testAFactorOnTheComputersSnapshotHasNoDataWithoutOne() throws {
        let natives: [Factor] = [
            Factor(.secureBoot, weight: 5), Factor(.bootstrapToken, weight: 5),
        ]
        XCTAssertTrue(try measures(natives).isEmpty, "snapshot never collected")
        let none = try measures(natives, sources: Sources(computers: []))
        XCTAssertNil(none["secure_boot"]?.share, "no Macs: nothing judged")
        XCTAssertNil(none["bootstrap_token"]?.share)
    }

    // MARK: - macOS and XProtect currency

    private static let sofaJSON = """
        {"OSVersions": [{"Latest": {"ProductVersion": "26.7.1",
                                    "ReleaseDate": "2026-09-28T17:00:00Z"},
                         "SecurityReleases": [
                           {"ProductVersion": "26.7", "ReleaseDate": "2026-09-15T17:00:00Z"},
                           {"ProductVersion": "26.6.2", "ReleaseDate": "2026-08-17T17:00:00Z"},
                           {"ProductVersion": "26.6.1", "ReleaseDate": "2026-07-20T17:00:00Z"}]}],
         "XProtectPlistConfigData": {"com.apple.XProtect": "5363",
                                     "ReleaseDate": "2026-09-29T17:00:00Z"}}
        """

    private var sofa: SOFAScoreFeed? { SOFAScoreFeed.decode(Data(Self.sofaJSON.utf8)) }

    /// With the default 30-day grace a Tahoe Mac needs 26.6.2; a Mac on a major the feed does
    /// not list, and a Mac that reports no version, are left out.
    func testOSCurrentJudgesEachMacAgainstItsMajorsRequiredRelease() throws {
        let sources = Sources(
            computers: [
                computer(os: "26.6.2"), computer(os: "26.7.1"), computer(os: "26.6.1"),
                computer(os: "14.8"), computer(os: nil),
            ], sofa: sofa)
        let result = try measures([Factor(.osCurrent, weight: 15)], sources: sources)
        XCTAssertEqual(result["os_current"], Measure(passing: 2, evaluated: 3))
    }

    func testOSCurrentFollowsTheFactorsGraceDays() throws {
        let sources = Sources(
            computers: [computer(os: "26.6.2"), computer(os: "26.7.1"), computer(os: "26.6.1")],
            sofa: sofa)
        // 5 days of grace: 26.7.1 is required.
        let short = try measures([Factor(.osCurrent, weight: 1, graceDays: 5)], sources: sources)
        XCTAssertEqual(short["os_current"], Measure(passing: 1, evaluated: 3))
        // 365 days: every release is inside the grace period, so every Mac is current.
        let long = try measures([Factor(.osCurrent, weight: 1, graceDays: 365)], sources: sources)
        XCTAssertEqual(long["os_current"], Measure(passing: 3, evaluated: 3))
    }

    func testOSCurrentHasNoDataWithoutTheSOFAFeedOrTheComputersSnapshot() throws {
        let factors = [Factor(.osCurrent, weight: 15)]
        let macs = [computer(os: "26.6.2")]
        XCTAssertTrue(try measures(factors, sources: Sources(computers: macs)).isEmpty,
                      "no SOFA feed cached")
        XCTAssertTrue(try measures(factors, sources: Sources(sofa: sofa)).isEmpty,
                      "no computers snapshot")
    }

    /// 5363 came out 5.8 days before `now`: with the default 14 days an older XProtect is
    /// still current; with 3 days it is behind. A Mac with no XProtect version is left out.
    func testXProtectCurrentJudgesAgainstTheNewestWithinTheGracePeriod() throws {
        let sources = Sources(
            computers: [
                computer(xprotect: 5363), computer(xprotect: 5362), computer(xprotect: 5000),
                computer(xprotect: nil),
            ], sofa: sofa)
        let byDefault = try measures([Factor(.xprotectCurrent, weight: 5)], sources: sources)
        XCTAssertEqual(byDefault["xprotect_current"], Measure(passing: 3, evaluated: 3))
        let strict = try measures(
            [Factor(.xprotectCurrent, weight: 5, graceDays: 3)], sources: sources)
        XCTAssertEqual(strict["xprotect_current"], Measure(passing: 1, evaluated: 3))
    }

    func testXProtectCurrentHasNoDataWhenTheFeedHasNoXProtect() throws {
        let noXProtect = SOFAScoreFeed.decode(Data("""
            {"OSVersions": [{"Latest": {"ProductVersion": "26.7.1",
                                        "ReleaseDate": "2026-09-28T17:00:00Z"}}]}
            """.utf8))
        let sources = Sources(computers: [computer(xprotect: 5363)], sofa: noXProtect)
        XCTAssertTrue(
            try measures([Factor(.xprotectCurrent, weight: 5)], sources: sources).isEmpty)
    }

    // MARK: - Patch compliance

    private func patchRows(_ rows: [(onLatest: Int, total: Int)]) throws -> [PatchStatusRow] {
        let items = rows.enumerated().map { index, row in
            """
            {"title": "T\(index)", "id": "\(index)", "on_latest": \(row.onLatest),
             "on_other": 0, "total": \(row.total), "latest": "1.0", "compliance_pct": "0%"}
            """
        }
        return try decode([PatchStatusRow].self, "[" + items.joined(separator: ",") + "]")
    }

    /// Device-title pairs over all titles with devices, never an average of the titles'
    /// percentages: 80 of 100 and 10 of 50 is 90 of 150, not 45% per title.
    func testPatchComplianceIsDeviceWeightedAndLeavesOutTitlesWithoutDevices() throws {
        let sources = Sources(patchRows: try patchRows([(80, 100), (10, 50), (0, 0)]))
        let result = try measures([Factor(.patchCompliance, weight: 10)], sources: sources)
        XCTAssertEqual(result["patch_compliance"], Measure(passing: 90, evaluated: 150))
        XCTAssertEqual(try XCTUnwrap(result["patch_compliance"]?.share), 60.0, accuracy: 0.0001)
    }

    func testPatchComplianceNeverCountsMoreThanATitlesDevices() throws {
        let sources = Sources(patchRows: try patchRows([(120, 100)]))
        let result = try measures([Factor(.patchCompliance, weight: 10)], sources: sources)
        XCTAssertEqual(result["patch_compliance"], Measure(passing: 100, evaluated: 100))
    }

    func testPatchComplianceHasNoDataWithoutTitlesWithDevices() throws {
        let factors = [Factor(.patchCompliance, weight: 10)]
        XCTAssertTrue(try measures(factors).isEmpty, "patch-status never collected")
        XCTAssertTrue(try measures(factors, sources: Sources(patchRows: [])).isEmpty)
        XCTAssertTrue(
            try measures(factors, sources: Sources(patchRows: try patchRows([(0, 0)]))).isEmpty)
    }

    // MARK: - Checked in

    private var complianceRows: [DeviceComplianceRow] {
        get throws {
            try decode([DeviceComplianceRow].self, """
                [{"name": "a", "days_since_contact": "5"},
                 {"name": "b", "days_since_contact": 40},
                 {"name": "c", "stale": true},
                 {"name": "d", "stale": false},
                 {"name": "e"},
                 {"name": "f", "days_since_checkin": 30}]
                """)
        }
    }

    /// `isStale(atDays:)` decides: the day count when there is one (30 days is stale at a
    /// 30-day window), else the server's `stale` flag. A row with neither is left out.
    /// a, d pass; b, c, f fail; e is not judged.
    func testCheckedInUsesTheStaleRuleAndLeavesOutRowsWithNeitherFigure() throws {
        let sources = Sources(complianceRows: try complianceRows)
        let result = try measures([Factor(.checkedIn, weight: 5)], sources: sources)
        XCTAssertEqual(result["checked_in"], Measure(passing: 2, evaluated: 5))
    }

    func testCheckedInFollowsTheConfiguredStaleWindow() throws {
        let sources = Sources(complianceRows: try complianceRows)
        let result = try measures(
            [Factor(.checkedIn, weight: 5)], sources: sources,
            yaml: "thresholds:\n  stale_device_days: 45\n")
        // b (40 days) and f (30 days) now pass; c still fails on the stale flag.
        XCTAssertEqual(result["checked_in"], Measure(passing: 4, evaluated: 5))
    }

    func testCheckedInHasNoDataWithoutDeviceComplianceRows() throws {
        XCTAssertTrue(try measures([Factor(.checkedIn, weight: 5)]).isEmpty)
    }

    // MARK: - Agents

    private static let agentYAML = """
        security_agents:
          - name: Falcon
            column: Falcon State
            connected_value: connected
        compliance:
          enabled: true
          baselines:
            - name: Baseline A
              failures_count_column: Count A
            - name: Baseline B
              failures_count_column: Count B
        """

    private func eaRows(_ rows: [(id: Int, ea: String, value: String)]) throws -> [EAResultRow] {
        let items = rows.map {
            "{\"computer_id\": \"\($0.id)\", \"computer_name\": \"m\($0.id)\", "
                + "\"ea_name\": \"\($0.ea)\", \"value\": \"\($0.value)\"}"
        }
        return try decode([EAResultRow].self, "[" + items.joined(separator: ",") + "]")
    }

    private func fleet(_ total: Int) -> SecurityFleetCounts {
        SecurityFleetCounts.build(
            totalDevices: total, onCounts: [.sip: total], devices: [], hardware: [:],
            policy: .default)
    }

    /// Macs 1-3 connected, 4 reports an error and 5 has no row: coverage counts 3 connected of
    /// 4 reporting, and the score takes the share over the whole fleet of 10, as the summary's
    /// EDR figure does. A Mac with no value counts as not connected.
    func testAnAgentIsScoredOverTheWholeFleet() throws {
        let rows = try eaRows([
            (1, "Falcon State", "connected"), (2, "Falcon State", "connected"),
            (3, "Falcon State", "Connected"), (4, "Falcon State", "error"),
        ])
        let factor = Factor(.agent, weight: 5, target: "Falcon")
        let withFleet = try measures(
            [factor], fleet: fleet(10), sources: Sources(eaRows: rows), yaml: Self.agentYAML)
        XCTAssertEqual(withFleet["agent:falcon"], Measure(passing: 3, evaluated: 10))

        let noFleet = try measures(
            [factor], sources: Sources(eaRows: rows), yaml: Self.agentYAML)
        XCTAssertEqual(noFleet["agent:falcon"], Measure(passing: 3, evaluated: 4),
                       "without the security report, the Macs that report are the fleet")
    }

    /// The ea-results and the security report are collected on different cadences, so a fleet
    /// that shrank in between must not score above 100%.
    func testAnAgentCountNeverPassesTheFleet() throws {
        let rows = try eaRows((1...5).map { ($0, "Falcon State", "connected") })
        let result = try measures(
            [Factor(.agent, weight: 5, target: "Falcon")], fleet: fleet(3),
            sources: Sources(eaRows: rows), yaml: Self.agentYAML)
        XCTAssertEqual(result["agent:falcon"], Measure(passing: 3, evaluated: 3))
    }

    func testAnAgentIsMatchedByNameIgnoringCase() throws {
        let rows = try eaRows([(1, "falcon state", "connected")])
        let result = try measures(
            [Factor(.agent, weight: 5, target: "FALCON")], sources: Sources(eaRows: rows),
            yaml: Self.agentYAML)
        XCTAssertEqual(result["agent:falcon"], Measure(passing: 1, evaluated: 1))
    }

    func testAnAgentHasNoDataWhenNoMacReportsItOrItIsNotConfigured() throws {
        let rows = try eaRows([(1, "Some Other EA", "connected")])
        let sources = Sources(eaRows: rows)
        let falcon = Factor(.agent, weight: 5, target: "Falcon")
        XCTAssertTrue(try measures([falcon], sources: sources, yaml: Self.agentYAML).isEmpty,
                      "no Mac reports the agent's extension attribute")
        let ghost = Factor(.agent, weight: 5, target: "Ghost")
        let reporting = Sources(eaRows: try eaRows([(1, "Falcon State", "connected")]))
        XCTAssertTrue(try measures([ghost], sources: reporting, yaml: Self.agentYAML).isEmpty,
                      "no security_agents entry has this name")
        XCTAssertTrue(try measures([falcon], sources: reporting).isEmpty, "no config at all")
        XCTAssertTrue(try measures([falcon], yaml: Self.agentYAML).isEmpty, "no ea-results")
    }

    // MARK: - mSCP

    /// Baseline A passes on Macs 1-2 of 4 (zero failures); B passes on all four.
    private func baselineRows() throws -> [EAResultRow] {
        try eaRows([
            (1, "Count A", "0"), (2, "Count A", "0"), (3, "Count A", "5"), (4, "Count A", "5"),
            (1, "Count B", "0"), (2, "Count B", "0"), (3, "Count B", "0"), (4, "Count B", "0"),
        ])
    }

    func testMSCPWithoutANameScoresTheFirstBaseline() throws {
        let result = try measures(
            [Factor(.mscp, weight: 10)], sources: Sources(eaRows: try baselineRows()),
            yaml: Self.agentYAML)
        XCTAssertEqual(result["mscp"], Measure(passing: 2, evaluated: 4))
    }

    func testMSCPWithANameScoresThatBaselineIgnoringCase() throws {
        let result = try measures(
            [Factor(.mscp, weight: 10, target: "baseline b")],
            sources: Sources(eaRows: try baselineRows()), yaml: Self.agentYAML)
        XCTAssertEqual(result["mscp:baseline b"], Measure(passing: 4, evaluated: 4))
    }

    func testMSCPHasNoDataForAnUnknownBaselineNoBaselinesOrNoRowsForTheColumn() throws {
        let sources = Sources(eaRows: try baselineRows())
        XCTAssertTrue(try measures(
            [Factor(.mscp, weight: 10, target: "Baseline Z")], sources: sources,
            yaml: Self.agentYAML).isEmpty)
        XCTAssertTrue(try measures(
            [Factor(.mscp, weight: 10)], sources: sources,
            yaml: "thresholds:\n  stale_device_days: 30\n").isEmpty, "no baselines configured")
        let otherColumn = Sources(eaRows: try eaRows([(1, "Unrelated", "0")]))
        XCTAssertTrue(try measures(
            [Factor(.mscp, weight: 10)], sources: otherColumn, yaml: Self.agentYAML).isEmpty,
                      "no Mac has a value for the baseline's column")
    }

    // MARK: - The four controls

    func testTheControlsComeFromTheSecurityReportUnderThePolicy() throws {
        let policy = SecurityControlPolicy(sip: .warning)
        let counts = SecurityFleetCounts.build(
            totalDevices: 10, onCounts: [.fileVault: 8, .sip: 7, .firewall: 10],
            devices: [], hardware: [:], policy: policy)
        let factors = [
            Factor(.fileVault, weight: 15), Factor(.sip, weight: 10),
            Factor(.firewall, weight: 10), Factor(.gatekeeper, weight: 5),
        ]
        let result = try measures(factors, fleet: counts)
        XCTAssertEqual(result["filevault"], Measure(passing: 8, evaluated: 10))
        XCTAssertEqual(result["sip"], Measure(passing: 10, evaluated: 10),
                       "a warning is not a gap, so it passes")
        XCTAssertEqual(result["firewall"], Measure(passing: 10, evaluated: 10))
        XCTAssertNil(result["gatekeeper"], "the report carries no Gatekeeper count")
        XCTAssertTrue(try measures(factors, fleet: nil).isEmpty, "no security report")
    }

    // MARK: - Together

    /// Measures are keyed by `SecurityScoreFactor.key` and a factor with no data is absent, so
    /// the calculator lists it as missing.
    func testMeasuresAreKeyedByFactorKeyAndOmitFactorsWithoutData() throws {
        let sources = Sources(
            computers: [computer(secureBoot: true), computer(secureBoot: false)],
            eaRows: try eaRows([(1, "Falcon State", "connected")]))
        let factors = [
            Factor(.secureBoot, weight: 5),
            Factor(.agent, weight: 5, target: "Falcon"),
            Factor(.patchCompliance, weight: 10),
        ]
        let result = try measures(factors, sources: sources, yaml: Self.agentYAML)
        XCTAssertEqual(Set(result.keys), ["secure_boot", "agent:falcon"])
        let score = SecurityScoreCalculator.score(factors: factors, measures: result)
        XCTAssertEqual(score.missing.map(\.id), ["patch_compliance"])
        // (50 x 5 + 100 x 5) / 10
        XCTAssertEqual(score.value, 75.0, accuracy: 0.0001)
    }
}
