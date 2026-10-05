import XCTest
@testable import JamfReports

/// `thresholds.stale_basis` and `thresholds.contact_gap_days` and the column that gives a CSV
/// its inventory date: decoding, Config Doctor, the schema and the Config screen's save.
final class StaleBasisConfigTests: XCTestCase {

    private func config(_ yaml: String) throws -> ReportConfig {
        try ConfigLoader.loadFromString(yaml)
    }

    private func doctorRows(_ yaml: String) throws -> [DoctorRow] {
        ConfigDoctorService.valueRows(
            try config(yaml), raw: try ConfigLoader.rawMapping(fromYAML: yaml))
    }

    // MARK: - Decoding

    func testAbsentKeysAreTheDefaults() throws {
        let thresholds = try XCTUnwrap(
            try config("thresholds:\n  stale_device_days: 45\n").thresholds)
        XCTAssertEqual(thresholds.resolvedStaleBasis, [.checkIn])
        XCTAssertEqual(thresholds.resolvedContactGapDays, 14)
        XCTAssertEqual(thresholds.staleRule, StaleRule(days: 45, basis: [.checkIn]))
        XCTAssertEqual(ReportConfig().staleRule, StaleRule(days: 30))
        XCTAssertEqual(ReportConfig().contactGapDays, 14)
    }

    func testAListOfDatesReadsInCanonicalOrder() throws {
        let thresholds = try XCTUnwrap(try config("""
        thresholds:
          stale_basis: [contact, check_in, inventory]
          contact_gap_days: 21
        """).thresholds)
        XCTAssertEqual(thresholds.resolvedStaleBasis, [.checkIn, .inventory, .contact])
        XCTAssertEqual(thresholds.resolvedContactGapDays, 21)
    }

    func testABlockListAndASingleStringBothRead() throws {
        let block = try XCTUnwrap(try config(
            "thresholds:\n  stale_basis:\n    - check_in\n    - inventory\n").thresholds)
        XCTAssertEqual(block.resolvedStaleBasis, [.checkIn, .inventory])
        let single = try XCTUnwrap(try config("thresholds:\n  stale_basis: inventory\n").thresholds)
        XCTAssertEqual(single.resolvedStaleBasis, [.inventory], "a string is a one-item list")
    }

    func testAWordTheAppDoesNotKnowIsSkipped() throws {
        let mixed = try XCTUnwrap(try config(
            "thresholds:\n  stale_basis: [check_in, last_seen, inventory]\n").thresholds)
        XCTAssertEqual(mixed.resolvedStaleBasis, [.checkIn, .inventory])
        XCTAssertEqual(mixed.staleBasis?.skipped, ["last_seen"])
        let none = try XCTUnwrap(try config("thresholds:\n  stale_basis: [bogus]\n").thresholds)
        XCTAssertEqual(none.resolvedStaleBasis, [.checkIn], "no known word: the default")
    }

    func testAnEmptyListOrAWrongShapeIsTheDefault() throws {
        let empty = try XCTUnwrap(try config("thresholds:\n  stale_basis: []\n").thresholds)
        XCTAssertEqual(empty.resolvedStaleBasis, [.checkIn])
        XCTAssertEqual(empty.staleBasis?.words, [])
        XCTAssertEqual(empty.staleBasis?.wrongShape, false)
        let number = try XCTUnwrap(try config("thresholds:\n  stale_basis: 7\n").thresholds)
        XCTAssertEqual(number.resolvedStaleBasis, [.checkIn])
        XCTAssertEqual(number.staleBasis?.wrongShape, true)
    }

    func testAWrongValueNeverFailsTheWholeConfigDecode() throws {
        let decoded = try config("""
        thresholds:
          stale_device_days: 45
          stale_basis: 7
          contact_gap_days: abc
          cert_warning_days: 60
        """)
        let thresholds = try XCTUnwrap(decoded.thresholds)
        XCTAssertEqual(thresholds.resolvedStaleDays, 45, "the keys around it still read")
        XCTAssertEqual(thresholds.resolvedCertWarningDays, 60)
        XCTAssertEqual(thresholds.resolvedContactGapDays, 14)
    }

    func testTheContactGapIsAWholeNumberFromOneTo365() throws {
        func gap(_ typed: String) throws -> Int {
            try XCTUnwrap(try config("thresholds:\n  contact_gap_days: \(typed)\n").thresholds)
                .resolvedContactGapDays
        }
        XCTAssertEqual(try gap("1"), 1)
        XCTAssertEqual(try gap("365"), 365)
        XCTAssertEqual(try gap("0"), 14)
        XCTAssertEqual(try gap("366"), 14)
        XCTAssertEqual(try gap("-3"), 14)
        XCTAssertEqual(try gap("14.5"), 14)
        XCTAssertEqual(try gap("true"), 14)
    }

    // MARK: - Config Doctor

    func testDoctorNamesASkippedWord() throws {
        let rows = try doctorRows("thresholds:\n  stale_basis: [check_in, last_seen]\n")
        let row = try XCTUnwrap(rows.first { $0.title == "thresholds.stale_basis" })
        XCTAssertEqual(row.severity, .warn)
        XCTAssertEqual(row.detail,
                       "\"last_seen\" names no date the app counts, so the app skips it.")
        XCTAssertTrue(row.hint?.contains("check_in, inventory, contact") == true)
        let many = try doctorRows("thresholds:\n  stale_basis: [check_in, a, b]\n")
        XCTAssertEqual(many.first { $0.title == "thresholds.stale_basis" }?.detail,
                       "\"a\", \"b\" name no date the app counts, so the app skips them.")
    }

    func testDoctorSaysWhenNoWordIsKnownOrTheListIsEmpty() throws {
        let none = try doctorRows("thresholds:\n  stale_basis: [bogus]\n")
        XCTAssertEqual(none.first { $0.title == "thresholds.stale_basis" }?.detail,
                       "\"bogus\" names no date the app counts, so the app counts check_in.")
        let empty = try doctorRows("thresholds:\n  stale_basis: []\n")
        XCTAssertEqual(empty.first { $0.title == "thresholds.stale_basis" }?.detail,
                       "stale_basis is an empty list. The app counts check_in.")
        let wrong = try doctorRows("thresholds:\n  stale_basis: 7\n")
        XCTAssertEqual(wrong.first { $0.title == "thresholds.stale_basis" }?.detail,
                       "stale_basis is neither a date nor a list of dates. "
                       + "The app counts check_in.")
    }

    func testDoctorNamesAContactGapOutsideTheRange() throws {
        for typed in ["0", "400", "abc"] {
            let rows = try doctorRows("thresholds:\n  contact_gap_days: \(typed)\n")
            XCTAssertEqual(rows.first { $0.title == "thresholds.contact_gap_days" }?.detail,
                           "\"\(typed)\" is not a whole number from 1 to 365. The app uses 14.",
                           typed)
        }
    }

    func testDoctorIsSilentForValidValuesAndForAbsentKeys() throws {
        XCTAssertEqual(try doctorRows("""
        thresholds:
          stale_basis: [check_in, inventory, contact]
          contact_gap_days: 30
        """).filter { $0.title.hasPrefix("thresholds.") }, [])
        XCTAssertEqual(try doctorRows("thresholds:\n  stale_device_days: 30\n"), [])
    }

    func testDoctorSaysInventoryHasNoDateOnACSVWithoutTheColumn() throws {
        let withInventory = try config("thresholds:\n  stale_basis: [check_in, inventory]\n")
        let rows = ConfigDoctorService.csvInventoryColumnRows(
            config: withInventory, csvHeaders: ["Computer Name"], csvFamily: .computers)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.severity, .warn)
        XCTAssertTrue(rows.first?.detail.contains("columns.last_inventory is not mapped") == true)

        let mapped = try config(
            "thresholds:\n  stale_basis: [inventory]\n"
                + "columns:\n  last_inventory: Last Inventory Update\n")
        XCTAssertTrue(ConfigDoctorService.csvInventoryColumnRows(
            config: mapped, csvHeaders: ["x"], csvFamily: .computers).isEmpty)
        XCTAssertTrue(ConfigDoctorService.csvInventoryColumnRows(
            config: withInventory, csvHeaders: nil, csvFamily: nil).isEmpty, "no CSV, no row")
        XCTAssertTrue(ConfigDoctorService.csvInventoryColumnRows(
            config: withInventory, csvHeaders: ["x"], csvFamily: .mobile).isEmpty)
        XCTAssertTrue(ConfigDoctorService.csvInventoryColumnRows(
            config: try config("thresholds:\n  stale_device_days: 30\n"),
            csvHeaders: ["x"], csvFamily: .computers).isEmpty, "the default basis needs none")
    }

    // MARK: - Schema and columns

    func testTheNewKeysAreKnownToTheSchema() throws {
        let keys = try ConfigSchema.unknownKeys(in: ConfigLoader.rawMapping(fromYAML: """
        thresholds:
          stale_basis: [check_in, inventory]
          contact_gap_days: 14
        columns:
          last_inventory: Last Inventory Update
        """))
        XCTAssertEqual(keys, [])
        let typo = try ConfigSchema.unknownKeys(in: ConfigLoader.rawMapping(
            fromYAML: "thresholds:\n  stale_basiss: [check_in]\n"))
        XCTAssertEqual(typo, [UnknownKey(keyPath: "thresholds.stale_basiss",
                                         suggestion: "stale_basis")])
    }

    func testLastInventoryIsAColumnField() throws {
        let columns = try XCTUnwrap(try config(
            "columns:\n  last_inventory: Last Inventory Update\n").columns)
        XCTAssertEqual(columns.columnName(for: .lastInventory), "Last Inventory Update")
        XCTAssertEqual(ColumnField.lastInventory.configKey, "last_inventory")
        XCTAssertNil(ColumnConfig().columnName(for: .lastInventory))
    }

    // MARK: - The Config screen's save

    private func workspace() throws -> (root: URL, profile: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JamfReportsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, "stale-basis-\(UUID().uuidString.lowercased())")
    }

    private func write(_ text: String, _ ws: (root: URL, profile: String)) throws {
        let url = try ConfigService.configURL(for: ws.profile, workspaceRoot: ws.root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func saved(_ ws: (root: URL, profile: String)) throws -> String {
        try String(contentsOf: ConfigService.configURL(for: ws.profile, workspaceRoot: ws.root),
                   encoding: .utf8)
    }

    private func resave(
        _ ws: (root: URL, profile: String), _ edit: (inout ConfigState) -> Void
    ) throws -> ConfigState {
        let loaded = try ConfigService.load(profile: ws.profile, workspaceRoot: ws.root)
        var state = loaded.state
        edit(&state)
        _ = try ConfigService.save(
            profile: ws.profile, state: state, existingDocument: loaded.document,
            workspaceRoot: ws.root)
        return try ConfigService.load(profile: ws.profile, workspaceRoot: ws.root).state
    }

    func testTheScreenReadsTheBasisAndTheGapFromTheFile() throws {
        let ws = try workspace()
        try write("thresholds:\n  stale_basis: [check_in, inventory]\n  contact_gap_days: 21\n", ws)
        let state = try ConfigService.load(profile: ws.profile, workspaceRoot: ws.root).state
        XCTAssertEqual(state.staleBasis, [.checkIn, .inventory])
        XCTAssertEqual(state.contactGapDays, "21")
        XCTAssertEqual(state.staleRule, StaleRule(days: 30, basis: [.checkIn, .inventory]))
        XCTAssertEqual(state.contactGapDaysValue, 21)
        let absent = ConfigState.defaultState
        XCTAssertEqual(absent.staleBasis, [.checkIn])
        XCTAssertEqual(absent.contactGapDaysValue, 14)
    }

    func testChangingTheBasisAndTheGapWritesBothKeysAndTheyReadBack() throws {
        let ws = try workspace()
        try write("thresholds:\n  stale_device_days: 30\n", ws)
        let reloaded = try resave(ws) {
            $0.staleBasis = [.checkIn, .inventory, .contact]
            $0.contactGapDays = "30"
        }
        XCTAssertEqual(reloaded.staleBasis, [.checkIn, .inventory, .contact])
        XCTAssertEqual(reloaded.contactGapDays, "30")
        let thresholds = try XCTUnwrap(try ConfigLoader.load(
            from: ConfigService.configURL(for: ws.profile, workspaceRoot: ws.root)).thresholds)
        XCTAssertEqual(thresholds.resolvedStaleBasis, [.checkIn, .inventory, .contact])
        XCTAssertEqual(thresholds.resolvedContactGapDays, 30)
    }

    func testTheDefaultsAreNotWrittenWhenTheFileNeverHadThem() throws {
        let ws = try workspace()
        try write("thresholds:\n  stale_device_days: 30\n", ws)
        _ = try resave(ws) { $0.staleDeviceDays = "40" }
        let text = try saved(ws)
        XCTAssertFalse(text.contains("stale_basis"), text)
        XCTAssertFalse(text.contains("contact_gap_days"), text)
    }

    func testReturningToTheDefaultRemovesTheKey() throws {
        let ws = try workspace()
        try write("thresholds:\n  stale_basis: [check_in, inventory]\n  contact_gap_days: 21\n", ws)
        let reloaded = try resave(ws) {
            $0.staleBasis = [.checkIn]
            $0.contactGapDays = "14"
        }
        XCTAssertEqual(reloaded.staleBasis, [.checkIn])
        let text = try saved(ws)
        XCTAssertFalse(text.contains("stale_basis"), text)
        XCTAssertFalse(text.contains("contact_gap_days"), text)
    }

    func testAnUnchangedChoiceLeavesWhatTheFileHoldsAsTyped() throws {
        let ws = try workspace()
        try write("""
        thresholds:
          stale_basis: inventory
          contact_gap_days: 14
        """, ws)
        _ = try resave(ws) { $0.staleDeviceDays = "40" }
        let text = try saved(ws)
        XCTAssertTrue(text.contains("stale_basis: inventory"),
                      "a single word the screen reads as [inventory] stays a single word")
        XCTAssertTrue(text.contains("contact_gap_days: 14"), "an explicit default is not dropped")
    }

    func testLastInventoryIsAnOptionalColumnWrittenOnlyWhenSet() throws {
        XCTAssertTrue(ConfigState.optionalColumnKeys.contains("last_inventory"))
        XCTAssertEqual(ConfigState.defaultState.columns["last_inventory"], "")
        let ws = try workspace()
        try write("columns:\n  computer_name: Computer Name\n", ws)
        let untouched = try resave(ws) { $0.staleDeviceDays = "31" }
        XCTAssertEqual(untouched.columns["last_inventory"], "")
        XCTAssertFalse(try saved(ws).contains("last_inventory"))
        let mapped = try resave(ws) { $0.columns["last_inventory"] = "Last Inventory Update" }
        XCTAssertEqual(mapped.columns["last_inventory"], "Last Inventory Update")
    }

    func testTheScreensWrittenKeysIncludeTheNewOnes() {
        XCTAssertTrue(ConfigEditedKeys.paths.contains(["thresholds", "stale_basis"]))
        XCTAssertTrue(ConfigEditedKeys.paths.contains(["thresholds", "contact_gap_days"]))
        XCTAssertTrue(ConfigEditedKeys.paths.contains(["columns", "last_inventory"]))
    }
}
