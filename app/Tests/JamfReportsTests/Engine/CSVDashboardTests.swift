import Foundation
import XCTest
@testable import JamfReports

/// Tests for CSVDashboard — focuses on the custom-EA column-not-found warning path.
final class CSVDashboardTests: XCTestCase {

    // MARK: - Helpers

    /// Minimal CSV with a "Computer Name" and "Serial Number" column and one EA column.
    private func makeCSVData(eaColumnName: String, includeEAColumn: Bool) -> Data {
        var header = "Computer Name,Serial Number"
        if includeEAColumn { header += ",\(eaColumnName)" }
        let row1 = includeEAColumn ? "Mac-001,ABC123,Encrypted" : "Mac-001,ABC123"
        let row2 = includeEAColumn ? "Mac-002,DEF456,Not Encrypted" : "Mac-002,DEF456"
        return Data("\(header)\n\(row1)\n\(row2)".utf8)
    }

    private func makeConfig(eaName: String, eaColumn: String) -> ReportConfig {
        var config = ReportConfig()
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        cols.serialNumber = "Serial Number"
        config.columns = cols
        config.customEas = [
            CustomEAConfig(
                name: eaName,
                column: eaColumn,
                type: .boolean,
                trueValue: "Encrypted"
            ),
        ]
        return config
    }

    // MARK: - missingEAColumns property

    func testMissingEAColumnsIsEmptyWhenColumnPresent() throws {
        let eaColumn = "FileVault 2 - Status"
        let csvData = makeCSVData(eaColumnName: eaColumn, includeEAColumn: true)
        let wb = Workbook()
        let config = makeConfig(eaName: "FileVault Status", eaColumn: eaColumn)
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: csvData, workbook: wb)
        )
        XCTAssertTrue(dashboard.missingEAColumns.isEmpty,
                      "No missing columns when the EA column exists in the CSV header.")
    }

    func testMissingEAColumnsContainsNameWhenColumnAbsent() throws {
        let csvData = makeCSVData(eaColumnName: "FileVault 2 - Status", includeEAColumn: false)
        let wb = Workbook()
        let config = makeConfig(eaName: "FileVault Status", eaColumn: "FileVault 2 - Status")
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: csvData, workbook: wb)
        )
        XCTAssertEqual(dashboard.missingEAColumns, ["FileVault Status"])
    }

    func testMissingEAColumnsMultipleEAs() throws {
        let csvData = Data("Computer Name,Serial Number\nMac-001,ABC123".utf8)
        let wb = Workbook()
        var config = ReportConfig()
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        cols.serialNumber = "Serial Number"
        config.columns = cols
        config.customEas = [
            CustomEAConfig(name: "EA One", column: "Missing Col 1", type: .boolean),
            CustomEAConfig(name: "EA Two", column: "Missing Col 2", type: .text),
            CustomEAConfig(name: "EA Three", column: "Missing Col 1", type: .version),
        ]
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: csvData, workbook: wb)
        )
        XCTAssertEqual(Set(dashboard.missingEAColumns), ["EA One", "EA Two", "EA Three"])
    }

    // MARK: - Family detection

    func testCSVFamilyDetectedComputers() throws {
        let csvText = "Computer Name,JSS Computer ID,Operating System Version,Last Check-in," +
            "Gatekeeper,System Integrity Protection,FileVault 2 Status,Firewall Enabled," +
            "Secure Boot Level,Processor Type,Apple Silicon,Boot Drive Percentage Full\n" +
            "Mac-001,1,15.4,2024-01-01,Enabled,Enabled,Encrypted,On,Full Security," +
            "Intel Core i9,false,45%\n"
        let csvData = Data(csvText.utf8)
        let wb = Workbook()
        var config = ReportConfig()
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        config.columns = cols
        let dashboard = try XCTUnwrap(CSVDashboard(config: config, csvData: csvData, workbook: wb))
        XCTAssertEqual(dashboard.csvFamily, .computers)
    }

    func testCSVFamilyDetectedMobile() throws {
        let csvText = "Display Name,JSS Mobile Device ID,OS Version,Last Inventory Update," +
            "Jailbreak Detected,Wi-Fi MAC Address,Battery Level,Lost Mode Enabled," +
            "Device Ownership Type,Passcode Status\n" +
            "iPad-001,100,18.0,2024-01-01,false,aa:bb:cc:dd:ee:ff,85%,false," +
            "Institutional,Compliant\n"
        let csvData = Data(csvText.utf8)
        let wb = Workbook()
        let config = ReportConfig()
        let dashboard = try XCTUnwrap(CSVDashboard(config: config, csvData: csvData, workbook: wb))
        XCTAssertEqual(dashboard.csvFamily, .mobile)
    }

    // MARK: - Sheet routing by family

    func testSheetPlan_computerCSV_noMobileSheets() throws {
        // A computer CSV must not produce mobile sheets even when mobile_columns is configured.
        let csvText = "Computer Name,JSS Computer ID,Operating System Version,Last Check-in," +
            "Gatekeeper,Firewall Enabled,FileVault 2 Status\n" +
            "Mac-001,1,15.0,2024-01-01,Enabled,Enabled,Encrypted\n"
        let csvData = Data(csvText.utf8)
        let wb = Workbook()
        var config = ReportConfig()
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        config.columns = cols
        var mobile = MobileColumnConfig()
        mobile.deviceName = "Display Name"
        config.mobileColumns = mobile
        let dashboard = try XCTUnwrap(CSVDashboard(config: config, csvData: csvData, workbook: wb))
        XCTAssertEqual(dashboard.csvFamily, .computers)
        let sheetNames = dashboard.sheetPlan.map { $0.name }
        XCTAssertTrue(sheetNames.contains("Device Inventory"),
                      "Computer CSV must include Device Inventory sheet")
        XCTAssertFalse(sheetNames.contains("Mobile Device Inventory"),
                       "Computer CSV must not include Mobile Device Inventory sheet")
        XCTAssertFalse(sheetNames.contains("Mobile Stale Devices"),
                       "Computer CSV must not include Mobile Stale Devices sheet")
    }

    func testSheetPlan_mobileCSV_onlyMobileSheets() throws {
        // A mobile CSV must produce only mobile sheets (no Device Inventory etc.).
        let csvText = "Display Name,JSS Mobile Device ID,OS Version,Last Inventory Update," +
            "Jailbreak Detected,Wi-Fi MAC Address,Battery Level,Lost Mode Enabled," +
            "Device Ownership Type,Passcode Status\n" +
            "iPad-001,100,18.0,2024-01-01,false,aa:bb:cc:dd:ee:ff,85%,false," +
            "Institutional,Compliant\n"
        let csvData = Data(csvText.utf8)
        let wb = Workbook()
        let config = ReportConfig()
        let dashboard = try XCTUnwrap(CSVDashboard(config: config, csvData: csvData, workbook: wb))
        XCTAssertEqual(dashboard.csvFamily, .mobile)
        let sheetNames = dashboard.sheetPlan.map { $0.name }
        XCTAssertTrue(sheetNames.contains("Mobile Device Inventory"),
                      "Mobile CSV must include Mobile Device Inventory sheet")
        XCTAssertTrue(sheetNames.contains("Mobile Stale Devices"),
                      "Mobile CSV must include Mobile Stale Devices sheet")
        XCTAssertFalse(sheetNames.contains("Device Inventory"),
                       "Mobile CSV must not include Device Inventory sheet")
        XCTAssertFalse(sheetNames.contains("Security Controls"),
                       "Mobile CSV must not include Security Controls sheet")
    }

    // MARK: - Continuation-row drop

    func testContinuationRowsDroppedFromComputerCSV() throws {
        // A 97-device export may be 607 rows due to continuation rows for
        // multi-value fields (Applications, Certificates, Groups…).
        // Rows whose Computer Name cell is blank must be dropped.
        let header = "Computer Name,Serial Number,Operating System Version"
        let real1  = "Mac-001,ABC123,15.4"
        let real2  = "Mac-002,DEF456,14.7"
        // These rows have a blank Computer Name — continuation rows.
        let cont1  = ",,"
        let cont2  = ",,"
        let cont3  = ",,"
        let csvText = [header, real1, cont1, cont2, real2, cont3].joined(separator: "\n") + "\n"
        let csvData = Data(csvText.utf8)
        let wb = Workbook()
        var config = ReportConfig()
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        cols.serialNumber = "Serial Number"
        config.columns = cols
        let dashboard = try XCTUnwrap(CSVDashboard(config: config, csvData: csvData, workbook: wb))
        // Only the 2 real device rows should survive.
        XCTAssertEqual(dashboard.rows.count, 2,
                       "Continuation rows with blank identity must be dropped")
    }

    func testContinuationRowsNotDroppedWhenIdentityColumnAbsent() throws {
        // When the configured identity column is not in the CSV headers,
        // no rows are dropped (guard: only drop when the column is present but blank).
        let csvData = Data("Serial Number,OS Version\nABC123,15.4\n,15.4\n".utf8)
        let wb = Workbook()
        var config = ReportConfig()
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"  // not present in this CSV
        config.columns = cols
        let dashboard = try XCTUnwrap(CSVDashboard(config: config, csvData: csvData, workbook: wb))
        // Neither row has a blank Computer Name (column absent) — both kept.
        XCTAssertEqual(dashboard.rows.count, 2,
                       "Rows must not be dropped when the identity column is absent")
    }

    // MARK: - EA Warnings sheet in workbook

    func testEAWarningsSheetAbsentWhenAllColumnsPresent() throws {
        let eaColumn = "FileVault 2 - Status"
        let csvData = makeCSVData(eaColumnName: eaColumn, includeEAColumn: true)
        let wb = Workbook()
        let config = makeConfig(eaName: "FileVault Status", eaColumn: eaColumn)
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: csvData, workbook: wb)
        )
        dashboard.writeAll()
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".xlsx")
        try wb.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let data = try Data(contentsOf: tmpURL)
        // "EA Warnings" sheet name should not appear in any XML when all columns are present.
        let content = String(data: data, encoding: .isoLatin1) ?? ""
        XCTAssertFalse(content.contains("EA Warnings"),
                       "EA Warnings sheet must not be written when all columns are present.")
    }

    func testEAWarningsSheetPresentWhenColumnMissing() throws {
        let csvData = makeCSVData(eaColumnName: "FileVault 2 - Status", includeEAColumn: false)
        let wb = Workbook()
        let config = makeConfig(eaName: "FileVault Status", eaColumn: "FileVault 2 - Status")
        let dashboard = try XCTUnwrap(
            CSVDashboard(config: config, csvData: csvData, workbook: wb)
        )
        dashboard.writeAll()
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".xlsx")
        try wb.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let data = try Data(contentsOf: tmpURL)
        let content = String(data: data, encoding: .isoLatin1) ?? ""
        XCTAssertTrue(content.contains("EA Warnings"),
                      "EA Warnings sheet must be written when a configured EA column is absent.")
        XCTAssertTrue(content.contains("FileVault Status"),
                      "EA Warnings sheet must name the missing EA.")
        XCTAssertTrue(content.contains("FileVault 2 - Status"),
                      "EA Warnings sheet must name the expected column.")
    }

    // MARK: - DateParser time zone

    func testDateParserResolvesAgainstExplicitLocalTimeZone() {
        // Pins DateParser's zone-less formats to the local zone explicitly —
        // if a future change swaps in a different zone, this breaks loudly
        // rather than silently shifting every user's day counts.
        let parser = DateParser()
        let raw = "2024-06-15"
        let expectedFormatter = DateFormatter()
        expectedFormatter.locale = Locale(identifier: "en_US_POSIX")
        expectedFormatter.dateFormat = "yyyy-MM-dd"
        expectedFormatter.timeZone = TimeZone.current
        let expected = expectedFormatter.date(from: raw)
        XCTAssertEqual(parser.parse(raw), expected,
                       "Zone-less dates must resolve against the local time zone")
    }

    // MARK: - Stale Devices sort order

    func testStaleDevicesSortedMostStaleFirst() throws {
        func dateString(daysAgo: Int) -> String {
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
        let header = "Computer Name,Serial Number,Last Check-in"
        let rows = [
            "Mac-Least,AAA,\(dateString(daysAgo: 40))",
            "Mac-Most,BBB,\(dateString(daysAgo: 90))",
            "Mac-Mid,CCC,\(dateString(daysAgo: 60))",
        ]
        let csvText = ([header] + rows).joined(separator: "\n") + "\n"
        let csvData = Data(csvText.utf8)
        let wb = Workbook()
        var config = ReportConfig()
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        cols.serialNumber = "Serial Number"
        cols.lastCheckin = "Last Check-in"
        config.columns = cols
        var thresholds = ThresholdsConfig()
        thresholds.staleDeviceDays = 30
        config.thresholds = thresholds
        let dashboard = try XCTUnwrap(CSVDashboard(config: config, csvData: csvData, workbook: wb))
        dashboard.writeStaleDevices()
        let ws = try XCTUnwrap(wb.sheet(named: "Stale Devices"))
        // Header row consumes rows 0-3 (2-row title/subtitle merge + the column header row);
        // data rows start at row 4.
        let names = ws.cells
            .filter { $0.col == 0 && $0.row >= 4 }
            .sorted { $0.row < $1.row }
            .compactMap { cell -> String? in
                if case .string(let s) = cell.value { return s }
                return nil
            }
        XCTAssertEqual(names, ["Mac-Most", "Mac-Mid", "Mac-Least"],
                       "Stale devices must remain sorted most-stale-first")
    }

    // MARK: - Security Controls sheet

    private struct ControlRow: Equatable {
        let compliant: String
        let nonCompliant: String
        let unknown: String
        let percent: String
        let percentFormat: CellFormat?
        var warning: String? = nil
    }

    /// The columns of the real-shape built-in export (`jamf1128_computers_builtin.csv`), mapped
    /// as `config.example.yaml` does except where `filevault` or the hardware columns are given.
    private func securityColumns(
        fileVault: String = "FileVault 2 Status", model: String? = nil, architecture: String? = nil
    ) -> ColumnConfig {
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        cols.lastCheckin = "Last Check-in"
        cols.filevault = fileVault
        cols.sip = "System Integrity Protection"
        cols.firewall = "Firewall Enabled"
        cols.gatekeeper = "Gatekeeper"
        cols.secureBoot = "Secure Boot Level"
        cols.bootstrapToken = "Bootstrap Token Escrowed"
        cols.model = model
        cols.architecture = architecture
        return cols
    }

    private func builtinCSV() throws -> Data {
        try Data(contentsOf: TestFixtures.root.appendingPathComponent(
            "csv/jamf1128_computers_builtin.csv"))
    }

    /// Writes the Security Controls sheet and returns its rows by label, plus the header.
    private func securityControls(
        csv: Data, columns: ColumnConfig, policy: SecurityControlPolicy? = nil
    ) throws -> (header: [String], rows: [String: ControlRow]) {
        var config = ReportConfig()
        config.columns = columns
        config.securityPolicy = policy
        // The fixture's check-in dates are fixed, so keep every row active.
        var thresholds = ThresholdsConfig()
        thresholds.staleDeviceDays = 36500
        config.thresholds = thresholds
        let wb = Workbook()
        let dashboard = try XCTUnwrap(CSVDashboard(config: config, csvData: csv, workbook: wb))
        dashboard.writeSecurityControls()
        let cells = try XCTUnwrap(wb.sheet(named: "Security Controls")).dedupedCells
        func text(_ cell: (row: Int, col: Int, value: CellValue, format: CellFormat?)?) -> String {
            guard let cell else { return "" }
            switch cell.value {
            case .string(let s): return s
            case .int(let i): return "\(i)"
            case .double(let d): return "\(d)"
            default: return ""
            }
        }
        let headerCells = cells.filter { $0.format == .header }.sorted { $0.col < $1.col }
        var rows: [String: ControlRow] = [:]
        for label in cells where label.col == 0 && label.format == .cell {
            func at(_ col: Int) -> (row: Int, col: Int, value: CellValue, format: CellFormat?)? {
                cells.first { $0.row == label.row && $0.col == col }
            }
            rows[text(label)] = ControlRow(
                compliant: text(at(1)), nonCompliant: text(at(2)), unknown: text(at(3)),
                percent: text(at(4)), percentFormat: at(4)?.format,
                warning: at(5).map { text($0) })
        }
        return (headerCells.map { text($0) }, rows)
    }

    /// Fixture `jamf1128_computers_builtin.csv`: four Macs; one has FileVault, SIP, Firewall and
    /// Gatekeeper off. Both FileVault columns the fixture carries (the status text and the
    /// partition counts) read the same.
    func testSecurityControlCountsOnTheBuiltinExport() throws {
        for fileVault in ["FileVault 2 Status", "FileVault Status"] {
            let sheet = try securityControls(
                csv: builtinCSV(), columns: securityColumns(fileVault: fileVault))
            XCTAssertEqual(
                sheet.header, ["Control", "Compliant", "Non-Compliant", "Unknown", "% Compliant"])
            for label in ["FileVault", "SIP", "Firewall", "Gatekeeper"] {
                XCTAssertEqual(
                    sheet.rows[label],
                    ControlRow(compliant: "3", nonCompliant: "1", unknown: "0", percent: "0.75",
                               percentFormat: .pctRed),
                    "\(label) via \(fileVault)")
            }
            for label in ["Secure Boot", "Bootstrap Token"] {
                XCTAssertEqual(
                    sheet.rows[label],
                    ControlRow(compliant: "4", nonCompliant: "0", unknown: "0", percent: "1.0",
                               percentFormat: .pctGreen),
                    label)
            }
        }
    }

    /// A small export: `rows` hold FV, SIP, FW, GK, SB, BT, Model Identifier and Architecture.
    private func inlineCSV(_ rows: [[String]]) -> Data {
        let header = "Computer Name,Last Check-in,FV,SIP,FW,GK,SB,BT,Model Identifier,Architecture"
        let lines = rows.enumerated().map { index, values in
            (["Mac\(index)", "2026-05-01 09:00:00"] + values).joined(separator: ",")
        }
        return Data(([header] + lines).joined(separator: "\n").utf8)
    }

    private func inlineColumns(hardware: Bool = false) -> ColumnConfig {
        var cols = ColumnConfig()
        cols.computerName = "Computer Name"
        cols.lastCheckin = "Last Check-in"
        cols.filevault = "FV"
        cols.sip = "SIP"
        cols.firewall = "FW"
        cols.gatekeeper = "GK"
        cols.secureBoot = "SB"
        cols.bootstrapToken = "BT"
        if hardware {
            cols.model = "Model Identifier"
            cols.architecture = "Architecture"
        }
        return cols
    }

    private func counts(_ row: ControlRow?) -> [String] {
        guard let row else { return [] }
        return [row.compliant, row.nonCompliant, row.unknown] + (row.warning.map { [$0] } ?? [])
    }

    /// Intended change: a value Jamf did not collect (or a Mac cannot report) was
    /// non-compliant. It says nothing about the control, so it counts as unknown.
    func testNotCollectedAndUnsupportedValuesAreUnknown() throws {
        let csv = inlineCSV([
            ["Encrypted", "Enabled", "Enabled", "Enabled", "Full Security", "Yes", "", ""],
            ["Not collected", "Not collected", "Not collected", "Not collected", "",
             "Not Supported", "", ""],
            ["Not Encrypted", "Disabled", "Not Enabled", "Off", "", "No", "", ""],
        ])
        let sheet = try securityControls(csv: csv, columns: inlineColumns())
        XCTAssertEqual(counts(sheet.rows["FileVault"]), ["1", "1", "1"])
        XCTAssertEqual(counts(sheet.rows["SIP"]), ["1", "1", "1"])
        XCTAssertEqual(counts(sheet.rows["Firewall"]), ["1", "1", "1"])
        XCTAssertEqual(counts(sheet.rows["Gatekeeper"]), ["1", "1", "1"])
        XCTAssertEqual(counts(sheet.rows["Bootstrap Token"]), ["1", "1", "1"])
    }

    /// Secure Boot keeps its own rule: Full and Medium Security are compliant, any other value
    /// is not, and a blank is unknown.
    func testSecureBootKeepsItsRule() throws {
        let csv = inlineCSV([
            ["", "", "", "", "Full Security", "", "", ""],
            ["", "", "", "", "Medium Security", "", "", ""],
            ["", "", "", "", "No Security", "", "", ""],
            ["", "", "", "", "Unsupported OS Version", "", "", ""],
            ["", "", "", "", "", "", "", ""],
        ])
        let sheet = try securityControls(csv: csv, columns: inlineColumns())
        XCTAssertEqual(counts(sheet.rows["Secure Boot"]), ["2", "2", "1"])
    }

    func testBootstrapTokenReadsLikeTheOtherControls() throws {
        let csv = inlineCSV([
            ["", "", "", "", "", "Yes", "", ""], ["", "", "", "", "", "Escrowed", "", ""],
            ["", "", "", "", "", "No", "", ""], ["", "", "", "", "", "Not Escrowed", "", ""],
            ["", "", "", "", "", "Unknown", "", ""],
        ])
        let sheet = try securityControls(csv: csv, columns: inlineColumns())
        XCTAssertEqual(counts(sheet.rows["Bootstrap Token"]), ["2", "2", "1"])
    }

    // MARK: - Security Controls sheet: the policy

    private func hardwareColumns() -> ColumnConfig {
        securityColumns(architecture: "Architecture Type")
    }

    /// The built-in export's four Macs are Apple silicon; the one with FileVault off (0/1)
    /// is hardware-encrypted, so the rule moves it out of Non-Compliant.
    func testHardwareRuleAtWarningCountsTheEncryptedMacAsAWarning() throws {
        let sheet = try securityControls(
            csv: builtinCSV(), columns: hardwareColumns(),
            policy: SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning))
        XCTAssertEqual(sheet.header, [
            "Control", "Compliant", "Non-Compliant", "Unknown", "% Compliant", "Warning",
        ])
        XCTAssertEqual(counts(sheet.rows["FileVault"]), ["3", "0", "0", "1"])
        XCTAssertEqual(sheet.rows["FileVault"]?.percent, "0.75")
        XCTAssertEqual(counts(sheet.rows["SIP"]), ["3", "1", "0", "0"])
        XCTAssertEqual(counts(sheet.rows["Secure Boot"]), ["4", "0", "0", "0"])
    }

    /// At `ignore` the Mac is not counted at all, so it leaves the share: three of the three
    /// Macs left are compliant.
    func testHardwareRuleAtIgnoreLeavesTheEncryptedMacOutOfTheShare() throws {
        let sheet = try securityControls(
            csv: builtinCSV(), columns: hardwareColumns(),
            policy: SecurityControlPolicy(fileVaultOffHardwareEncrypted: .ignore))
        XCTAssertEqual(counts(sheet.rows["FileVault"]), ["3", "0", "0", "0"])
        XCTAssertEqual(sheet.rows["FileVault"]?.percent, "1.0")
        XCTAssertEqual(sheet.rows["FileVault"]?.percentFormat, .pctGreen)
    }

    /// Hardware columns are often unmapped; then hardware is unknown and FileVault's own
    /// level applies. The Warning column is still there, because the rule is set.
    func testHardwareRuleWithoutHardwareColumnsKeepsFileVaultsOwnLevel() throws {
        let sheet = try securityControls(
            csv: builtinCSV(), columns: securityColumns(),
            policy: SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning))
        XCTAssertEqual(counts(sheet.rows["FileVault"]), ["3", "1", "0", "0"])
        XCTAssertEqual(sheet.header.last, "Warning")
    }

    /// The model identifier finds a T2 Mac when the architecture says Intel; an Intel Mac
    /// without T2 stays a failure.
    func testHardwareRuleReadsTheModelAndArchitectureColumns() throws {
        let csv = inlineCSV([
            ["Not Encrypted", "", "", "", "", "", "\"MacBookPro16,2\"", "x86_64"],
            ["Not Encrypted", "", "", "", "", "", "\"MacBookPro14,1\"", "x86_64"],
            ["Encrypted", "", "", "", "", "", "\"MacBookPro14,1\"", "x86_64"],
        ])
        let sheet = try securityControls(
            csv: csv, columns: inlineColumns(hardware: true),
            policy: SecurityControlPolicy(fileVaultOffHardwareEncrypted: .warning))
        XCTAssertEqual(counts(sheet.rows["FileVault"]), ["1", "1", "0", "1"])
    }

    func testControlAtWarningIsCountedInTheWarningColumn() throws {
        let sheet = try securityControls(
            csv: builtinCSV(), columns: securityColumns(),
            policy: SecurityControlPolicy(sip: .warning))
        XCTAssertEqual(counts(sheet.rows["SIP"]), ["3", "0", "0", "1"])
        XCTAssertEqual(counts(sheet.rows["FileVault"]), ["3", "1", "0", "0"])
    }

    /// An ignored control says so in its label and shows no Non-Compliant count; its other
    /// counts stay the facts, and nothing grades the share.
    func testIgnoredControlIsNotCounted() throws {
        let sheet = try securityControls(
            csv: builtinCSV(), columns: securityColumns(),
            policy: SecurityControlPolicy(firewall: .ignore))
        XCTAssertNil(sheet.rows["Firewall"])
        let firewall = try XCTUnwrap(sheet.rows["Firewall (not counted)"])
        XCTAssertEqual(firewall.nonCompliant, "\u{2014}")
        XCTAssertEqual(firewall.compliant, "3")
        XCTAssertEqual(firewall.unknown, "0")
        XCTAssertEqual(firewall.percentFormat, .pct)
        XCTAssertEqual(counts(sheet.rows["FileVault"]), ["3", "1", "0", "0"])
        XCTAssertEqual(sheet.header.last, "Warning")
    }
}
