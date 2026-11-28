import XCTest
@testable import JamfReports

/// The 24-hour grace edges, the version parser and the report lines of `ProtectAgentHealth`
/// that the 2.13 mutation sweep left unpinned.
final class ProtectAgentHealthBoundaryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }

    private func rows(_ json: String) throws -> [ProtectComputerRow] {
        try JSONDecoder().decode([ProtectComputerRow].self, from: Data(json.utf8))
    }

    private func evaluate(
        _ computers: [ProtectComputerRow],
        published: [(Int, Double)]? = nil, installer: (String, Double)? = nil
    ) -> ProtectAgentHealth {
        ProtectAgentHealth.evaluate(
            computers: computers,
            published: published.map { .value($0.map { .init(id: $0.0, created: hoursAgo($0.1)) }) }
                ?? .unavailable(.notCollected(kind: "x")),
            installer: installer.map { .value(.init(version: $0.0, firstSeen: hoursAgo($0.1))) }
                ?? .unavailable(.notCollected(kind: "x")),
            now: now)
    }

    // MARK: - The 24-hour grace

    func testAReleaseIsTheBaselineFromExactlyADayOld() throws {
        let computers = try rows(#"[{"signaturesVersion":100}]"#)
        XCTAssertEqual(evaluate(computers, published: [(101, 24)]).signaturesBehind.share,
                       .init(met: 1, of: 1))
        XCTAssertEqual(evaluate(computers, published: [(101, 24.5)]).signaturesBehind.share,
                       .init(met: 1, of: 1))
        XCTAssertEqual(evaluate(computers, published: [(101, 23.5)]).signaturesBehind,
                       .unavailable(.noVersionOldEnough))
    }

    func testTheBaselineIsTheHighestIDNotTheNewestDate() throws {
        let computers = try rows(#"[{"signaturesVersion":100}]"#)
        let health = evaluate(computers, published: [(101, 72), (100, 30)])
        XCTAssertEqual(health.signaturesBehind.baseline, .published(id: 101, created: hoursAgo(72)))
    }

    func testAnInstallerIsTheBaselineFromExactlyADayOld() throws {
        let computers = try rows(#"[{"version":"5.0"}]"#)
        XCTAssertEqual(evaluate(computers, installer: ("5.1", 24)).agentBehind.share,
                       .init(met: 1, of: 1))
    }

    func testDisconnectedExactlyADayIsNotOverADay() throws {
        let gone = ISO8601Time.string(hoursAgo(24))
        let computers = try rows(
            #"[{"connectionStatus":"Disconnected","lastDisconnection":"\#(gone)"}]"#)
        XCTAssertEqual(evaluate(computers).disconnected.share, .init(met: 0, of: 1))
    }

    // MARK: - Versions

    func testDottedVersionsAreTrimmedDigitsOnly() {
        XCTAssertEqual(ProtectAgentHealth.dottedVersion(" 5.1 "), [5, 1])
        XCTAssertNil(ProtectAgentHealth.dottedVersion("+5.1"),
                     "Int reads a sign; a version has none")
        XCTAssertNil(ProtectAgentHealth.dottedVersion("5.-1"))
    }

    func testAMissingTrailingPartIsZero() {
        XCTAssertTrue(ProtectAgentHealth.isLower([5, 1], than: [5, 1, 1]))
        XCTAssertFalse(ProtectAgentHealth.isLower([5, 1, 1], than: [5, 1]))
    }

    // MARK: - Reasons

    private func disconnected(_ reasons: [String?]) throws -> [ProtectComputerRow] {
        let old = ISO8601Time.string(hoursAgo(30))
        let items = reasons.map { reason in
            let extra = reason.map { #","lastDisconnectionReason":"\#($0)""# } ?? ""
            return #"{"connectionStatus":"Disconnected","lastDisconnection":"\#(old)"\#(extra)}"#
        }
        return try rows("[" + items.joined(separator: ",") + "]")
    }

    func testABlankReasonIsNoReason() throws {
        let health = evaluate(try disconnected(["", nil]))
        XCTAssertEqual(health.disconnectedReasons, [.init(reason: nil, count: 2)])
    }

    func testReasonsAreMostCommonFirstThenByName() throws {
        let health = evaluate(try disconnected(["C", "B", "A", "B"]))
        XCTAssertEqual(health.disconnectedReasons,
                       [.init(reason: "B", count: 2), .init(reason: "A", count: 1),
                        .init(reason: "C", count: 1)])
    }

    func testReasonsAreCappedWithTheirTotal() throws {
        let health = evaluate(try disconnected(["A", "B", "C", "D", "E", "F"]))
        XCTAssertEqual(health.disconnectedReasons.count, ManagementHealth.maxShownValues)
        XCTAssertEqual(health.distinctReasons, 6)
        XCTAssertTrue(health.reportNotes.contains("5 of 6 reasons listed"), "\(health.reportNotes)")
    }

    func testNotesNameOnlyWhatIsThere() throws {
        let notes = evaluate(try disconnected(["A"])).reportNotes
        XCTAssertEqual(notes, ["A: 1"])
    }

    func testAReportRowNamesItsBaseline() throws {
        let computers = try rows(#"[{"signaturesVersion":100}]"#)
        let row = evaluate(computers, published: [(101, 30)]).reportRows[0]
        XCTAssertEqual(row.value, "1 of 1")
        XCTAssertTrue(row.detail.hasPrefix("Compared with version 101, published "), row.detail)
    }
}
