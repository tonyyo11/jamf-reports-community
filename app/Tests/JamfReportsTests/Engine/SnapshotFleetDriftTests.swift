import XCTest
@testable import JamfReports

/// Fleet Drift from two `computers` snapshots. Every Mac is invented.
final class SnapshotFleetDriftTests: XCTestCase {

    private var roots: [URL] = []
    private let anchor = GoldenFleetClock.anchorNoon()
    private let iso = ISO8601DateFormatter()

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func at(_ dayOffset: Int, hour: Int = 12) -> Date {
        GoldenFleetClock.timestamp(dayOffset: dayOffset, hour: hour, minute: 0, relativeTo: anchor)
    }

    /// A Mac whose dates sit `daysOld` before `taken`, an hour clear of a day boundary.
    private func mac(
        _ id: Int?, serial: String? = nil, os: String = "26.0", daysOld: Double = 1,
        inventoryDaysOld: Double? = nil, taken: Date
    ) -> [String: Any] {
        func stamp(_ days: Double) -> String {
            iso.string(from: taken.addingTimeInterval(-days * 86_400 - 3_600))
        }
        var general: [String: Any] = ["name": "Mac-\(id ?? 0)-\(serial ?? "")",
                                      "lastCheckIn": stamp(daysOld),
                                      "reportDate": stamp(inventoryDaysOld ?? daysOld)]
        general["lastContact"] = NSNull()
        var item: [String: Any] = ["general": general, "operatingSystem": ["version": os]]
        if let id { item["id"] = String(id) }
        if let serial { item["hardware"] = ["serialNumber": serial] }
        return item
    }

    private func dashboard(
        _ yaml: String = "", files: [(Date, [[String: Any]])],
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) throws -> CoreDashboard {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        for (date, rows) in files {
            _ = try GoldenFleetWorkspace.writeSnapshot(
                kind: "computers", dataDir: dataDir, at: date, rows: rows)
        }
        return CoreDashboard(
            config: try ConfigLoader.loadFromString(yaml), dataDir: dataDir, workbook: Workbook(),
            onLine: onLine)
    }

    private func texts(_ dash: CoreDashboard) throws -> [String] {
        let sheet = try XCTUnwrap(dash.workbook.sheet(named: "Fleet Drift"))
        return sheet.dedupedCells.map {
            switch $0.value {
            case .string(let s): s
            case .int(let i): String(i)
            default: ""
            }
        }
    }

    /// The rows listed under `title`: everything up to the next section title.
    private func section(_ title: String, in dash: CoreDashboard) throws -> [String] {
        let sheet = try XCTUnwrap(dash.workbook.sheet(named: "Fleet Drift"))
        let cells = sheet.dedupedCells.sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        let titles: Set = ["New Enrollments", "Departed Devices", "New Stale", "Recovered Stale",
                           "OS Changed", "FileVault changes", "Patch policy failures since the last scan",
                           "Benchmark rules newly failing"]
        guard let start = cells.firstIndex(where: { $0.col == 0 && $0.row > 0 && text($0.value) == title })
        else { return [] }
        let body = cells[(start + 1)...].prefix { !($0.col == 0 && titles.contains(text($0.value))) }
        return body.filter { $0.col == 0 && text($0.value) != "Name" }.map { text($0.value) }
    }

    private func text(_ value: CellValue) -> String {
        if case .string(let s) = value { return s }
        return ""
    }

    // MARK: - Joined, left, OS change

    func testJoinedLeftAndOSChangeAreFoundByJamfID() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(1, serial: "A1", taken: old), mac(2, serial: "A2", taken: old),
                         mac(3, serial: "A3", os: "26.0", taken: old)]),
            (new, [mac(1, serial: "A1", taken: new), mac(3, serial: "A3", os: "26.1.0", taken: new),
                         mac(4, serial: "A4", taken: new)]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Enrollments", in: dash).filter { $0.hasPrefix("Mac-") },
                       ["Mac-4-A4"])
        XCTAssertEqual(try section("Departed Devices", in: dash).filter { $0.hasPrefix("Mac-") },
                       ["Mac-2-A2"])
        XCTAssertEqual(try section("OS Changed", in: dash).filter { $0.hasPrefix("Mac-") },
                       ["Mac-3-A3"])
    }

    func testOSVersionSpellingsOfOneReleaseAreNotAChange() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(1, os: "26.7", taken: old)]),
            (new, [mac(1, os: "26.7.0", taken: new)]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("OS Changed", in: dash), ["No changes"])
    }

    func testSerialJoinsAMacWhoseRecordHasNoJamfID() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(nil, serial: "A1", taken: old)]),
            (new, [mac(7, serial: "A1", taken: new)]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Enrollments", in: dash), ["No changes"])
        XCTAssertEqual(try section("Departed Devices", in: dash), ["No changes"])
    }

    func testMacWithNeitherIdentifierIsSkippedAndCounted() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(1, taken: old)]),
            (new, [mac(1, taken: new), mac(nil, taken: new)]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Enrollments", in: dash), ["No changes"])
        XCTAssertTrue(try texts(dash).contains("1 Macs with no Jamf ID or serial left out"))
    }

    func testASerialTwoRecordsHoldIsNeitherJoinedNorLeft() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(nil, serial: "DUP", taken: old), mac(nil, serial: "DUP", taken: old),
                   mac(1, serial: "A1", taken: old)]),
            (new, [mac(nil, serial: "DUP", taken: new), mac(nil, serial: "DUP", taken: new),
                   mac(1, serial: "A1", taken: new)]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Enrollments", in: dash), ["No changes"])
        XCTAssertEqual(try section("Departed Devices", in: dash), ["No changes"])
        XCTAssertTrue(try texts(dash).contains(
            "4 Macs whose Jamf ID or serial more than one record holds left out"))
    }

    // MARK: - Large change

    private func fleet(_ ids: ClosedRange<Int>, taken: Date) -> [[String: Any]] {
        ids.map { mac($0, serial: "S\($0)", taken: taken) }
    }

    private func cell(row: Int, col: Int, in dash: CoreDashboard) throws -> String {
        let sheet = try XCTUnwrap(dash.workbook.sheet(named: "Fleet Drift"))
        return sheet.dedupedCells.first { $0.row == row && $0.col == col }.map { text($0.value) }
            ?? ""
    }

    func testASixtyPercentDropKeepsTheListAndWarns() throws {
        let (old, new) = (at(-1), at(0))
        let lines = DriftLineCollector()
        let dash = try dashboard(
            files: [(old, fleet(1...100, taken: old)), (new, fleet(1...40, taken: new))],
            onLine: lines.append)
        let log = AttentionLog(profile: "p", usesAppRecord: false)
        try AttentionLog.$current.withValue(log) { try dash.writeFleetDrift() }
        XCTAssertEqual(log.changes, [.fleetDriftLargeChange: .raised(
            "Fleet Drift: 0 joined and 60 left (60% of the fleet)")])
        XCTAssertEqual(try section("Departed Devices", in: dash).count, 60)
        let warning = try cell(row: 2, col: 0, in: dash)
        XCTAssertTrue(warning.hasPrefix("Large change: 0 joined and 60 left since "), warning)
        XCTAssertTrue(warning.contains("(60% of the fleet). If this was not a planned enrollment "
            + "or retirement, check that the last collect finished; a partial collect can make "
            + "Macs look departed."), warning)
        XCTAssertEqual(lines.texts, ["[warn] Fleet Drift: \(warning)"])
    }

    func testAMassEnrollmentKeepsTheListAndWarns() throws {
        let (old, new) = (at(-1), at(0))
        let lines = DriftLineCollector()
        let dash = try dashboard(
            files: [(old, fleet(1...1_000, taken: old)), (new, fleet(1...1_300, taken: new))],
            onLine: lines.append)
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Enrollments", in: dash).count, 300)
        let warning = try cell(row: 2, col: 0, in: dash)
        XCTAssertTrue(warning.hasPrefix("Large change: 300 joined and 0 left since "), warning)
        XCTAssertTrue(warning.contains("(23% of the fleet)"), warning)
        XCTAssertEqual(lines.texts.count, 1)
    }

    func testASmallChangeDoesNotWarn() throws {
        let (old, new) = (at(-1), at(0))
        let lines = DriftLineCollector()
        let dash = try dashboard(
            files: [(old, fleet(1...100, taken: old)), (new, fleet(3...105, taken: new))],
            onLine: lines.append)
        let log = AttentionLog(profile: "p", usesAppRecord: false)
        try AttentionLog.$current.withValue(log) { try dash.writeFleetDrift() }
        XCTAssertEqual(log.changes, [.fleetDriftLargeChange: .cleared])
        XCTAssertEqual(try section("New Enrollments", in: dash).count, 5)
        XCTAssertEqual(try section("Departed Devices", in: dash).count, 2)
        XCTAssertFalse(try texts(dash).contains { $0.hasPrefix("Large change") })
        XCTAssertTrue(lines.texts.isEmpty)
    }

    func testATinyFleetGrowingDoesNotWarn() throws {
        let (old, new) = (at(-1), at(0))
        let lines = DriftLineCollector()
        let dash = try dashboard(
            files: [(old, fleet(1...1, taken: old)), (new, fleet(1...3, taken: new))],
            onLine: lines.append)
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Enrollments", in: dash).count, 2)
        XCTAssertTrue(lines.texts.isEmpty)
    }

    /// Power BI reads this tab by name and layout; a warning must not move a section.
    func testTheSheetKeepsItsNameAndColumnsWithAWarning() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(
            files: [(old, fleet(1...100, taken: old)), (new, fleet(1...10, taken: new))])
        try dash.writeFleetDrift()
        XCTAssertEqual(dash.workbook.firstSheet?.name, "Fleet Drift")
        XCTAssertEqual(try cell(row: 3, col: 0, in: dash), "New Enrollments")
        XCTAssertEqual(try (0..<4).map { try cell(row: 4, col: $0, in: dash) },
                       ["Name", "Serial", "OS", "Last Check-in"])
        let sheet = try XCTUnwrap(dash.workbook.sheet(named: "Fleet Drift"))
        let rows = Dictionary(grouping: sheet.dedupedCells, by: \.row)
        let headerRows = rows.values.map { $0.sorted { $0.col < $1.col }.map { text($0.value) } }
            .filter { $0.first == "Name" }
        XCTAssertEqual(Set(headerRows), [
            ["Name", "Serial", "OS", "Last Check-in"],
            ["Name", "Serial", "Prior Days Stale", "Current Days Stale"],
            ["Name", "Serial", "Prior OS", "Current OS"],
        ])
        let titles = sheet.dedupedCells.filter { $0.col == 0 && $0.row > 2 }.map { text($0.value) }
            .filter { ["New Enrollments", "Departed Devices", "New Stale", "Recovered Stale",
                       "OS Changed"].contains($0) }
        XCTAssertEqual(titles, ["New Enrollments", "Departed Devices", "New Stale",
                                "Recovered Stale", "OS Changed"])
    }

    // MARK: - Stale

    func testASnapshotWithoutDatesIsNotComparedForStaleness() throws {
        let (old, new) = (at(-1), at(0))
        let undated: [[String: Any]] = (1...3).map {
            ["id": String($0), "general": ["name": "Mac-\($0)-"],
             "operatingSystem": ["version": "26.0"]]
        }
        let dash = try dashboard(files: [
            (old, (1...3).map { mac($0, taken: old) }), (new, undated),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Stale", in: dash), ["Not compared"])
        XCTAssertEqual(try section("Recovered Stale", in: dash), ["Not compared"])
        XCTAssertTrue(try texts(dash).contains(
            "Not compared: a snapshot has no check-in or inventory dates"))
    }

    func testStaleTransitionsUseTheCheckInAndInventoryBasis() throws {
        let (old, new) = (at(-1), at(0))
        let yaml = "thresholds:\n  stale_device_days: 30\n  stale_basis: [check_in, inventory]\n"
        let dash = try dashboard(yaml, files: [
            // 1: inventory goes quiet. 2: recovers. 3: checks in, never inventories, stays stale.
            (old, [mac(1, daysOld: 2, inventoryDaysOld: 2, taken: old),
                         mac(2, daysOld: 2, inventoryDaysOld: 40, taken: old),
                         mac(3, daysOld: 2, inventoryDaysOld: 40, taken: old)]),
            (new, [mac(1, daysOld: 2, inventoryDaysOld: 41, taken: new),
                         mac(2, daysOld: 2, inventoryDaysOld: 2, taken: new),
                         mac(3, daysOld: 2, inventoryDaysOld: 45, taken: new)]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Stale", in: dash).filter { $0.hasPrefix("Mac-") }, ["Mac-1-"])
        XCTAssertEqual(try section("Recovered Stale", in: dash).filter { $0.hasPrefix("Mac-") },
                       ["Mac-2-"])
    }

    func testCheckInAloneIgnoresAnOldInventoryDate() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(1, daysOld: 2, inventoryDaysOld: 2, taken: old)]),
            (new, [mac(1, daysOld: 2, inventoryDaysOld: 90, taken: new)]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Stale", in: dash), ["No changes"])
    }

    // MARK: - Baseline choice

    func testBaselineIsTheNewestSnapshotOfAnEarlierDayNotAnEarlierFileOfTheSameDay() throws {
        let dash = try dashboard(files: [
            (at(-2), [mac(1, taken: at(-2)), mac(2, taken: at(-2))]),
            (at(0, hour: 6), [mac(1, taken: at(0, hour: 6)), mac(2, taken: at(0, hour: 6))]),
            (at(0, hour: 18), [mac(1, taken: at(0, hour: 18))]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("Departed Devices", in: dash).filter { $0.hasPrefix("Mac-") },
                       ["Mac-2-"], "Mac 2 left after the day-before-yesterday snapshot")
    }

    func testSyncConflictCopyIsNotASnapshot() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(1, taken: old)]),
            (new, [mac(1, taken: new)]),
            // A provider's copy of the older file, named like a stamped snapshot with a suffix.
            (at(0, hour: 20), [mac(1, taken: new), mac(9, taken: new)]),
        ])
        let root = dash.dataDir.appendingPathComponent("computers")
        let copy = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path)
            .sorted().last)
        try FileManager.default.moveItem(
            at: root.appendingPathComponent(copy),
            to: root.appendingPathComponent(copy.replacingOccurrences(of: ".json", with: " 2.json")))
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("New Enrollments", in: dash), ["No changes"])
    }

    func testALinkAtTheNewestSnapshotIsNotRead() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(1, serial: "A1", taken: old)]), (new, [mac(1, serial: "A1", taken: new)]),
        ])
        let folder = dash.dataDir.appendingPathComponent("computers")
        let newest = folder.appendingPathComponent(try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: folder.path).sorted().last))
        let elsewhere = folder.deletingLastPathComponent().appendingPathComponent("elsewhere.json")
        try FileManager.default.moveItem(at: newest, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: newest, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try dash.writeFleetDrift()) {
            XCTAssertTrue(($0 as? SheetSkippable)?.skipReason.contains("could not be read") == true,
                          "a refused link reads as unreadable, never as not collected")
        }
        XCTAssertNil(dash.workbook.sheet(named: "Fleet Drift")?.dedupedCells.first)
    }

    /// A baseline that is there but does not decode is named, not "no cached snapshot".
    func testAnUndecodableBaselineSkipsWithCouldNotBeRead() throws {
        let (old, new) = (at(-1), at(0))
        let dash = try dashboard(files: [
            (old, [mac(1, serial: "A1", taken: old)]), (new, [mac(1, serial: "A1", taken: new)]),
        ])
        let folder = dash.dataDir.appendingPathComponent("computers")
        let oldest = folder.appendingPathComponent(try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: folder.path).sorted().first))
        try Data("{bad".utf8).write(to: oldest)
        XCTAssertThrowsError(try dash.writeFleetDrift()) {
            let reason = ($0 as? SheetSkippable)?.skipReason ?? ""
            XCTAssertTrue(reason.contains("could not be read (it did not decode)"), reason)
            XCTAssertFalse(reason.contains("No cached jamf-cli snapshot"))
        }
    }

    func testNoEarlierDaySnapshotSkipsTheSheet() throws {
        let dash = try dashboard(files: [
            (at(0, hour: 6), [mac(1, taken: at(0, hour: 6))]),
            (at(0, hour: 18), [mac(1, taken: at(0, hour: 18))]),
        ])
        XCTAssertThrowsError(try dash.writeFleetDrift()) { XCTAssertTrue($0 is SheetSkippable) }
        XCTAssertNil(dash.workbook.sheet(named: "Fleet Drift"))
    }

    func testSheetIsPlannedAndTemplatesListIt() throws {
        let dash = CoreDashboard(config: try ConfigLoader.loadFromString(""), dataDir: URL(fileURLWithPath: "/nonexistent"),
                                 workbook: Workbook())
        XCTAssertTrue(dash.sheetPlan.map(\.name).contains(SheetID.fleetDrift.rawValue))
        for template: any ReportTemplate in [FullInstanceTemplate(), OperationalTemplate(), AssetTemplate()] {
            XCTAssertTrue(template.includedSheets.contains(.fleetDrift))
        }
    }

    // MARK: - FileVault changes (wave B2)

    private func fv(_ id: Int, _ value: String?, hardware: Bool? = nil) -> ComputerDates {
        ComputerDates(jamfID: "\(id)", name: "Mac-\(id)", fileVault: value,
                      hardwareEncrypted: hardware)
    }

    func testFileVaultTransitionTable() {
        let policy = SecurityControlPolicy()
        func change(_ was: String?, _ now: String?) -> SnapshotFleetDrift.FileVaultChange? {
            SnapshotFleetDrift.fileVaultChange(from: fv(1, was), to: fv(1, now), policy: policy)
        }
        XCTAssertEqual(change("ENCRYPTED", "UNENCRYPTED"), .turnedOff)
        XCTAssertEqual(change("true", "false"), .turnedOff)
        XCTAssertNil(change("UNENCRYPTED", "ENCRYPTED"), "a gap closing is not a B2 change")
        XCTAssertNil(change("NOT_COLLECTED", "UNENCRYPTED"), "unknown to gap opens no change")
        XCTAssertEqual(change("ENCRYPTED", nil), .stoppedReporting)
        XCTAssertEqual(change("UNENCRYPTED", nil), .stoppedReporting)
        XCTAssertNil(change("UNENCRYPTED", "ENCRYPTING"), "a value present but unreadable")
        XCTAssertNil(change("ENCRYPTED", "RESTART_NEEDED"))
        XCTAssertNil(change(nil, nil))
    }

    func testFileVaultIgnoreAndHardwareRule() {
        let ignored = SecurityControlPolicy(fileVault: .ignore)
        XCTAssertNil(SnapshotFleetDrift.fileVaultChange(
            from: fv(1, "ENCRYPTED"), to: fv(1, "UNENCRYPTED"), policy: ignored))
        XCTAssertNil(SnapshotFleetDrift.fileVaultChange(
            from: fv(1, "ENCRYPTED"), to: fv(1, nil), policy: ignored))
        // Off on a hardware-encrypted Mac at warning is not a gap, so not turned off.
        let hardware = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning)
        XCTAssertNil(SnapshotFleetDrift.fileVaultChange(
            from: fv(1, "ENCRYPTED", hardware: true), to: fv(1, "UNENCRYPTED", hardware: true),
            policy: hardware))
        // A per-Mac ignore on either side is no change.
        let hardwareIgnored = SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore)
        XCTAssertNil(SnapshotFleetDrift.fileVaultChange(
            from: fv(1, "UNENCRYPTED", hardware: true), to: fv(1, nil, hardware: true),
            policy: hardwareIgnored))
    }

    func testFileVaultUnderOnValues() {
        let policy = SecurityControlPolicy(
            onValues: [.fileVault: ["Pass"]], offValues: [.fileVault: ["Fail"]])
        XCTAssertEqual(SnapshotFleetDrift.fileVaultChange(
            from: fv(1, "Pass"), to: fv(1, "Fail"), policy: policy), .turnedOff)
    }

    func testFileVaultListsCoverMatchedMacsOnly() {
        let taken = at(0)
        let prior = ComputerSnapshot(rows: [fv(1, "ENCRYPTED"), fv(2, "ENCRYPTED"),
                                            fv(3, "ENCRYPTED")])
        let current = ComputerSnapshot(rows: [fv(1, "UNENCRYPTED"), fv(2, nil),
                                              fv(4, "UNENCRYPTED")])
        let drift = SnapshotFleetDrift(
            current: current, currentAt: taken, prior: prior, priorAt: at(-1),
            rule: StaleRule(days: 30), policy: SecurityControlPolicy())
        XCTAssertEqual(drift.fileVaultOff?.map(\.current.jamfID), ["1"])
        XCTAssertEqual(drift.fileVaultOff?.first?.prior.fileVault, "ENCRYPTED")
        XCTAssertEqual(drift.fileVaultStoppedReporting?.map(\.current.jamfID), ["2"])
    }

    func testFileVaultListsNilWhenOneSnapshotHasNoFileVault() {
        let drift = SnapshotFleetDrift(
            current: [fv(1, nil)], currentAt: at(0),
            prior: [fv(1, "ENCRYPTED")], priorAt: at(-1), rule: StaleRule(days: 30))
        XCTAssertNil(drift.fileVaultOff)
        XCTAssertNil(drift.fileVaultStoppedReporting)
    }

    func testBaselineIgnoresSameDayAndFutureFiles() throws {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        for date in [at(-2), at(-1), at(0, hour: 8), at(1)] {
            _ = try GoldenFleetWorkspace.writeSnapshot(
                kind: "computers", dataDir: dataDir, at: date, rows: [])
        }
        let baseline = SnapshotFleetDrift.baseline(dataDir: dataDir, before: at(0))
        XCTAssertEqual(baseline?.date, at(-1))
        XCTAssertNil(SnapshotFleetDrift.baseline(dataDir: dataDir, before: at(-2)))
    }

    /// jamf-cli's `fileVault2Enabled` Bool prints as Jamf's words, as Device Security State does.
    func testFileVaultSectionPrintsBoolsAsWords() throws {
        func withEnabled(_ item: [String: Any], _ on: Bool) -> [String: Any] {
            var item = item
            item["diskEncryption"] = ["fileVault2Enabled": on]
            return item
        }
        let dash = try dashboard(files: [
            (at(-1), [withEnabled(mac(1, taken: at(-1)), true)]),
            (at(0), [withEnabled(mac(1, taken: at(0)), false)]),
        ])
        try dash.writeFleetDrift()
        let all = try texts(dash)
        XCTAssertTrue(all.contains("ENCRYPTED") && all.contains("UNENCRYPTED"), "\(all)")
        XCTAssertFalse(all.contains("true") || all.contains("false"))
    }

    func testFileVaultSectionRows() throws {
        func withFileVault(_ item: [String: Any], _ value: String) -> [String: Any] {
            var item = item
            item["diskEncryption"] = ["bootPartitionEncryptionDetails":
                                        ["partitionFileVault2State": value]]
            return item
        }
        let dash = try dashboard(files: [
            (at(-1), [withFileVault(mac(1, taken: at(-1)), "ENCRYPTED"),
                      withFileVault(mac(2, taken: at(-1)), "ENCRYPTED")]),
            (at(0), [withFileVault(mac(1, taken: at(0)), "UNENCRYPTED"),
                     withFileVault(mac(2, taken: at(0)), "ENCRYPTED")]),
        ])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("FileVault changes", in: dash), ["Computer", "Mac-1-"])
        XCTAssertTrue(try texts(dash).contains("UNENCRYPTED"))
        XCTAssertFalse(try texts(dash).contains("Benchmark rules newly failing"),
                       "absent with no compliance-rules files")
    }

    func testFileVaultSectionNotComparedWithoutFileVault() throws {
        let dash = try dashboard(files: [(at(-1), [mac(1, taken: at(-1))]),
                                         (at(0), [mac(1, taken: at(0))])])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("FileVault changes", in: dash),
                       ["Computer", "Not compared (no FileVault data in one snapshot)"])
    }

    func testBenchmarkSectionWithOneRulesDay() throws {
        let dash = try dashboard(files: [(at(-1), [mac(1, taken: at(-1))]),
                                         (at(0), [mac(1, taken: at(0))])])
        _ = try GoldenFleetWorkspace.writeSnapshot(
            kind: "compliance-rules", dataDir: dash.dataDir, at: at(0),
            rows: [["benchmark": "CIS", "ruleId": "r1", "rule": "Rule 1", "failed": 2]])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("Benchmark rules newly failing", in: dash),
                       ["Benchmark", "Not compared (one compliance-rules day)"])
    }

    /// A rules file that is there but does not decode is not "one day".
    func testBenchmarkSectionWithAnUnreadableRulesFile() throws {
        let dash = try dashboard(files: [(at(-1), [mac(1, taken: at(-1))]),
                                         (at(0), [mac(1, taken: at(0))])])
        let old = try GoldenFleetWorkspace.writeSnapshot(
            kind: "compliance-rules", dataDir: dash.dataDir, at: at(-1), rows: [])
        _ = try GoldenFleetWorkspace.writeSnapshot(
            kind: "compliance-rules", dataDir: dash.dataDir, at: at(0),
            rows: [["benchmark": "CIS", "ruleId": "r1", "rule": "Rule 1", "failed": 2]])
        try Data("{bad".utf8).write(to: old)
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("Benchmark rules newly failing", in: dash), [
            "Benchmark",
            "Not compared (a compliance-rules file could not be read: it did not decode)"])
    }

    func testBenchmarkSectionListsNewlyFailingRules() throws {
        let dash = try dashboard(files: [(at(-1), [mac(1, taken: at(-1))]),
                                         (at(0), [mac(1, taken: at(0))])])
        _ = try GoldenFleetWorkspace.writeSnapshot(
            kind: "compliance-rules", dataDir: dash.dataDir, at: at(-1),
            rows: [["benchmark": "CIS", "ruleId": "r1", "rule": "Rule 1", "failed": 0],
                   ["benchmark": "CIS", "ruleId": "r2", "rule": "Rule 2", "failed": 0]])
        _ = try GoldenFleetWorkspace.writeSnapshot(
            kind: "compliance-rules", dataDir: dash.dataDir, at: at(0),
            rows: [["benchmark": "CIS", "ruleId": "r1", "rule": "Rule 1", "failed": 3],
                   ["benchmark": "CIS", "ruleId": "r2", "rule": "Rule 2", "failed": 0],
                   ["benchmark": "CIS", "ruleId": "r3", "rule": "Rule 3", "failed": 1]])
        try dash.writeFleetDrift()
        XCTAssertEqual(try section("Benchmark rules newly failing", in: dash),
                       ["Benchmark", "CIS"])
        XCTAssertTrue(try texts(dash).contains("1 rules not compared"))
    }

    // MARK: - Patch policy failures (wave B2b)

    private func scan(_ rows: [[String: Any]], at date: Date, in dash: CoreDashboard) throws {
        _ = try GoldenFleetWorkspace.writeSnapshot(
            kind: "patch-device-failures", dataDir: dash.dataDir, at: date, rows: rows)
    }

    private func failure(_ device: String, _ policy: String) -> [String: Any] {
        ["device": "Mac-\(device)", "device_id": device, "policy": "Policy \(policy)",
         "policy_id": policy, "attempt": "2"]
    }

    func testPatchSectionRows() throws {
        let dash = try dashboard(files: [(at(-7), [mac(1, taken: at(-7)), mac(2, taken: at(-7))]),
                                         (at(0), [mac(1, taken: at(0)), mac(2, taken: at(0))])])
        try scan([failure("1", "5"), failure("99", "5"), ["device_id": "", "policy_id": "5"]],
                 at: at(-7), in: dash)
        try scan([failure("2", "5")], at: at(0), in: dash)
        try dash.writeFleetDrift()
        let cells = try texts(dash)
        XCTAssertEqual(try section("Patch policy failures since the last scan", in: dash),
                       ["Computer", "Mac-2", "Mac-1"])
        XCTAssertTrue(cells.contains("Started failing"))
        XCTAssertTrue(cells.contains("No longer listed as failed"))
        XCTAssertTrue(cells.contains(
            "1 rows with no Jamf ID or policy ID left out; 1 Macs not in the computers snapshot"))
    }

    func testPatchSectionNotComparedCases() throws {
        let one = try dashboard(files: [(at(-1), [mac(1, taken: at(-1))]),
                                        (at(0), [mac(1, taken: at(0))])])
        try scan([], at: at(0), in: one)
        try one.writeFleetDrift()
        XCTAssertEqual(try section("Patch policy failures since the last scan", in: one),
                       ["Computer", "Not compared (one scan)"])

        let bad = try dashboard(files: [(at(-1), [mac(1, taken: at(-1))]),
                                        (at(0), [mac(1, taken: at(0))])])
        try scan([], at: at(-1), in: bad)
        try scan([], at: at(0), in: bad)
        let badFile = try XCTUnwrap(TrendStore.datedSnapshots(
            of: "patch-device-failures", in: bad.dataDir).first?.url)
        try Data("{bad".utf8).write(to: badFile)
        try bad.writeFleetDrift()
        XCTAssertEqual(try section("Patch policy failures since the last scan", in: bad),
                       ["Computer", "Not compared (a scan could not be read: it did not decode)"])

        // Both scans predate every computers file, so no Mac list is readable for them.
        let noMacs = try dashboard(files: [(at(-1), [mac(1, taken: at(-1))]),
                                           (at(0), [mac(1, taken: at(0))])])
        try scan([], at: at(-9), in: noMacs)
        try scan([], at: at(-8), in: noMacs)
        try noMacs.writeFleetDrift()
        XCTAssertEqual(try section("Patch policy failures since the last scan", in: noMacs),
                       ["Computer", "Not compared (no computers snapshot)"])

        let none = try dashboard(files: [(at(-1), [mac(1, taken: at(-1))]),
                                         (at(0), [mac(1, taken: at(0))])])
        try none.writeFleetDrift()
        XCTAssertFalse(try texts(none).contains("Patch policy failures since the last scan"))
    }
}

private final class DriftLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in self.lock.lock(); defer { self.lock.unlock() }; self.lines.append(line.text) }
    }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
