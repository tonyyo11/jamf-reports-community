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
