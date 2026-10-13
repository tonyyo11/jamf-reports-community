import XCTest
@testable import JamfReports

/// The HTML report follow-ups to #274, #275 and #276: the stale figure says how many of its
/// Macs lack the Jamf binary, Agent Health names the Macs missing each agent, and a Mobile
/// devices section exists. Every workspace and device is invented.
final class HtmlReportFollowupsTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func iso(daysAgo days: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-days * 86_400 - 3_600))
    }

    private func computer(_ name: String, managed: Bool, checkIn: Double?) -> [String: Any] {
        let stamp: Any = checkIn.map { iso(daysAgo: $0) } ?? NSNull()
        return [
            "id": name,
            "general": ["name": name, "lastCheckIn": stamp, "reportDate": stamp,
                        "lastContact": NSNull(), "remoteManagement": ["managed": managed]],
            "hardware": ["serialNumber": "SER-\(name)"],
        ]
    }

    private func workspace(
        yaml: String = "",
        snapshots: [(kind: String, rows: [[String: Any]])] = [],
        staleCount: Int? = nil
    ) throws -> HtmlReport {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        for entry in snapshots {
            try GoldenFleetWorkspace.writeSnapshot(
                kind: entry.kind, dataDir: dataDir, at: GoldenFleetClock.anchorNoon(),
                rows: entry.rows)
        }
        if let staleCount {
            let summary = DailySummary(
                date: GoldenFleetClock.daySummaryString(GoldenFleetClock.anchorNoon()),
                totalDevices: 20, fileVaultPct: 95, compliancePct: 85, staleCount: staleCount,
                osCurrentPct: 60, crowdstrikePct: nil, patchPct: 70, source: "jamf-cli",
                provenance: nil, securityScore: 80, actionItemsP0: 1, complianceIsProxy: true,
                patchPctBasis: DailySummary.deviceWeightedPatchBasis)
            try GoldenFleetWorkspace.writeJSON(
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)),
                to: root.appendingPathComponent("snapshots/summaries/summary_\(summary.date).json"))
        }
        return HtmlReport(config: try ConfigLoader.loadFromString(yaml), dataDir: dataDir)
    }

    // MARK: - #274: the stale figure and the binary-missing Macs

    private var depFleet: [[String: Any]] {
        [computer("Healthy", managed: true, checkIn: 2),
         computer("StaleOnly", managed: true, checkIn: 60),
         computer("DEP - C02AAA", managed: false, checkIn: nil),
         computer("DEP - C02BBB", managed: false, checkIn: nil)]
    }

    func testTheStaleTileAndSentenceSayHowManyLackTheBinary() throws {
        // The summary still counts all three, by decision; the table lists two apart.
        let report = try workspace(snapshots: [("computers", depFleet)], staleCount: 3)
        let inputs = report.loadInputs(for: Set(SectionID.allCases))

        let tile = report.buildAtAGlance(inputs).html
        XCTAssertTrue(tile.contains(
            "<div class=\"glance-sub\">includes 2 without the Jamf binary, listed apart</div>"),
            tile)
        XCTAssertEqual(tile.components(separatedBy: "listed apart").count - 1, 1,
                       "only the Stale tile carries the note")

        let stale = try XCTUnwrap(
            report.attentionItems(inputs, shown: [.interventionList]).first)
        XCTAssertEqual(
            stale.text,
            "3 Macs have not checked in for more than 30 days "
                + "(includes 2 without the Jamf binary, listed apart).")
        XCTAssertEqual(stale.anchor, "intervention-list")
    }

    func testNothingIsAddedWithoutBinaryMissingMacsOrWithoutTheSnapshot() throws {
        let plain = [computer("Healthy", managed: true, checkIn: 2),
                     computer("StaleOnly", managed: true, checkIn: 60)]
        for snapshots in [[(kind: "computers", rows: plain)], []] {
            let report = try workspace(snapshots: snapshots, staleCount: 2)
            let inputs = report.loadInputs(for: Set(SectionID.allCases))
            XCTAssertFalse(report.buildAtAGlance(inputs).html.contains("glance-sub"))
            XCTAssertEqual(
                report.attentionItems(inputs, shown: []).first?.text,
                "2 Macs have not checked in for more than 30 days.")
        }
    }

    func testTheSentenceKeepsTheNoteOffACountTakenFromTheSnapshot() throws {
        // No daily summary: the stale count comes from the computers snapshot, which already
        // leaves the binary-missing Macs out, so the clause would be wrong.
        let report = try workspace(snapshots: [("computers", depFleet)])
        let inputs = report.loadInputs(for: Set(SectionID.allCases))
        XCTAssertEqual(
            report.attentionItems(inputs, shown: []).first?.text,
            "1 Mac has not checked in for more than 30 days.")
    }

    // MARK: - #276: the Macs missing each agent

    private let agentYAML = """
    security_agents:
      - name: "Falcon"
        column: "Falcon - Status"
        connected_value: "Running"
    """

    private func eaRows(_ rows: [[String: Any]]) throws -> [EAResultRow] {
        try XCTUnwrap(
            EAResultRow.decodeSnapshot(JSONSerialization.data(withJSONObject: rows)).rows)
    }

    private func tableCells(_ html: String) -> [[String]] {
        let body = html.components(separatedBy: "<tbody>").dropFirst()
        return body.flatMap { chunk -> [[String]] in
            chunk.components(separatedBy: "</tr>").compactMap { row in
                let cells = row.components(separatedBy: "<td>").dropFirst()
                    .map { $0.components(separatedBy: "</td>")[0] }
                return cells.isEmpty ? nil : cells
            }
        }
    }

    func testAgentHealthNamesTheMacsWithoutTheAgentAndSaysWhenItHasOnlyAName() throws {
        let rows = try eaRows([
            ["computer_id": "1", "serial": "SA", "computer_name": "A-ok",
             "ea_name": "Falcon - Status", "value": "Running"],
            ["computer_id": "2", "serial": "SB", "computer_name": "B-stopped",
             "ea_name": "Falcon - Status", "value": "Not Running"],
            ["computer_id": "3", "computer_name": "C-empty",
             "ea_name": "Falcon - Status", "value": ""],
            ["device": "D-name", "ea_name": "Falcon - Status", "value": "Stopped"],
            ["computer_id": "5", "serial": "SE", "computer_name": "E-other",
             "ea_name": "Other EA", "value": "x"],
        ])
        let report = try workspace(yaml: agentYAML)
        let html = report.buildAgentHealth(eaRows: rows, fleet: 5).html

        let table = html.components(separatedBy: "Value seen")[1]
        XCTAssertEqual(tableCells(table), [
            ["B-stopped", "SB", "Falcon", "Not Running"],
            ["C-empty", "ID 3", "Falcon", "no value"],
            ["D-name", "name only", "Falcon", "Stopped"],
            ["E-other", "SE", "Falcon", "no value"],
        ])
        XCTAssertTrue(html.contains("4 Macs without a connected agent"), html)
        XCTAssertTrue(html.contains("marked name only carries no serial or ID"), html)
        XCTAssertFalse(table.contains("A-ok"))
    }

    /// "Not Running" holds the connected value "Running" but reads as off: the table uses
    /// `SecurityAgentCheck`, the comparison the coverage counts use, not a substring test.
    func testTheTableAndTheCoverageCountsAgreeOnWhoIsConnected() throws {
        let falcon = SecurityAgentConfig(
            name: "Falcon", column: "Falcon - Status", connectedValue: "Running")
        let rows = try eaRows((1...6).map { index in
            ["computer_id": "\(index)", "serial": "S\(index)", "computer_name": "Mac-\(index)",
             "ea_name": "Falcon - Status",
             "value": ["Running", "Not Running", "running", "", "Stopped", "RUNNING"][index - 1]]
        })
        let coverage = try XCTUnwrap(
            SecurityAgentCoverage.compute(rows: rows, agents: [falcon]).first)
        let missing = SecurityAgentCoverage.missing(rows: rows, agents: [falcon])

        XCTAssertEqual(coverage.installed, 3)
        XCTAssertEqual(missing.count, 6 - coverage.installed)
        XCTAssertEqual(missing.map(\.device), ["Mac-2", "Mac-4", "Mac-5"])
    }

    func testTheAgentTableIsCappedAndSaysHowManyMoreAreInTheWorkbook() throws {
        let rows = try eaRows((1...120).map { index in
            ["computer_id": "\(index)", "serial": "S\(index)", "computer_name": "Mac-\(index)",
             "ea_name": "Falcon - Status", "value": "Stopped"]
        })
        let html = try workspace(yaml: agentYAML).buildAgentHealth(eaRows: rows, fleet: 120).html

        XCTAssertTrue(html.contains("Show 100 of 120"), html)
        XCTAssertTrue(html.contains("20 more rows are in the workbook"), html)
        XCTAssertEqual(tableCells(html).filter { $0.count == 4 }.count, 100,
                       "the first 10 show and the rest sit behind Show all, up to the cap")
    }

    func testAnAgentNoMacReportsAddsNoRows() throws {
        let rows = try eaRows([
            ["computer_id": "1", "serial": "S1", "computer_name": "Mac-1",
             "ea_name": "Other EA", "value": "x"],
        ])
        let report = try workspace(yaml: agentYAML)
        XCTAssertEqual(report.buildAgentHealth(eaRows: rows, fleet: 1).isShown, false)
    }

    // MARK: - #275: the Mobile devices section

    private func mobile(
        _ id: String, identifier: String, model: String, os: String, managed: Bool,
        supervised: Bool, passcode: Bool? = nil, lock: Bool? = nil
    ) -> [String: Any] {
        var security: [String: Any] = [:]
        if let passcode { security["passcodeCompliant"] = passcode }
        if let lock { security["activationLockEnabled"] = lock }
        return [
            "mobileDeviceId": id, "deviceType": "iOS",
            "hardware": ["model": model, "modelIdentifier": identifier,
                         "serialNumber": "MSER\(id)"],
            "general": ["displayName": "Secret-Name-\(id)", "osVersion": os,
                        "managed": managed, "supervised": supervised],
            "security": security,
        ]
    }

    private var mobileFleet: [[String: Any]] {
        [mobile("1", identifier: "iPad13,1", model: "iPad Air", os: "17.4", managed: true,
                supervised: true, passcode: true),
         mobile("2", identifier: "iPad14,3", model: "iPad Pro", os: "17.4", managed: true,
                supervised: false, passcode: false),
         mobile("3", identifier: "iPhone16,1", model: "iPhone 15", os: "18.0", managed: true,
                supervised: true, passcode: true),
         mobile("4", identifier: "AppleTV5,3", model: "Apple TV 4K", os: "18.0", managed: false,
                supervised: false)]
    }

    private func mobileSection(_ report: HtmlReport) -> HtmlBlock {
        report.buildMobileFleet(report.loadInputs(for: [.mobileFleet]).mobile)
    }

    func testTheMobileSectionCountsFormFactorsPostureAndVersionsWithoutADeviceTable() throws {
        let report = try workspace(snapshots: [(MobileFleetService.deviceKind, mobileFleet)])
        let block = mobileSection(report)
        let html = block.html

        XCTAssertTrue(block.isShown)
        XCTAssertTrue(html.contains("Mobile devices (4)"), html)
        func card(_ name: String) -> String? {
            html.components(separatedBy: "<div class=\"count-card\">").dropFirst().first {
                $0.contains("<div class=\"count-label\">\(name)</div>")
            }
        }
        XCTAssertTrue(card("iPad")?.contains("<div class=\"count-value\">2</div>") == true)
        XCTAssertTrue(card("iPhone")?.contains("<div class=\"count-value\">1</div>") == true)
        XCTAssertTrue(card("Apple TV")?.contains("<div class=\"count-value\">1</div>") == true)
        XCTAssertTrue(card("Managed")?.contains(">3<") == true)
        XCTAssertTrue(card("Managed")?.contains("of 4") == true)
        XCTAssertTrue(card("Supervised")?.contains(">2<") == true)
        XCTAssertTrue(card("Passcode compliant")?.contains(">2<") == true)
        XCTAssertTrue(card("Passcode compliant")?.contains("of 3 reporting") == true)
        // No device carries the Activation Lock field: unknown, never 0.
        let lock = try XCTUnwrap(card("Activation Lock on"))
        XCTAssertTrue(lock.contains(">Unknown<"), lock)
        XCTAssertFalse(lock.contains(">0<"), lock)

        XCTAssertEqual(html.components(separatedBy: "cohort-bar-row\"").count - 1, 2,
                       "one CSS bar per OS version, 17.4 and 18.0")
        XCTAssertTrue(html.contains("17.4") && html.contains("18.0"))
        XCTAssertFalse(html.contains("<table"), "no per-device table")
        XCTAssertFalse(html.contains("Secret-Name") || html.contains("MSER"))
    }

    func testAListOnlySnapshotCountsDevicesAndSaysWhatItLacks() throws {
        let list: [[String: Any]] = [
            ["id": "1", "name": "n1", "model": "iPad Air", "type": "iPad"],
            ["id": "2", "name": "n2", "model": "iPhone 15", "type": "iPhone"],
        ]
        let report = try workspace(snapshots: [(MobileFleetService.deviceKind, list)])
        let html = mobileSection(report).html

        XCTAssertTrue(html.contains("Mobile devices (2)"), html)
        XCTAssertTrue(html.contains("Only the device list was collected"), html)
        XCTAssertFalse(html.contains("<div class=\"count-label\">Managed</div>"))
        XCTAssertFalse(html.contains("cohort-bar-row"))
    }

    func testTheLegacyInventoryKindStillFillsTheSection() throws {
        let report = try workspace(
            snapshots: [(MobileFleetService.legacyInventoryKind, mobileFleet)])
        XCTAssertTrue(mobileSection(report).html.contains("Mobile devices (4)"))
    }

    func testNoMobileSnapshotIsListedAsNotIncluded() throws {
        let report = try workspace()
        let block = mobileSection(report)
        XCTAssertEqual(block.omission, "No mobile device data collected")

        let html = report.buildTemplatedHTML(
            outputURL: URL(fileURLWithPath: "/tmp/unused.html"), profileName: "p",
            sections: [.mobileFleet, .auditAppendix])
        XCTAssertTrue(html.contains("Mobile devices — No mobile device data collected"), html)
        XCTAssertFalse(html.contains("id=\"grp-mobile\""))
    }

    func testARecordedFailureCauseIsNamedInTheReason() throws {
        let report = try workspace()
        let state = StateFileStore(
            directory: report.dataDir.appendingPathComponent("state", isDirectory: true))
        state.record(
            .failed(exitCode: 5), report: MobileFleetService.deviceKind, at: Date(),
            cause: FailureCause(
                kind: .missingPermission, names: ["Inventory: Devices (Read)"], hint: nil,
                exitCode: 5))

        XCTAssertEqual(
            mobileSection(report).omission,
            "No mobile device data collected: the last attempt failed "
                + "(missing permission: Inventory: Devices (Read))")
    }

    func testAnEmptySnapshotIsNotCalledUncollected() throws {
        let report = try workspace(snapshots: [(MobileFleetService.deviceKind, [])])
        XCTAssertEqual(
            mobileSection(report).omission, "the mobile device snapshot lists no devices")
    }

    func testTheSectionRendersInItsOwnGroupAndTheDataSourceIsListed() throws {
        let report = try workspace(snapshots: [(MobileFleetService.deviceKind, mobileFleet)])
        let html = report.buildTemplatedHTML(
            outputURL: URL(fileURLWithPath: "/tmp/unused.html"), profileName: "p",
            sections: [.mobileFleet, .auditAppendix])

        XCTAssertTrue(html.contains("id=\"grp-mobile\""), html)
        XCTAssertTrue(html.contains("4 devices · 2 iPad · 1 iPhone · 1 Apple TV"), html)
        XCTAssertTrue(html.contains("Mobile devices (mobile-devices-list)"), html)
    }

    func testOnlyTheTemplatesWhoseWorkbookHasMobileSheetsListTheSection() {
        let withMobile = TemplateResolver.allTemplates.filter {
            $0.htmlSections.contains(.mobileFleet)
        }.map(\.identifier)
        XCTAssertEqual(Set(withMobile), ["full-instance", "asset"])
        // School's "mobile" sheets are its device sheets, and it has no HTML report.
        for template in TemplateResolver.allTemplates
        where template.identifier != "school"
            && (template.includedSheets.contains(.mobileFleetSummary)
                || template.includedSheets.contains(.mobileInventory)) {
            XCTAssertTrue(template.htmlSections.contains(.mobileFleet), template.identifier)
        }
        XCTAssertTrue(CustomTemplate(includedSheets: [.mobileSupervisionStatus])
            .htmlSections.contains(.mobileFleet))
        XCTAssertFalse(CustomTemplate(includedSheets: [.patchCompliance])
            .htmlSections.contains(.mobileFleet))
    }
}
