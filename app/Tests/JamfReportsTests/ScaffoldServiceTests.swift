import Foundation
import XCTest
@testable import JamfReports

/// Unit tests for ScaffoldService — scoring, YAML output, RFC 4180 header parsing,
/// BOM stripping, and file permissions.
final class ScaffoldServiceTests: XCTestCase {

    // MARK: - Helpers

    private func tempURL(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaffoldServiceTests-\(name)-\(UUID().uuidString).yaml")
    }

    private func csvURL(headers: [String], bom: Bool = false) throws -> URL {
        let line = headers.joined(separator: ",")
        let content = bom ? "\u{FEFF}\(line)\n" : "\(line)\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaffoldServiceTests-\(UUID().uuidString).csv")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Scoring: exact match wins

    func test_matchColumns_exactMatch_scores_highest() throws {
        let url = try csvURL(headers: ["Computer Name", "Serial Number", "Operating System Version"])
        let result = try ScaffoldService.matchColumns(from: url, profile: "test")
        XCTAssertEqual(result.columns["computer_name"], "Computer Name")
        XCTAssertEqual(result.columns["serial_number"], "Serial Number")
        XCTAssertEqual(result.columns["operating_system"], "Operating System Version")
    }

    // MARK: - Scoring: exclude pattern suppresses match

    func test_matchColumns_exclude_suppressesManagerMatch() throws {
        // "Managed By" contains the exclude "managed"; "Direct Manager" should win.
        let url = try csvURL(headers: ["Managed By", "Direct Manager", "Serial Number"])
        let result = try ScaffoldService.matchColumns(from: url, profile: "test")
        // "Managed By" is excluded for manager (contains "managed").
        // "Direct Manager" matches via hint "direct manager".
        XCTAssertEqual(result.columns["manager"], "Direct Manager",
                       "exclude pattern must suppress 'Managed By' from matching manager")
    }

    // MARK: - BOM stripping

    func test_matchColumns_stripsUTF8BOM() throws {
        let url = try csvURL(headers: ["Computer Name", "Serial Number"], bom: true)
        let result = try ScaffoldService.matchColumns(from: url, profile: "test")
        XCTAssertEqual(result.columns["computer_name"], "Computer Name",
                       "BOM must be stripped before header matching")
    }

    // MARK: - Empty CSV throws

    func test_matchColumns_emptyFile_returnsEmptyResult() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaffoldServiceTests-empty-\(UUID().uuidString).csv")
        try "".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        // Empty file has no headers — result should have no columns, not throw.
        let result = try ScaffoldService.matchColumns(from: url, profile: "test")
        XCTAssertTrue(result.columns.isEmpty)
    }

    // MARK: - writeConfig embeds profile slug

    func test_writeConfig_containsProfileSlug() throws {
        let url = try csvURL(headers: ["Computer Name"])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ScaffoldService.matchColumns(from: url, profile: "my-profile")
        let dest = tempURL(name: "writeConfig")
        defer { try? FileManager.default.removeItem(at: dest) }
        try ScaffoldService.writeConfig(to: dest, result: result, profile: "my-profile")
        let written = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(written.contains("profile: \"my-profile\""),
                      "written config must contain the profile slug")
    }

    // MARK: - writeMinimalConfig all columns empty

    func test_writeMinimalConfig_allColumnsEmpty() throws {
        let dest = tempURL(name: "minimal")
        defer { try? FileManager.default.removeItem(at: dest) }
        try ScaffoldService.writeMinimalConfig(to: dest, profile: "test-profile")
        let written = try String(contentsOf: dest, encoding: .utf8)
        // Every column line should have an empty string value.
        let columnLines = written.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("computer_name:")
                    || $0.trimmingCharacters(in: .whitespaces).hasPrefix("serial_number:")
                    || $0.trimmingCharacters(in: .whitespaces).hasPrefix("filevault:") }
        for line in columnLines {
            XCTAssertTrue(line.hasSuffix("\"\""), "column line must have empty string value: \(line)")
        }
    }

    // MARK: - writeConfig sets 0600 permissions

    func test_writeConfig_setsOwnerOnlyPermissions() throws {
        let url = try csvURL(headers: ["Computer Name"])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ScaffoldService.matchColumns(from: url, profile: "test")
        let dest = tempURL(name: "perms")
        defer { try? FileManager.default.removeItem(at: dest) }
        try ScaffoldService.writeConfig(to: dest, result: result, profile: "test")
        let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.int16Value
        XCTAssertEqual(perms, 0o600, "config.yaml must be written with 0600 permissions")
    }

    // MARK: - YAML injection: special characters in column names are escaped

    func test_writeConfig_escapesBackslashInColumnName() throws {
        let url = try csvURL(headers: ["Path\\Column"])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ScaffoldService.matchColumns(from: url, profile: "test")
        let dest = tempURL(name: "escape-backslash")
        defer { try? FileManager.default.removeItem(at: dest) }
        try ScaffoldService.writeConfig(to: dest, result: result, profile: "test")
        let written = try String(contentsOf: dest, encoding: .utf8)
        // A raw backslash in a YAML double-quoted scalar must be escaped as \\.
        XCTAssertFalse(written.contains("\"Path\\Column\""),
                       "unescaped backslash must not appear in YAML output")
    }

    func test_writeConfig_escapesDoubleQuoteInColumnName() throws {
        // Build a CSV with a quoted field containing a double-quote (RFC 4180: "").
        let raw = "\"Name \"\"Pro\"\" Column\",Serial Number\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaffoldServiceTests-quote-\(UUID().uuidString).csv")
        try raw.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ScaffoldService.matchColumns(from: url, profile: "test")
        let dest = tempURL(name: "escape-quote")
        defer { try? FileManager.default.removeItem(at: dest) }
        try ScaffoldService.writeConfig(to: dest, result: result, profile: "test")
        let written = try String(contentsOf: dest, encoding: .utf8)
        // Embedded " must become \" in YAML output so the scalar stays valid.
        XCTAssertTrue(written.contains("\\\""),
                      "double-quote in column name must be escaped as \\\" in YAML output")
    }

    // MARK: - Family detection in ScaffoldResult

    func test_matchColumns_computerCSV_familyIsComputers() throws {
        let url = try csvURL(headers: [
            "Computer Name", "JSS Computer ID", "Operating System Version",
            "Last Check-in", "Gatekeeper", "System Integrity Protection",
            "FileVault 2 Status", "Firewall Enabled", "Secure Boot Level",
            "Processor Type", "Apple Silicon", "Boot Drive Percentage Full",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ScaffoldService.matchColumns(from: url, profile: "test")
        XCTAssertEqual(result.family, .computers)
        XCTAssertFalse(result.columns.isEmpty,
                       "Computer CSV must produce non-empty columns block")
        XCTAssertTrue(result.mobileColumns.isEmpty,
                      "Computer CSV must produce empty mobileColumns block")
    }

    func test_matchColumns_mobileCSV_familyIsMobile() throws {
        let url = try csvURL(headers: [
            "Display Name", "JSS Mobile Device ID", "Device ID", "Serial Number",
            "OS Version", "Last Inventory Update", "Email Address", "Model",
            "Device Family", "Managed", "Supervised", "Jailbreak Detected",
            "Wi-Fi MAC Address", "Battery Level", "Lost Mode Enabled",
            "Device Ownership Type", "Passcode Status",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ScaffoldService.matchColumns(from: url, profile: "test")
        XCTAssertEqual(result.family, .mobile)
        XCTAssertFalse(result.mobileColumns.isEmpty,
                       "Mobile CSV must produce non-empty mobileColumns block")
        XCTAssertTrue(result.columns.isEmpty,
                      "Mobile CSV must produce empty columns block")
        // Key mobile columns must be correctly mapped.
        XCTAssertEqual(result.mobileColumns["device_name"], "Display Name")
        XCTAssertEqual(result.mobileColumns["operating_system"], "OS Version")
        XCTAssertEqual(result.mobileColumns["serial_number"], "Serial Number")
    }

    func test_matchColumns_computerWithManagedAndSupervised_familyIsComputers() throws {
        // Jamf Pro 11.28 computer exports include Managed + Supervised columns.
        // These shared columns must not cause misdetection as .mobile.
        let url = try csvURL(headers: [
            "Computer Name", "Apple Silicon", "Firewall Enabled", "JSS Computer ID",
            "Last Check-in", "Gatekeeper", "System Integrity Protection",
            "FileVault 2 Status", "Secure Boot Level", "Processor Type",
            "Boot Drive Percentage Full", "Operating System Version",
            "Managed", "Supervised",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ScaffoldService.matchColumns(from: url, profile: "test")
        XCTAssertEqual(result.family, .computers,
                       "Computer CSV with Managed+Supervised must detect as .computers")
        XCTAssertTrue(result.mobileColumns.isEmpty,
                      "Computer CSV must not populate mobileColumns")
    }

    func test_matchColumns_ambiguousCSV_familyIsNil() throws {
        // Headers with no discriminators → family is nil.
        let url = try csvURL(headers: ["Asset Tag", "Serial Number", "Email Address"])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ScaffoldService.matchColumns(from: url, profile: "test")
        XCTAssertNil(result.family,
                     "Headers with no discriminators must return nil family")
    }

    // MARK: - configYAML writes mobile_columns for mobile export

    func test_writeConfig_mobileCSV_writesMobileColumns() throws {
        let url = try csvURL(headers: [
            "Display Name", "JSS Mobile Device ID", "OS Version", "Last Inventory Update",
            "Email Address", "Model", "Device Family", "Managed", "Supervised",
            "Jailbreak Detected", "Wi-Fi MAC Address", "Battery Level",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ScaffoldService.matchColumns(from: url, profile: "test")
        let dest = tempURL(name: "mobile-writeConfig")
        defer { try? FileManager.default.removeItem(at: dest) }
        try ScaffoldService.writeConfig(to: dest, result: result, profile: "test")
        let written = try String(contentsOf: dest, encoding: .utf8)
        // mobile_columns block must be present with populated device_name.
        XCTAssertTrue(written.contains("mobile_columns:"),
                      "mobile_columns section must be written for mobile export")
        XCTAssertTrue(written.contains("device_name: \"Display Name\""),
                      "device_name must be mapped to 'Display Name' in mobile export")
        // columns block must have empty values.
        XCTAssertTrue(written.contains("computer_name: \"\""),
                      "computer_name must be empty for mobile export")
    }

    func test_writeConfig_computerCSV_writesComputerColumns() throws {
        let url = try csvURL(headers: [
            "Computer Name", "Serial Number", "Operating System Version",
            "Last Check-in", "Gatekeeper", "Firewall Enabled",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ScaffoldService.matchColumns(from: url, profile: "test")
        let dest = tempURL(name: "computer-writeConfig")
        defer { try? FileManager.default.removeItem(at: dest) }
        try ScaffoldService.writeConfig(to: dest, result: result, profile: "test")
        let written = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(written.contains("computer_name: \"Computer Name\""),
                      "computer_name must be mapped for computer export")
        // mobile_columns block must be present but empty.
        XCTAssertTrue(written.contains("mobile_columns:"),
                      "mobile_columns section must always be written")
        XCTAssertTrue(written.contains("device_name: \"\""),
                      "device_name must be empty for computer export")
    }

    // MARK: - Exact-match scoring: 200 - hintIndex picks first hint on tie

    func test_matchColumns_exactMatch_firstHintWinsOnTie() throws {
        // Python uses 200 - hintIndex, so "Last Check-in" (hint index 0) must win
        // over "Last Inventory Update" (hint index 3) when both are present.
        let url = try csvURL(headers: [
            "Last Inventory Update", "Last Check-in", "Computer Name",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ScaffoldService.matchColumns(from: url, profile: "test")
        XCTAssertEqual(result.columns["last_checkin"], "Last Check-in",
                       "First hint 'Last Check-in' must win over later hint 'Last Inventory Update'")
    }

    // MARK: - RFC 4180: quoted field with embedded comma

    func test_matchColumns_rfc4180_quotedFieldWithComma() throws {
        // CSV: "Name, with comma","Serial Number"
        let raw = "\"Name, with comma\",\"Serial Number\"\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaffoldServiceTests-rfc4180-\(UUID().uuidString).csv")
        try raw.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ScaffoldService.matchColumns(from: url, profile: "test")
        // "Serial Number" is the only recognized field; "Name, with comma" won't match.
        XCTAssertEqual(result.columns["serial_number"], "Serial Number",
                       "RFC 4180 quoted field with embedded comma must be parsed correctly")
        // The field count must be 2, not 3 (a naive split would produce "Name", " with comma", "Serial Number").
        // We verify this indirectly: computer_name should NOT match "with comma".
        XCTAssertNotEqual(result.columns["computer_name"], "with comma")
    }
}
