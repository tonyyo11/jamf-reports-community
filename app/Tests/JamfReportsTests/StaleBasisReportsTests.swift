import XCTest
@testable import JamfReports

/// The stale rule and the contact gap in the workbook, the CSV sheets and the HTML report.
/// Every Mac is invented; ages keep an hour clear of a day boundary.
final class StaleBasisReportsTests: XCTestCase {

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

    /// Device-compliance carries the check-in day count only.
    private var compliance: [[String: Any]] {
        [complianceRow(1, days: 2), complianceRow(2, days: 25), complianceRow(3, days: 2),
         complianceRow(4, days: 20)]
    }

    private let both = "thresholds:\n  stale_basis: [check_in, inventory]\n"

    private func dashboard(
        _ yaml: String, computers: [[String: Any]]? = nil, compliance: [[String: Any]]? = nil
    ) throws -> CoreDashboard {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let anchor = GoldenFleetClock.anchorNoon()
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "device-compliance", dataDir: dataDir, at: anchor,
            rows: compliance ?? self.compliance)
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

    // MARK: - Workbook sheets that count stale Macs

    func testActiveDevicesCountsTheCheckInAloneOnTheDefaultBasis() throws {
        let dash = try dashboard("", computers: computers)
        try dash.writeActiveDevices()
        XCTAssertEqual(try row(dash, "Active Devices", "Stale Devices")[1], "0",
                       "no check-in is more than 30 days old; M3's inventory is not counted")
        XCTAssertEqual(try subtitle(dash, "Active Devices", prefix: "Stale threshold")?
            .hasPrefix("Stale threshold: 30 days |"), true)
    }

    func testActiveDevicesCountsTheInventoryDateWhenTheBasisListsIt() throws {
        let dash = try dashboard(both, computers: computers)
        try dash.writeActiveDevices()
        XCTAssertEqual(try row(dash, "Active Devices", "Stale Devices")[1], "1",
                       "M3: checked in, but inventoried 40 days ago")
        XCTAssertEqual(try row(dash, "Active Devices", "Active (non-stale)")[1], "3")
    }

    func testTheSubtitleNamesTheCountedDates() throws {
        let dash = try dashboard(
            "thresholds:\n  stale_basis: [check_in, inventory]\n  stale_device_days: 20\n",
            computers: computers)
        try dash.writeActiveDevices()
        // More than 20 days: M2 (check-in 25) and M3 (inventory 40); M4 at 20 is not.
        XCTAssertEqual(try row(dash, "Active Devices", "Stale Devices")[1], "2")
        let line = try subtitle(dash, "Active Devices", prefix: "Stale threshold")
        XCTAssertTrue(line?.contains("20 days since check-in or inventory update") == true,
                      line ?? "no subtitle")
    }

    func testThePatchSummaryActiveWindowFollowsTheBasis() throws {
        let dash = try dashboard(
            "thresholds:\n  stale_basis: [check_in, inventory]\n  stale_device_days: 20\n",
            computers: computers)
        try GoldenFleetWorkspace.writePatchStatus(
            dataDir: dash.dataDir, at: GoldenFleetClock.anchorNoon(), rows: [
                GoldenFleetWorkspace.patchRow(id: "1", title: "Chrome", onLatest: 8, total: 10),
            ])
        try dash.writePatchSummaryDashboard()
        XCTAssertEqual(try row(dash, "Patch Summary Dashboard", "Inactive Devices")[1], "2")
        XCTAssertEqual(try row(dash, "Patch Summary Dashboard", "Active Devices")[1], "2")
    }

    func testTheExecutiveSummaryTiersBucketByStaleAge() throws {
        let rows = [complianceRow(1, days: 2), complianceRow(2, days: 2), complianceRow(3, days: 2)]
        let macs = [
            computer(1, checkIn: 2, inventory: 2, contact: 1),
            computer(2, checkIn: 2, inventory: 50, contact: 1),
            computer(3, checkIn: 2, inventory: 200, contact: 1),
        ]
        let plain = try dashboard("", computers: macs, compliance: rows)
        let byDefault = CoreDashboard.executiveMetrics(config: plain.config, dataDir: plain.dataDir)
        XCTAssertEqual(byDefault.recentCount, 3, "every check-in is 2 days old")
        let widened = try dashboard(both, computers: macs, compliance: rows)
        let metrics = CoreDashboard.executiveMetrics(
            config: widened.config, dataDir: widened.dataDir)
        XCTAssertEqual(metrics.recentCount, 1)
        XCTAssertEqual(metrics.offlineCount, 1, "inventory 50 days old: 31 to 90")
        XCTAssertEqual(metrics.dormantCount, 1, "inventory 200 days old: past 180")
    }

    // MARK: - Check-in Health

    func testCheckInHealthOverdueCountFollowsTheBasis() throws {
        let byDefault = try dashboard("", computers: computers)
        try byDefault.writeCheckinHealth()
        XCTAssertEqual(try row(byDefault, "Check-in Health", "Overdue (>7 days)")[1], "2",
                       "M2 and M4")
        let widened = try dashboard(both, computers: computers)
        try widened.writeCheckinHealth()
        XCTAssertEqual(try row(widened, "Check-in Health", "Overdue (>7 days)")[1], "3",
                       "M3's inventory is 40 days old")
        let line = try subtitle(widened, "Check-in Health", prefix: "Threshold")
        XCTAssertTrue(line?.contains("7 days since check-in or inventory update") == true,
                      line ?? "no subtitle")
    }

    func testCheckInHealthCountsTheCheckInAloneWithoutAComputersSnapshot() throws {
        let dash = try dashboard(both, computers: nil)
        try dash.writeCheckinHealth()
        XCTAssertEqual(try row(dash, "Check-in Health", "Overdue (>7 days)")[1], "2",
                       "no snapshot: the basis falls back to the check-in")
        XCTAssertEqual(try subtitle(dash, "Check-in Health", prefix: "Threshold")?
            .hasPrefix("Threshold: 7 days since check-in or inventory update |"), true)
    }

    // MARK: - CSV sheets

    private func staleSheet(_ yaml: String, rows: [String]) throws -> Worksheet {
        var config = try ConfigLoader.loadFromString(yaml)
        var columns = config.columns ?? ColumnConfig()
        columns.computerName = "Computer Name"
        columns.serialNumber = "Serial Number"
        columns.lastCheckin = "Last Check-in"
        config.columns = columns
        let csv = (["Computer Name,Serial Number,Last Check-in,Last Inventory Update"] + rows)
            .joined(separator: "\n") + "\n"
        let book = Workbook()
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: Data(csv.utf8), workbook: book))
        dashboard.writeStaleDevices()
        return try XCTUnwrap(book.sheet(named: "Stale Devices"))
    }

    private func stamp(_ days: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date().addingTimeInterval(-days * 86_400 - 3_600))
    }

    private func staleNames(_ sheet: Worksheet) -> [String] {
        sheet.cells.filter { $0.col == 0 && $0.row >= 4 }.sorted { $0.row < $1.row }
            .compactMap { cell -> String? in
                if case .string(let s) = cell.value { return s }
                return nil
            }.filter { $0.hasPrefix("Mac-") }
    }

    private let mappedInventory = "thresholds:\n  stale_basis: [check_in, inventory]\n"
        + "columns:\n  last_inventory: Last Inventory Update\n"

    func testACSVRowIsStaleByItsInventoryDateWhenTheColumnIsMapped() throws {
        let rows = ["Mac-A,A1,\(stamp(2)),\(stamp(2))", "Mac-B,B1,\(stamp(2)),\(stamp(50))"]
        XCTAssertEqual(staleNames(try staleSheet(mappedInventory, rows: rows)), ["Mac-B"])
        XCTAssertEqual(staleNames(try staleSheet("", rows: rows)), [],
                       "the default basis ignores inventory")
    }

    func testInventoryDoesNotApplyToACSVWithoutTheMappedColumn() throws {
        let rows = ["Mac-A,A1,\(stamp(2)),\(stamp(2))", "Mac-B,B1,\(stamp(2)),\(stamp(50))"]
        XCTAssertEqual(staleNames(try staleSheet(both, rows: rows)), [],
                       "columns.last_inventory is unmapped: the rule counts the check-in alone")
    }

    func testABlankInventoryCellInAMappedColumnIsNever() throws {
        let rows = ["Mac-A,A1,\(stamp(2)),", "Mac-B,B1,\(stamp(2)),\(stamp(2))"]
        XCTAssertEqual(staleNames(try staleSheet(mappedInventory, rows: rows)), ["Mac-A"])
    }

    func testTheStaleDevicesSheetNamesTheBasisInItsAgeColumn() throws {
        let rows = ["Mac-B,B1,\(stamp(2)),\(stamp(50))", "Mac-C,C1,\(stamp(2)),"]
        let sheet = try staleSheet(mappedInventory, rows: rows)
        let strings = sheet.cells.compactMap { cell -> String? in
            if case .string(let s) = cell.value { return s }
            return nil
        }
        XCTAssertTrue(strings.contains("Days Since Check-in or Inventory Update"))
        let ages = sheet.cells.filter { $0.col == 4 && $0.row >= 4 }.sorted { $0.row < $1.row }
            .map { text($0.value) }
        XCTAssertEqual(ages, ["never", "50"], "never inventoried first, then 50 days")
        let plain = try staleSheet("", rows: ["Mac-D,D1,\(stamp(45)),"])
        XCTAssertTrue(plain.cells.contains {
            if case .string("Days Since Check-in") = $0.value { return true }
            return false
        })
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

    private func name(_ item: [String: Any]) -> String? {
        (item["general"] as? [String: Any])?["name"] as? String
    }

    func testTheInterventionListFollowsTheBasisAndNamesIt() throws {
        let widened = try htmlReport(both, computers: computers)
        let stale = widened.staleComputers(computers)
        XCTAssertEqual(stale.map { name($0.item) }, ["Mac-3"], "M3: inventory 40 days old")
        XCTAssertEqual(stale.map(\.age), [.days(40)])
        let block = widened.buildInterventionList(computersInventory: computers)
        XCTAssertTrue(block.html.contains(
            "Macs with no check-in or inventory update for more than 30 days (1)"), block.html)
        XCTAssertTrue(block.html.contains("Days Since Check-in or Inventory Update"))

        let plain = try htmlReport("", computers: computers)
        XCTAssertTrue(plain.staleComputers(computers).isEmpty)
        XCTAssertEqual(plain.buildInterventionList(computersInventory: computers).omission,
                       "no Mac has gone more than 30 days without a check-in")
    }

    func testAMacWithNoInventoryDateIsOldestInTheList() throws {
        let macs = [computer(1, checkIn: 2, inventory: nil, contact: 1),
                    computer(2, checkIn: 2, inventory: 200, contact: 1)]
        let report = try htmlReport(both, computers: macs)
        let stale = report.staleComputers(macs)
        XCTAssertEqual(stale.map { name($0.item) }, ["Mac-1", "Mac-2"])
        XCTAssertEqual(stale.map(\.age), [.never, .days(200)])
        let html = report.buildInterventionList(computersInventory: macs).html
        XCTAssertTrue(html.contains("never"))
    }

    func testTheDefaultHTMLWordingIsUnchanged() {
        XCTAssertEqual(HtmlReport.staleSentence(1, rule: StaleRule(days: 30)),
                       "1 Mac has not checked in for more than 30 days.")
        XCTAssertEqual(HtmlReport.staleSentence(4, rule: StaleRule(days: 21)),
                       "4 Macs have not checked in for more than 21 days.")
        XCTAssertEqual(HtmlReport.staleSentence(
            2, rule: StaleRule(days: 30, basis: [.checkIn, .inventory])),
            "2 Macs have gone more than 30 days without a check-in or inventory update.")
    }
}
