import XCTest
@testable import JamfReports

/// The contact gap in the workbook's Check-in Health sheet and the HTML report's Needs attention
/// list. Every Mac is invented; ages keep an hour clear of a day boundary.
final class ContactGapReportsTests: XCTestCase {

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
        _ id: Int, checkIn: Double?, inventory: Double?, contact: Double?
    ) -> [String: Any] {
        var general: [String: Any] = ["name": "Mac-\(id)"]
        if let checkIn { general["lastCheckIn"] = iso(daysAgo: checkIn) }
        if let inventory { general["reportDate"] = iso(daysAgo: inventory) }
        general["lastContact"] = contact.map { iso(daysAgo: $0) } ?? NSNull()
        return ["id": String(id), "general": general, "hardware": ["serialNumber": "SER\(id)"]]
    }

    private func complianceRow(_ id: Int, days: Int) -> [String: Any] {
        ["name": "Mac-\(id)", "serial": "SER\(id)", "managed": true, "stale": false,
         "days_since_contact": String(days)]
    }

    /// M1 is healthy. M2: the Jamf binary is silent (check-in 25 days old, contact yesterday).
    /// M3: checks in, inventory is 40 days old. M4: silent on every channel, no Last Contact.
    private var computers: [[String: Any]] {
        [
            computer(1, checkIn: 2, inventory: 2, contact: 1),
            computer(2, checkIn: 25, inventory: 25, contact: 1),
            computer(3, checkIn: 2, inventory: 40, contact: 1),
            computer(4, checkIn: 20, inventory: 20, contact: nil),
        ]
    }

    private var compliance: [[String: Any]] {
        [complianceRow(1, days: 2), complianceRow(2, days: 25), complianceRow(3, days: 2),
         complianceRow(4, days: 20)]
    }

    private let both = "thresholds:\n  stale_basis: [check_in, inventory]\n"

    private func dashboard(_ yaml: String, computers: [[String: Any]]?) throws -> CoreDashboard {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let anchor = GoldenFleetClock.anchorNoon()
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "device-compliance", dataDir: dataDir, at: anchor, rows: compliance)
        if let computers {
            try GoldenFleetWorkspace.writeSnapshot(
                kind: "computers", dataDir: dataDir, at: anchor, rows: computers)
        }
        return CoreDashboard(
            config: try ConfigLoader.loadFromString(yaml), dataDir: dataDir, workbook: Workbook())
    }

    private func text(_ value: CellValue) -> String {
        switch value {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .bool(let b): String(b)
        case .blank: ""
        }
    }

    private typealias SheetCell = (row: Int, col: Int, value: CellValue, format: CellFormat?)

    private func cells(_ dash: CoreDashboard, _ sheet: String) throws -> [SheetCell] {
        try XCTUnwrap(dash.workbook.sheet(named: sheet)?.dedupedCells, "no \(sheet)")
    }

    /// The cells of the first row whose first column reads `label`, by column.
    private func row(
        _ dash: CoreDashboard, _ sheet: String, _ label: String
    ) throws -> [Int: String] {
        let all = try cells(dash, sheet)
        let first = try XCTUnwrap(all.first { $0.col == 0 && text($0.value) == label },
                                  "\(sheet) has no \(label)")
        return Dictionary(uniqueKeysWithValues: all.filter { $0.row == first.row }
            .map { ($0.col, text($0.value)) })
    }

    private func subtitle(
        _ dash: CoreDashboard, _ sheet: String, prefix: String
    ) throws -> String? {
        try cells(dash, sheet).map { text($0.value) }.first { $0.hasPrefix(prefix) }
    }

    // MARK: - Check-in Health

    private static let detailTitles = ["Name", "Serial", "Last Contact", "Last Check-in",
                                       "Last Inventory", "Contact gap"]

    /// The detail table under the summary: one dictionary per Mac, keyed by column title.
    private func detail(_ dash: CoreDashboard) throws -> [[String: String]] {
        let all = try cells(dash, "Check-in Health")
        guard let header = all.first(where: { $0.col == 0 && text($0.value) == "Name" }) else {
            return []
        }
        var rows: [[String: String]] = []
        var next = header.row + 1
        while all.contains(where: { $0.row == next }) {
            var entry: [String: String] = [:]
            for (col, title) in Self.detailTitles.enumerated() {
                entry[title] = text(all.first { $0.row == next && $0.col == col }?.value ?? .blank)
            }
            rows.append(entry)
            next += 1
        }
        return rows
    }

    func testCheckInHealthListsTheMacsWithTheirThreeDatesAndTheGap() throws {
        let dash = try dashboard("", computers: computers)
        try dash.writeCheckinHealth()
        let all = try cells(dash, "Check-in Health")
        let header = try XCTUnwrap(all.first { $0.col == 0 && text($0.value) == "Name" })
        let titles = (0..<6).map { col in
            text(all.first { $0.row == header.row && $0.col == col }?.value ?? .blank)
        }
        XCTAssertEqual(titles, Self.detailTitles)

        let rows = try detail(dash)
        XCTAssertEqual(rows.compactMap { $0["Name"] }, ["Mac-2", "Mac-3", "Mac-4"],
                       "the gaps first, then the Mac that is only overdue; M1 is left out")
        XCTAssertEqual(rows.compactMap { $0["Contact gap"] },
                       ["Jamf binary silent", "Inventory not updating", ""])
        let silent = try XCTUnwrap(rows.first { $0["Name"] == "Mac-2" })
        XCTAssertEqual(silent["Serial"], "SER2")
        for column in ["Last Contact", "Last Check-in", "Last Inventory"] {
            XCTAssertEqual(silent[column]?.count, 10, "\(column) is a yyyy-MM-dd date")
        }
        let none = try XCTUnwrap(rows.first { $0["Name"] == "Mac-4" })
        XCTAssertEqual(none["Last Contact"], "", "no Last Contact is left blank")
    }

    func testCheckInHealthIsUnchangedWithoutAComputersSnapshot() throws {
        let dash = try dashboard("", computers: nil)
        try dash.writeCheckinHealth()
        XCTAssertTrue(try detail(dash).isEmpty, "no snapshot, no dates, no table")
        XCTAssertEqual(try row(dash, "Check-in Health", "Overdue (>7 days)")[1], "2")
        XCTAssertEqual(try subtitle(dash, "Check-in Health", prefix: "Threshold")?
            .hasPrefix("Threshold: 7 days |"), true)
    }

    // MARK: - HTML report

    private func htmlReport(_ yaml: String, computers: [[String: Any]]) throws -> HtmlReport {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "computers", dataDir: dataDir, at: GoldenFleetClock.anchorNoon(), rows: computers)
        return HtmlReport(config: try ConfigLoader.loadFromString(yaml), dataDir: dataDir)
    }

    func testTheNeedsAttentionListNamesBothGapKindsAndTheStaleCount() throws {
        let report = try htmlReport(both, computers: computers)
        let inputs = report.loadInputs(for: Set(SectionID.allCases))
        XCTAssertEqual(inputs.contactGapCounts[.binarySilent], 1)
        XCTAssertEqual(inputs.contactGapCounts[.inventoryStale], 1)
        let lines = report.attentionItems(inputs, shown: []).map(\.text)
        XCTAssertTrue(lines.contains("1 Mac has gone more than 30 days without a check-in or "
                                     + "inventory update."), "\(lines)")
        XCTAssertTrue(lines.contains("1 Mac is reached by MDM, but its Jamf binary has not "
                                     + "checked in for more than 14 days."), "\(lines)")
        XCTAssertTrue(lines.contains("1 Mac checks in, but its inventory has not updated for "
                                     + "more than 14 days."), "\(lines)")
    }

    func testTheGapSentencesAgreeInNumber() {
        XCTAssertEqual(HtmlReport.contactGapSentence(.binarySilent, count: 3, gapDays: 7),
                       "3 Macs are reached by MDM, but their Jamf binary has not checked in for "
                       + "more than 7 days.")
        XCTAssertEqual(HtmlReport.contactGapSentence(.inventoryStale, count: 3, gapDays: 7),
                       "3 Macs check in, but their inventory has not updated for more than 7 days.")
    }

    func testNoGapLineWhenNoMacShowsOne() throws {
        let macs = [computer(1, checkIn: 2, inventory: 2, contact: 1),
                    computer(4, checkIn: 20, inventory: 20, contact: nil)]
        let report = try htmlReport("", computers: macs)
        let inputs = report.loadInputs(for: Set(SectionID.allCases))
        XCTAssertTrue(inputs.contactGapCounts.isEmpty)
        XCTAssertFalse(report.attentionItems(inputs, shown: []).map(\.text)
            .contains { $0.contains("MDM") })
    }

    func testTheGapDaysSettingMovesTheCounts() throws {
        func counts(_ days: Int) throws -> [ContactGap: Int] {
            try htmlReport("thresholds:\n  contact_gap_days: \(days)\n", computers: computers)
                .contactGapCounts(computers)
        }
        // M2's check-in lags its contact by 24 days, M3's inventory by 39.
        XCTAssertEqual(try counts(14), [.binarySilent: 1, .inventoryStale: 1])
        XCTAssertEqual(try counts(30), [.inventoryStale: 1])
        XCTAssertEqual(try counts(45), [:])
    }
}
