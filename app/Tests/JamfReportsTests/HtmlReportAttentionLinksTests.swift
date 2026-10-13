import XCTest
@testable import JamfReports

/// The HTML report's "Needs attention" links (#276): the intervention list holds the Macs the
/// stale and contact-gap sentences count, and the security block lists the Macs behind the P0
/// figure. Every Mac is invented; ages keep an hour clear of a day boundary.
final class HtmlReportAttentionLinksTests: XCTestCase {

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

    private func computer(
        _ name: String, checkIn: Double, inventory: Double, contact: Double?
    ) -> [String: Any] {
        ["id": name, "general": [
            "name": name, "lastCheckIn": iso(daysAgo: checkIn),
            "reportDate": iso(daysAgo: inventory),
            "lastContact": contact.map { iso(daysAgo: $0) } ?? NSNull(),
        ], "hardware": ["serialNumber": "SER-\(name)"]]
    }

    /// Healthy; gap only (binary silent, 25 days); stale only (60 days, no Last Contact);
    /// both (50 days, contact yesterday); inventory not updating (40 days).
    private var computers: [[String: Any]] {
        [computer("Healthy", checkIn: 2, inventory: 2, contact: 1),
         computer("GapOnly", checkIn: 25, inventory: 25, contact: 1),
         computer("StaleOnly", checkIn: 60, inventory: 60, contact: nil),
         computer("Both", checkIn: 50, inventory: 50, contact: 1),
         computer("InventoryGap", checkIn: 2, inventory: 40, contact: 1)]
    }

    private func report(
        _ yaml: String = "", write: [(kind: String, rows: [[String: Any]])]
    ) throws -> HtmlReport {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        for entry in write {
            try GoldenFleetWorkspace.writeSnapshot(
                kind: entry.kind, dataDir: dataDir, at: GoldenFleetClock.anchorNoon(),
                rows: entry.rows)
        }
        return HtmlReport(config: try ConfigLoader.loadFromString(yaml), dataDir: dataDir)
    }

    /// The body rows of the first table in `html`, each as its cells.
    private func tableRows(_ html: String) throws -> [[String]] {
        let body = try XCTUnwrap(html.components(separatedBy: "<tbody>").dropFirst().first)
        return body.components(separatedBy: "</tr>").compactMap { row in
            let cells = row.components(separatedBy: "<td>").dropFirst()
                .map { $0.components(separatedBy: "</td>")[0] }
            return cells.isEmpty ? nil : cells
        }
    }

    // MARK: - Intervention list

    func testTheListHoldsStaleGapAndBothMacsOnceEach() throws {
        let report = try report(write: [("computers", computers)])
        let html = report.buildInterventionList(computersInventory: computers).html
        let rows = try tableRows(html)

        XCTAssertEqual(rows.map { $0[0] }, ["Both", "GapOnly", "InventoryGap", "StaleOnly"],
                       "gap Macs first (binary silent before inventory), then stale-only")
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0[0], $0) })
        XCTAssertEqual(byName["StaleOnly"]?[5], "—", "stale only: no gap")
        XCTAssertEqual(byName["StaleOnly"]?[4], "—", "no Last Contact")
        XCTAssertEqual(byName["GapOnly"]?[5], "Jamf binary silent")
        XCTAssertEqual(byName["GapOnly"]?[3], "25", "a gap-only Mac still shows its age")
        XCTAssertEqual(byName["GapOnly"]?[4].count, 10, "Last Contact is a yyyy-MM-dd date")
        XCTAssertEqual(byName["Both"]?[5], "Jamf binary silent")
        XCTAssertEqual(byName["Both"]?[3], "50", "stale and gap: one row with both facts")
        XCTAssertEqual(byName["InventoryGap"]?[5], "Inventory not updating")
        XCTAssertTrue(html.contains("Macs to follow up (4)"), html)
        XCTAssertTrue(
            html.contains("2 with no check-in for more than 30 days, 3 with a contact gap"), html)
    }

    /// The sentences, the group headline and the table count the same Macs.
    func testTheCountsTheSentencesStateAreTheCountsTheTableHolds() throws {
        let report = try report(write: [("computers", computers)])
        let inputs = report.loadInputs(for: Set(SectionID.allCases))
        let rows = try tableRows(
            report.buildInterventionList(computersInventory: computers).html)

        let stale = report.staleComputers(computers).count
        let gaps = inputs.contactGapCounts.values.reduce(0, +)
        XCTAssertEqual(stale, 2)
        XCTAssertEqual(gaps, 3)
        XCTAssertEqual(rows.count, stale + gaps - 1, "Both is counted by each and listed once")
        XCTAssertEqual(rows.filter { $0[5] != "—" }.count, gaps)
        XCTAssertEqual(
            report.groupSummary(.devices, shown: [], inputs: inputs),
            "2 Macs idle over 30 days · 3 with a contact gap")

        let items = report.attentionItems(inputs, shown: [.interventionList])
        let gapLines = items.filter { $0.text.contains("MDM") || $0.text.contains("inventory") }
        XCTAssertEqual(gapLines.count, 2)
        XCTAssertTrue(gapLines.allSatisfy { $0.anchor == "intervention-list" })
    }

    /// On a fleet with more stale Macs than the table shows, the gap Macs the attention lines
    /// lead to come first, so the cap cuts stale-only rows instead (prod, beta 4: 121 stale
    /// filled all 100 rows and every Reason cell read "—").
    func testMacsWithAReasonComeBeforeStaleOnlyMacs() throws {
        let report = try report(write: [("computers", computers)])
        let order = report.interventionMacs(computers).map { report.inventoryName($0.item) }
        let reasons = report.interventionMacs(computers).map(\.reason)
        XCTAssertEqual(reasons.prefix(3).filter { $0 != "—" }.count, 3, "\(order)")
        XCTAssertEqual(reasons.last, "—", "the stale-only Mac is last: \(order)")
    }

    func testAMacShowingNeitherIsNotListedAndAStaleOnlyListKeepsItsTitle() throws {
        let stale = [computer("StaleOnly", checkIn: 60, inventory: 60, contact: nil),
                     computer("Healthy", checkIn: 2, inventory: 2, contact: 1)]
        let report = try report(write: [("computers", stale)])
        let html = report.buildInterventionList(computersInventory: stale).html
        XCTAssertEqual(try tableRows(html).map { $0[0] }, ["StaleOnly"])
        XCTAssertTrue(html.contains("Macs with no check-in for more than 30 days (1)"), html)
        XCTAssertFalse(html.contains("contact gap."), "no gap, no breakdown note")
    }

    func testNoStaleAndNoGapLeavesTheListOut() throws {
        let healthy = [computer("Healthy", checkIn: 2, inventory: 2, contact: 1)]
        let block = try report(write: [("computers", healthy)])
            .buildInterventionList(computersInventory: healthy)
        XCTAssertTrue(block.html.isEmpty)
        XCTAssertEqual(block.omission, "no Mac has gone more than 30 days without a check-in")
    }

    // MARK: - P0 table

    private func device(
        _ name: String, fileVault: String = "ENCRYPTED", firewall: Bool = true
    ) -> [String: Any] {
        GoldenFleetWorkspace.securityDeviceRow(
            name: name, serial: "SER-\(name)", osVersion: "26.1", fileVault: fileVault,
            sip: "ENABLED", firewall: firewall, gatekeeper: "ENABLED")
    }

    private func securityBlock(
        _ yaml: String = "", filevaultOn: Int, firewallOn: Int, devices: [[String: Any]],
        computers: [[String: Any]] = []
    ) throws -> String {
        let rows = GoldenFleetWorkspace.securitySummaryPayload(
            total: 4, filevault: filevaultOn, sip: 4, firewall: firewallOn, gatekeeper: 4)
            + devices
        var write: [(kind: String, rows: [[String: Any]])] = [("security", rows)]
        if !computers.isEmpty { write.append(("computers", computers)) }
        let report = try report(yaml, write: write)
        let inputs = report.loadInputs(for: Set(SectionID.allCases))
        return report.buildSecurityControls(inputs).html
    }

    private var fleetDevices: [[String: Any]] {
        [device("Mac-A", fileVault: "Off", firewall: false), device("Mac-B", fileVault: "Off"),
         device("Mac-C"), device("Mac-D")]
    }

    func testTheP0TableListsEachMacWithItsFailingControls() throws {
        // FileVault off on two Macs and the firewall off on one: three gaps on two Macs.
        let html = try securityBlock(filevaultOn: 2, firewallOn: 3, devices: fleetDevices)
        XCTAssertEqual(try tableRows(html).map { $0[0] }, ["Mac-A", "Mac-B"])
        XCTAssertEqual(try tableRows(html).map { $0[2] }, ["FileVault, Firewall", "FileVault"])
        XCTAssertEqual(try tableRows(html).map { $0[1] }, ["SER-Mac-A", "SER-Mac-B"])
        XCTAssertTrue(html.contains("All 3 P0 gaps listed, on 2 Macs."), html)
    }

    func testTheP0TableSaysHowManyGapsTheRowsDoNotName() throws {
        // The summary counts three Macs with FileVault off; the rows name two of them.
        let devices = [device("Mac-A", fileVault: "Off"), device("Mac-B", fileVault: "Off"),
                       device("Mac-C"), device("Mac-D")]
        let html = try securityBlock(filevaultOn: 1, firewallOn: 4, devices: devices)
        XCTAssertTrue(html.contains("2 of 3 P0 gaps listed, on 2 Macs."), html)
        XCTAssertFalse(html.contains("All "), html)
    }

    func testTheHardwareRuleKeepsAHardwareEncryptedMacOffTheP0Table() throws {
        let computers = [
            GoldenFleetWorkspace.computerRow(
                name: "Mac-B", serial: "SER-Mac-B", appleSilicon: true,
                modelIdentifier: "Mac14,2", fileVault: "Off", sip: "ENABLED", firewall: true,
                gatekeeper: "ENABLED"),
        ]
        let html = try securityBlock(
            "security_policy:\n  filevault_off_hardware_encrypted: warning\n",
            filevaultOn: 2, firewallOn: 3, devices: fleetDevices, computers: computers)
        XCTAssertEqual(try tableRows(html).map { $0[0] }, ["Mac-A"])
        XCTAssertTrue(html.contains("All 2 P0 gaps listed, on 1 Mac."), html)
    }

    func testNoDeviceRowsAddNothingToTheSecurityBlock() throws {
        let html = try securityBlock(filevaultOn: 2, firewallOn: 3, devices: [])
        XCTAssertFalse(html.contains("<table"), html)
        XCTAssertFalse(html.contains("P0 gap"), html)
    }
}
