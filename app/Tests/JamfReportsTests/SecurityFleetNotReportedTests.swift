import Foundation
import XCTest
@testable import JamfReports

/// A Mac whose value for a control Jamf did not report (NOT_COLLECTED, a blank) is not a Mac
/// with the control off. The summary is the count of Macs with a control on; the device rows
/// only say which of the others are measured off and which are not reported. P0, P1, the score
/// and every share count the measured ones, and each surface says how many did not report.
@MainActor
final class SecurityFleetNotReportedTests: XCTestCase {

    private typealias Control = SecurityFleetCounts.Control

    nonisolated(unsafe) private var testRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testRoot = GoldenFleetWorkspace.freshRoot()
    }

    override func tearDownWithError() throws {
        if let dir = testRoot { try? FileManager.default.removeItem(at: dir) }
        testRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func summary(
        total: Int, fileVault: Int, sip: Int, firewall: Int, gatekeeper: Int
    ) -> [String: Any] {
        GoldenFleetWorkspace.securitySummaryPayload(
            total: total, filevault: fileVault, sip: sip, firewall: firewall,
            gatekeeper: gatekeeper)[0]
    }

    /// A device row; `firewall` nil leaves the key out, as a row that never carried it.
    private func row(
        _ serial: String, fileVault: String = "ENCRYPTED", sip: String = "ENABLED",
        firewall: Bool? = true, gatekeeper: String = "APP_STORE"
    ) -> [String: Any] {
        var row = GoldenFleetWorkspace.securityDeviceRow(
            name: "Lab-" + serial, serial: serial, osVersion: "15.4.1", fileVault: fileVault,
            sip: sip, firewall: firewall ?? true, gatekeeper: gatekeeper)
        if firewall == nil { row["firewall"] = nil }
        return row
    }

    private func rows(
        _ count: Int, prefix: String, _ make: (String) -> [String: Any]
    ) -> [[String: Any]] {
        (0..<count).map { make("\(prefix)\($0)") }
    }

    private func counts(
        _ items: [[String: Any]], policy: SecurityControlPolicy = .default,
        hardware: [String: Bool] = [:]
    ) throws -> SecurityFleetCounts {
        let data = try JSONSerialization.data(withJSONObject: items)
        let decoded = try JSONDecoder().decode([SecurityReportItem].self, from: data)
        return try XCTUnwrap(SecurityFleetCounts.build(
            items: decoded, hardware: hardware, policy: policy))
    }

    /// Like the dummy tenant: 101 Macs, SIP on one, NOT_COLLECTED on the other 100.
    private func dummyLikeReport() -> [[String: Any]] {
        [summary(total: 101, fileVault: 101, sip: 1, firewall: 101, gatekeeper: 101),
         row("DUMMY000")]
            + rows(100, prefix: "DUMMY1") { row($0, sip: "NOT_COLLECTED") }
    }

    // MARK: - The counts

    func testMacsThatDidNotReportSIPAreNotFailures() throws {
        let fleet = try counts(dummyLikeReport())
        XCTAssertEqual(fleet.controls[.sip],
                       Control(level: .fail, on: 1, fail: 0, warning: 0, notReported: 100))
        XCTAssertEqual(fleet.p0, 0)
        XCTAssertEqual(fleet.p0NotReported, 100)
        XCTAssertEqual(fleet.p1, 0)
        XCTAssertEqual(fleet.p1NotReported, 0)
        XCTAssertEqual(try XCTUnwrap(fleet.nonFailingPct(.sip)), 100, accuracy: 0.001)
        // Out of the score's SIP share too: the one Mac that reported is on.
        XCTAssertEqual(fleet.scoreMeasure(for: .sip),
                       SecurityScoreMeasure(passing: 1, evaluated: 1))
        XCTAssertEqual(SecurityScoreTestSupport.score(fleet).value, 100, accuracy: 0.001)
    }

    func testOnlyMacsMeasuredOffAreFailures() throws {
        let fleet = try counts(
            [summary(total: 10, fileVault: 10, sip: 4, firewall: 10, gatekeeper: 10)]
                + rows(4, prefix: "ON") { row($0) }
                + rows(3, prefix: "OFF") { row($0, sip: "DISABLED") }
                + rows(3, prefix: "NONE") { row($0, sip: "NOT_COLLECTED") })
        XCTAssertEqual(fleet.controls[.sip],
                       Control(level: .fail, on: 4, fail: 3, warning: 0, notReported: 3))
        XCTAssertEqual(fleet.p0, 3)
        XCTAssertEqual(fleet.p0NotReported, 3)
        // 4 of the 7 Macs that reported.
        XCTAssertEqual(try XCTUnwrap(fleet.nonFailingPct(.sip)), 400.0 / 7, accuracy: 0.001)
        XCTAssertEqual(fleet.scoreMeasure(for: .sip),
                       SecurityScoreMeasure(passing: 4, evaluated: 7))
    }

    /// At warning the measured-off Macs warn, the others are still not reported, and the
    /// score counts a warning as compliant over the Macs that reported.
    func testAWarningIsAMeasuredOffMacToo() throws {
        let policy = SecurityControlPolicy(sip: .warning)
        let fleet = try counts(
            [summary(total: 10, fileVault: 10, sip: 4, firewall: 10, gatekeeper: 10)]
                + rows(4, prefix: "ON") { row($0) }
                + rows(3, prefix: "OFF") { row($0, sip: "DISABLED") }
                + rows(3, prefix: "NONE") { row($0, sip: "") }, policy: policy)
        XCTAssertEqual(fleet.controls[.sip],
                       Control(level: .warning, on: 4, fail: 0, warning: 3, notReported: 3))
        XCTAssertEqual(fleet.scoreMeasure(for: .sip),
                       SecurityScoreMeasure(passing: 7, evaluated: 7))
    }

    /// With every Mac measured nothing is unreported: the same counts as the summary alone.
    func testAFullyMeasuredFleetCountsAsBefore() throws {
        let report: [[String: Any]] = [
            summary(total: 10, fileVault: 6, sip: 7, firewall: 8, gatekeeper: 9),
        ] + (0..<10).map { index in
            row("FULL\(index)", fileVault: index < 6 ? "ENCRYPTED" : "UNENCRYPTED",
                sip: index < 7 ? "ENABLED" : "DISABLED", firewall: index < 8,
                gatekeeper: index < 9 ? "APP_STORE" : "DISABLED")
        }
        let withRows = try counts(report)
        let summaryOnly = try counts([report[0]])
        XCTAssertEqual(withRows, summaryOnly)
        XCTAssertEqual(withRows.p0, 4 + 3 + 2)
        XCTAssertEqual(withRows.p0NotReported, 0)
        for control in SecurityControl.allCases {
            XCTAssertEqual(withRows.controls[control]?.notReported, 0, "\(control)")
            XCTAssertEqual(withRows.scoreMeasure(for: control)?.evaluated, 10,
                           "\(control): a share of the whole fleet")
        }
    }

    /// The summary counts Gatekeeper on for 100 Macs while the rows say NOT_COLLECTED for
    /// them: the one Mac not on is the measured-off one, not an unreported one.
    func testRowsMeasuredOffTakeTheirShareOfTheSummarysOffMacsFirst() throws {
        let fleet = try counts(
            [summary(total: 101, fileVault: 101, sip: 101, firewall: 101, gatekeeper: 100)]
                + [row("OFF", gatekeeper: "DISABLED")]
                + rows(100, prefix: "NONE") { row($0, gatekeeper: "NOT_COLLECTED") })
        XCTAssertEqual(fleet.controls[.gatekeeper],
                       Control(level: .fail, on: 100, fail: 1, warning: 0, notReported: 0))
        XCTAssertEqual(fleet.p1, 1)
    }

    /// Rows only say which of the summary's non-on Macs are unreported; more unreported rows
    /// than non-on Macs leave the summary's count in charge.
    func testUnreportedMacsNeverExceedTheSummarysNotOnCount() throws {
        let fleet = try counts(
            [summary(total: 10, fileVault: 10, sip: 8, firewall: 10, gatekeeper: 10)]
                + rows(5, prefix: "ON") { row($0) }
                + rows(5, prefix: "NONE") { row($0, sip: "NOT_COLLECTED") })
        XCTAssertEqual(fleet.controls[.sip],
                       Control(level: .fail, on: 8, fail: 0, warning: 0, notReported: 2))
    }

    func testWithoutDeviceRowsNoMacIsUnreported() throws {
        let fleet = try counts(
            [summary(total: 101, fileVault: 101, sip: 1, firewall: 101, gatekeeper: 101)])
        XCTAssertEqual(fleet.controls[.sip],
                       Control(level: .fail, on: 1, fail: 100, warning: 0, notReported: 0))
        XCTAssertEqual(fleet.p0, 100)
    }

    /// The report's firewall is a boolean: a row that has it is measured, either way. A row
    /// that never carried it is not reported.
    func testAFirewallBooleanIsAlwaysMeasured() throws {
        let fleet = try counts(
            [summary(total: 4, fileVault: 4, sip: 4, firewall: 0, gatekeeper: 4)]
                + rows(2, prefix: "OFF") { row($0, firewall: false) }
                + rows(2, prefix: "NONE") { row($0, firewall: nil) })
        XCTAssertEqual(fleet.controls[.firewall],
                       Control(level: .fail, on: 0, fail: 2, warning: 0, notReported: 2))
    }

    func testEveryMacUnreportedLeavesNoShareAndNoScoreMetric() throws {
        let fleet = try counts(
            [summary(total: 4, fileVault: 4, sip: 0, firewall: 4, gatekeeper: 4)]
                + rows(4, prefix: "NONE") { row($0, sip: "NOT_COLLECTED") })
        XCTAssertEqual(fleet.controls[.sip],
                       Control(level: .fail, on: 0, fail: 0, warning: 0, notReported: 4))
        XCTAssertNil(fleet.nonFailingPct(.sip))
        XCTAssertNil(fleet.scoreMeasure(for: .sip)?.share, "no Mac is left to judge")
        let score = SecurityScoreTestSupport.score(fleet)
        XCTAssertTrue(score.missing.contains { $0.kind == .sip })
    }

    /// An ignored control keeps its count, and its unreported Macs stay in that count as
    /// information only. The policy drops its factor, so the score neither scores it nor calls
    /// it missing.
    func testAnIgnoredControlKeepsItsUnreportedCountAsInformation() throws {
        let policy = SecurityControlPolicy(sip: .ignore)
        let fleet = try counts(dummyLikeReport(), policy: policy)
        XCTAssertEqual(fleet.controls[.sip],
                       Control(level: .ignore, on: 1, fail: 0, warning: 0, notReported: 100))
        XCTAssertEqual(fleet.p0NotReported, 0, "SIP is not counted, so P0 leaves out nothing")
        XCTAssertEqual(fleet.scoreMeasure(for: .sip),
                       SecurityScoreMeasure(passing: 1, evaluated: 101))
        let score = SecurityScoreTestSupport.score(fleet, policy: policy)
        XCTAssertFalse(score.missing.contains { $0.kind == .sip })
        XCTAssertFalse(score.available.contains { $0.kind == .sip })
        XCTAssertNil(fleet.nonFailingPct(.sip))
    }

    // MARK: - The hardware rule

    private func hardwareReport(unreported: Int) -> [[String: Any]] {
        [summary(total: 10, fileVault: 5, sip: 10, firewall: 10, gatekeeper: 10)]
            + rows(5, prefix: "ON") { row($0) }
            + rows(2, prefix: "AS") { row($0, fileVault: "UNENCRYPTED") }
            + rows(unreported, prefix: "AX") { row($0, fileVault: "NOT_COLLECTED") }
            + rows(3 - unreported, prefix: "IN") { row($0, fileVault: "UNENCRYPTED") }
    }

    private var hardware: [String: Bool] {
        HardwareEncryption.index(computers: (0..<5).flatMap { index in
            ["AS\(index)", "AX\(index)"].map { serial in
                ["general": ["name": "Lab-\(serial)"],
                 "hardware": ["serialNumber": serial, "appleSilicon": true]] as [String: Any]
            }
        })
    }

    /// Five Macs are not on: two measured off (Apple silicon), three not reported. Only the
    /// measured-off ones move to the hardware level.
    func testTheHardwareMoveIsCappedAtTheMeasuredOffMacs() throws {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
        let fleet = try counts(hardwareReport(unreported: 3), policy: policy, hardware: hardware)
        XCTAssertEqual(fleet.controls[.fileVault],
                       Control(level: .fail, on: 5, fail: 0, warning: 2, notReported: 3))
        XCTAssertEqual(fleet.fileVaultOffHardwareEncrypted, 2)
        // 7 Macs reported; the 2 warned ones are not failing.
        XCTAssertEqual(try XCTUnwrap(fleet.nonFailingPct(.fileVault)), 100, accuracy: 0.001)
        XCTAssertEqual(fleet.scoreMeasure(for: .fileVault),
                       SecurityScoreMeasure(passing: 7, evaluated: 7))
    }

    /// At ignore the two moved Macs leave the share and the three that did not report leave
    /// it as well: five of the ten Macs are scored.
    func testHardwareIgnoredMacsAndUnreportedMacsBothLeaveTheFileVaultShare() throws {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore)
        let fleet = try counts(hardwareReport(unreported: 3), policy: policy, hardware: hardware)
        XCTAssertEqual(fleet.controls[.fileVault],
                       Control(level: .fail, on: 5, fail: 0, warning: 0, notReported: 3))
        XCTAssertEqual(fleet.fileVaultOffHardwareEncrypted, 2)
        XCTAssertEqual(fleet.scoreMeasure(for: .fileVault),
                       SecurityScoreMeasure(passing: 5, evaluated: 5))
        XCTAssertEqual(try XCTUnwrap(fleet.nonFailingPct(.fileVault)), 100, accuracy: 0.001)
    }

    /// An Intel Mac without hardware encryption stays a plain failure beside the unreported.
    func testAMeasuredOffMacTheRuleDoesNotMoveStaysAFailure() throws {
        let policy = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
        let fleet = try counts(hardwareReport(unreported: 2), policy: policy, hardware: hardware)
        XCTAssertEqual(fleet.controls[.fileVault],
                       Control(level: .fail, on: 5, fail: 1, warning: 2, notReported: 2))
        XCTAssertEqual(fleet.p0, 1)
    }

    // MARK: - Surfaces

    @discardableResult
    private func writeReport(
        _ items: [[String: Any]], to name: String = "fleet"
    ) throws -> (dataDir: URL, security: URL) {
        let dataDir = testRoot.appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("jamf-cli-data", isDirectory: true)
        let url = try GoldenFleetWorkspace.writeSnapshot(
            kind: "security", dataDir: dataDir, at: Date(), rows: items)
        return (dataDir, url)
    }

    private func text(_ value: CellValue) -> String {
        switch value {
        case .string(let s): s
        case .int(let i): "\(i)"
        case .double(let d): "\(d)"
        case .bool(let b): "\(b)"
        case .blank: ""
        }
    }

    private func rowCells(
        _ workbook: Workbook, _ sheet: String, _ label: String
    ) -> [Int: String]? {
        guard let cells = workbook.sheet(named: sheet)?.dedupedCells,
              let first = cells.first(where: { $0.col == 0 && text($0.value) == label })
        else { return nil }
        return Dictionary(uniqueKeysWithValues: cells.filter { $0.row == first.row }
            .map { ($0.col, text($0.value)) })
    }

    func testSecurityPostureScreenSaysHowManyDidNotReport() throws {
        let url = try writeReport(dummyLikeReport()).security
        let snapshot = try SecurityPostureService.load(from: url, policy: .default, hardware: [:])
        XCTAssertEqual(snapshot.fleetCounts.controls[.sip]?.notReported, 100)
        let fleet = snapshot.fleetCounts
        XCTAssertEqual(
            SecurityPostureView.kpiTileSub(.sip, on: 1, total: 101, fleet: fleet),
            "1 of 101 · not reported: 100")
        XCTAssertEqual(
            SecurityPostureView.kpiTileSub(.fileVault, on: 101, total: 101, fleet: fleet),
            "101 of 101", "nothing to say when every Mac reported")
        XCTAssertEqual(
            SecurityPostureView.actionCaption(
                "FileVault / SIP / Firewall gaps", notReported: fleet.p0NotReported),
            "FileVault / SIP / Firewall gaps · not reported: 100")
        XCTAssertEqual(
            SecurityPostureView.actionCaption("Gatekeeper gaps", notReported: fleet.p1NotReported),
            "Gatekeeper gaps")
        XCTAssertEqual(SecurityPostureView.p0TileCount(fleet), 0)
        XCTAssertEqual(
            SecurityPostureView.score(snapshot.scoredFromReportAlone()).value, 100, accuracy: 0.001)
    }

    func testTheKPITileLeavesAnIgnoredControlsNoteAlone() throws {
        let policy = SecurityControlPolicy(sip: .ignore)
        let url = try writeReport(dummyLikeReport()).security
        let snapshot = try SecurityPostureService.load(from: url, policy: policy, hardware: [:])
        XCTAssertEqual(
            SecurityPostureView.kpiTileSub(
                .sip, on: 1, total: 101, fleet: snapshot.fleetCounts),
            "Not counted by this workspace's policy")
    }

    func testThePostureInsightCarriesTheUnreportedCount() throws {
        let url = try writeReport(dummyLikeReport()).security
        let snapshot = try SecurityPostureService.load(from: url, policy: .default, hardware: [:])
        let context = FleetInsightInput.posture(.security(snapshot))?.promptContext() ?? ""
        XCTAssertTrue(context.contains(
            "- Macs that did not report SIP (not counted as failing): 100"), context)
        XCTAssertTrue(context.contains(
            "- System Integrity Protection (SIP) enabled on 1.0% of devices; "
                + "off or not reported on 99.0%"), context)
        XCTAssertFalse(context.contains("did not report FileVault"), context)
    }

    /// The summary writer, the Security Posture model, the Executive Summary and the HTML
    /// tiles take P0, P1 and the score from the same counts.
    func testEverySurfaceCountsTheSameMeasuredMacs() async throws {
        let fleet = try writeReport(dummyLikeReport())
        let config = ReportConfig()

        let summariesDir = testRoot.appendingPathComponent("summaries", isDirectory: true)
        ReportEngine(config: config, dataDir: fleet.dataDir)
            .emitSummaryJSON(summariesDir: summariesDir)
        let written = try XCTUnwrap(SummaryJSONParser.parseDirectory(summariesDir).first)
        XCTAssertEqual(written.actionItemsP0, 0)
        XCTAssertEqual(written.actionItemsP1, 0)
        XCTAssertEqual(written.securityScore, 100)
        XCTAssertEqual(try XCTUnwrap(written.sipPct), 1.0, accuracy: 0.05, "the share is a fact")

        let metrics = CoreDashboard.executiveMetrics(config: config, dataDir: fleet.dataDir)
        XCTAssertEqual(metrics.actionItemsP0, written.actionItemsP0)
        XCTAssertEqual(metrics.p0NotReported, 100)

        let dashboard = CoreDashboard(config: config, dataDir: fleet.dataDir, workbook: Workbook())
        try dashboard.writeExecutiveSummary()
        XCTAssertEqual(
            rowCells(dashboard.workbook, "Executive Summary",
                     "P0 Not Reported (FV/SIP/FW values)")?[1], "100")
        XCTAssertNil(rowCells(dashboard.workbook, "Executive Summary",
                              "P1 Not Reported (Gatekeeper values)"))
        XCTAssertEqual(
            rowCells(dashboard.workbook, "Executive Summary",
                     "P0 Action Items (FV/SIP/FW gaps)")?[1], "0")

        try dashboard.writeSecurity()
        XCTAssertEqual(rowCells(dashboard.workbook, "Security Posture", "SIP Not Reported")?[1],
                       "100")
        XCTAssertNil(rowCells(dashboard.workbook, "Security Posture", "FileVault Not Reported"))

        try dashboard.writeCompliancePosture()
        XCTAssertEqual(rowCells(dashboard.workbook, "Compliance Posture", "SIP Enabled")?[2],
                       "GREEN")
        XCTAssertNotNil(rowCells(dashboard.workbook, "Compliance Posture", "Not reported: SIP 100. "
            + "Macs whose value Jamf did not report are not counted as failing and are left out "
            + "of the shares above."))

        let outputURL = testRoot.appendingPathComponent("report.html")
        try await HtmlReport(config: config, dataDir: fleet.dataDir).generate(outputURL: outputURL)
        let html = try String(contentsOf: outputURL, encoding: .utf8)
        let tiles = try XCTUnwrap(html.range(of: "<section class=\"tiles-row\">"))
        let tilesEnd = try XCTUnwrap(html.range(
            of: "</section>", range: tiles.upperBound..<html.endIndex))
        let blocks = html[tiles.upperBound..<tilesEnd.lowerBound]
            .components(separatedBy: "<div class=\"tile ").dropFirst()
        let note = "<div class=\"tile-label\">not reported: 100</div>"
        let withNote = blocks.filter { $0.contains(note) }
        XCTAssertEqual(withNote.count, 1, "only the SIP tile")
        XCTAssertTrue(withNote.first?.contains(">SIP<") == true)
        XCTAssertTrue(withNote.first?.hasPrefix("ok") == true,
                      "graded on the one Mac that reported")
    }

    /// A fully measured fleet adds no line anywhere.
    func testAFullyMeasuredFleetAddsNoNotReportedLine() async throws {
        let report: [[String: Any]] = [
            summary(total: 3, fileVault: 3, sip: 3, firewall: 3, gatekeeper: 3),
        ] + rows(3, prefix: "OK") { row($0) }
        let fleet = try writeReport(report)
        let config = ReportConfig()
        let dashboard = CoreDashboard(config: config, dataDir: fleet.dataDir, workbook: Workbook())
        try dashboard.writeExecutiveSummary()
        try dashboard.writeSecurity()
        try dashboard.writeCompliancePosture()
        for sheet in ["Executive Summary", "Security Posture", "Compliance Posture"] {
            let labels = (dashboard.workbook.sheet(named: sheet)?.dedupedCells ?? [])
                .filter { $0.col == 0 }.map { text($0.value) }
            XCTAssertFalse(labels.contains { $0.lowercased().contains("not reported") }, sheet)
        }
        let snapshot = try SecurityPostureService.load(
            from: fleet.security, policy: .default, hardware: [:])
        XCTAssertEqual(
            SecurityPostureView.kpiTileSub(.sip, on: 3, total: 3, fleet: snapshot.fleetCounts),
            "3 of 3")
        let context = FleetInsightInput.posture(.security(snapshot))?.promptContext() ?? ""
        XCTAssertFalse(context.contains("not report"), context)
    }
}
