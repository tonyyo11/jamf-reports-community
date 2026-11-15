import XCTest
@testable import JamfReports

/// The workbook's Management Health tab. Every Mac and instance is invented.
final class ManagementHealthReportsTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// An hour clear of a day boundary.
    private func iso(days: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(days * 86_400 + 3_600))
    }

    private func day(_ offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        return CoreDashboard.dayText(date)
    }

    private func mac(
        _ id: Int, name: String? = nil, profile: Int? = nil, approved: Bool? = nil
    ) -> [String: Any] {
        var general: [String: Any] = [
            "name": name ?? "Mac-\(id)", "managed": true, "lastCheckIn": iso(days: -1),
            "reportDate": iso(days: -1), "remoteManagement": ["managed": true],
        ]
        if let profile { general["mdmProfileExpiration"] = iso(days: Double(profile)) }
        if let approved { general["userApprovedMdm"] = approved }
        return ["id": String(id), "general": general,
                "hardware": ["serialNumber": "SER\(id)"],
                "operatingSystem": ["version": "26.0"], "security": ["recoveryLockEnabled": id == 1]]
    }

    private var fleet: [[String: Any]] {
        [mac(1, profile: -5), mac(2, profile: 10, approved: false), mac(3), mac(4, approved: true)]
    }

    private func dashboard(
        computers: [[String: Any]]?, instances: [[String: Any]]? = nil
    ) throws -> CoreDashboard {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let anchor = GoldenFleetClock.anchorNoon()
        if let computers {
            try GoldenFleetWorkspace.writeSnapshot(
                kind: "computers", dataDir: dataDir, at: anchor, rows: computers)
        }
        if let instances {
            try GoldenFleetWorkspace.writeSnapshot(
                kind: "device-enrollment-instances", dataDir: dataDir, at: anchor,
                rows: instances)
        }
        return CoreDashboard(
            config: try ConfigLoader.loadFromString(""), dataDir: dataDir, workbook: Workbook())
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

    /// Each row of the sheet as column to text.
    private func rows(_ dash: CoreDashboard) throws -> [[Int: String]] {
        let cells = try XCTUnwrap(
            dash.workbook.sheet(named: "Management Health")?.dedupedCells, "no sheet")
        return Dictionary(grouping: cells, by: \.row).sorted { $0.key < $1.key }
            .map { Dictionary(uniqueKeysWithValues: $0.value.map { ($0.col, text($0.value)) }) }
    }

    private func row(_ all: [[Int: String]], _ label: String) throws -> [Int: String] {
        try XCTUnwrap(all.first { $0[0] == label }, "no row \(label)")
    }

    // MARK: - Registration

    func testTheSheetIsRegisteredAfterCheckinHealthAndInTheTemplates() throws {
        XCTAssertEqual(SheetID.managementHealth.rawValue, "Management Health")
        let names = try dashboard(computers: nil).sheetPlan.map(\.name)
        let checkin = try XCTUnwrap(names.firstIndex(of: "Check-in Health"))
        XCTAssertEqual(names[checkin + 1], "Management Health")
        XCTAssertTrue(FullInstanceTemplate().includedSheets.contains(.managementHealth))
        XCTAssertTrue(OperationalTemplate().includedSheets.contains(.managementHealth))
        XCTAssertTrue(SecurityPostureTemplate().includedSheets.contains(.managementHealth))
    }

    // MARK: - Layout

    func testSummaryCountsComeFromTheCalculatorWithTheirDenominators() throws {
        let dash = try dashboard(computers: fleet)
        try dash.writeManagementHealth()
        let all = try rows(dash)
        XCTAssertEqual(all.first { $0[0] == "Finding" }, [0: "Finding", 1: "Macs", 2: "Evaluated",
                                                          3: "Kind"])
        // Two Macs report a profile date; one of them has expired.
        XCTAssertEqual(try row(all, "MDM profile expired"),
                       [0: "MDM profile expired", 1: "1", 2: "2", 3: "Gap"])
        XCTAssertEqual(try row(all, "MDM profile expiring, still checking in")[1], "1")
        // Two Macs report approval; one is not approved.
        XCTAssertEqual(try row(all, "MDM not user-approved"),
                       [0: "MDM not user-approved", 1: "1", 2: "2", 3: "Gap"])
        // A finding no Mac reports has no row, never 0 of 0.
        XCTAssertNil(all.first { $0[0] == "Not supervised" })
    }

    func testTogglesShowOnOffAndNotReported() throws {
        let dash = try dashboard(computers: fleet)
        try dash.writeManagementHealth()
        let all = try rows(dash)
        XCTAssertEqual(try row(all, "Recovery Lock"),
                       [0: "Recovery Lock", 1: "1", 2: "3", 3: "0"])
        XCTAssertNil(all.first { $0[0] == "Lockdown Mode" })
    }

    func testValuesBlockShowsTheFiveMostCommonAndCountsTheRest() throws {
        let computers = (1...8).map { id -> [String: Any] in
            var row = mac(id)
            row["security"] = ["attestationStatus": "FAIL_\(id)"]
            return row
        }
        let dash = try dashboard(computers: computers)
        try dash.writeManagementHealth()
        let all = try rows(dash)
        let title = ManagementReport.title(.attestationProblem)
        let ofField = all.filter { $0[0] == title && $0[1] != nil }
        XCTAssertEqual(ofField.filter { $0[1]?.hasPrefix("FAIL_") == true }.count,
                       ManagementHealth.maxShownValues)
        XCTAssertEqual(ofField.last?[1], "… and 3 more values")
    }

    func testDetailListsGapsFirstWithValueAndDays() throws {
        let dash = try dashboard(computers: fleet)
        try dash.writeManagementHealth()
        let all = try rows(dash)
        let head = try XCTUnwrap(all.firstIndex { $0[0] == "Computer" })
        XCTAssertEqual(all[head], [0: "Computer", 1: "Serial", 2: "Finding", 3: "Value",
                                   4: "Days"])
        let detail = Array(all[(head + 1)...])
        XCTAssertEqual(detail.map { $0[2] ?? "" }, [
            "MDM profile expired", "MDM not user-approved", "MDM profile expiring, still checking in",
        ])
        XCTAssertEqual(detail[0], [0: "Mac-1", 1: "SER1", 2: "MDM profile expired",
                                   3: day(-5), 4: "-5"])
        XCTAssertEqual(detail[1][3], "No")
        XCTAssertEqual(detail[2][4], "10")
    }

    func testANameThatStartsLikeAFormulaIsEscaped() throws {
        let dash = try dashboard(computers: [mac(1, name: "=cmd|calc", profile: -5)])
        try dash.writeManagementHealth()
        let cells = try XCTUnwrap(dash.workbook.sheet(named: "Management Health")?.dedupedCells)
        XCTAssertFalse(cells.contains { text($0.value).hasPrefix("=") })
        XCTAssertTrue(cells.contains { text($0.value).contains("=cmd|calc") })
    }

    // MARK: - Enrollment instances

    func testInstancesAreNotCollectedUnreadableOrListed() throws {
        let none = try dashboard(computers: fleet)
        try none.writeManagementHealth()
        XCTAssertTrue(try rows(none).contains { $0[0] == "Enrollment instances not collected." })

        let listed = try dashboard(
            computers: fleet,
            instances: [["name": "Placeholder Instance", "tokenExpirationDate": day(10)],
                        ["name": "Other Instance", "tokenExpirationDate": day(-3)]])
        try listed.writeManagementHealth()
        let all = try rows(listed)
        XCTAssertEqual(try row(all, "Placeholder Instance"),
                       [0: "Placeholder Instance", 1: day(10), 2: "10", 3: "Expiring"])
        XCTAssertEqual(try row(all, "Other Instance")[3], "Expired")
        XCTAssertEqual(try row(all, "Other Instance")[2], "-3")
    }

    // MARK: - Skipped

    func testNoComputersSnapshotWritesNoSheet() throws {
        let dash = try dashboard(computers: nil)
        XCTAssertThrowsError(try dash.writeManagementHealth())
        XCTAssertNil(dash.workbook.sheet(named: "Management Health"))
    }

    /// Rows that carry none of the fields judge nothing, which is not "no gaps".
    private var bareFleet: [[String: Any]] {
        [1, 2].map { id in
            ["id": String(id),
             "general": ["name": "Mac-\(id)", "managed": true, "lastCheckIn": iso(days: -1),
                         "reportDate": iso(days: -1), "remoteManagement": ["managed": true]],
             "hardware": ["serialNumber": "SER\(id)"], "operatingSystem": ["version": "26.0"]]
        }
    }

    func testRowsWithNoManagementFieldsWriteNoSheet() throws {
        let dash = try dashboard(computers: bareFleet)
        XCTAssertThrowsError(try dash.writeManagementHealth())
        XCTAssertNil(dash.workbook.sheet(named: "Management Health"))
        let health = ManagementHealth(
            records: bareFleet.map { DeviceInventoryService.recordFromComputer($0, source: "t") },
            rule: StaleRule(days: 30), now: Date())
        XCTAssertFalse(health.judgedAnything)
        XCTAssertFalse(health.judgedGapsOrWarnings)
        XCTAssertNil(ManagementCard.build(health: health, tokens: .empty))
    }

    func testJudgedWithNoGapsSaysSoAndAFlagOnlyFleetDoesNot() throws {
        let clear = try dashboard(computers: [mac(1, approved: true)])
        try clear.writeManagementHealth()
        XCTAssertTrue(try rows(clear).contains { $0[0] == "No Mac has a management gap or warning." })
        // Only a neutral count was judged: no gap or warning figure, so no "none" sentence.
        var row = mac(1)
        row["general"] = (row["general"] as? [String: Any] ?? [:])
            .merging(["supervised": false]) { $1 }
        let neutral = try dashboard(computers: [row])
        try neutral.writeManagementHealth()
        let all = try rows(neutral)
        XCTAssertFalse(all.contains { $0[0] == "No Mac has a management gap or warning." })
        XCTAssertFalse(all.contains { $0[0] == "Macs with a gap or warning" })
    }

    func testASnapshotThatIsNotAListOfComputersWarnsAndSkipsTheSheet() throws {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "computers", dataDir: dataDir, at: GoldenFleetClock.anchorNoon(), rows: fleet)
        let folder = dataDir.appendingPathComponent("computers", isDirectory: true)
        for file in try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            try Data(#"{"not": "a list"}"#.utf8).write(to: file)
        }
        let lines = LockedLines()
        let dash = CoreDashboard(
            config: try ConfigLoader.loadFromString(""), dataDir: dataDir, workbook: Workbook(),
            onLine: { lines.append($0.text) })
        XCTAssertThrowsError(try dash.writeManagementHealth())
        XCTAssertNil(dash.workbook.sheet(named: "Management Health"))
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("[warn] Management Health:")
            && $0.contains("computers") }, "\(lines.all)")
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
