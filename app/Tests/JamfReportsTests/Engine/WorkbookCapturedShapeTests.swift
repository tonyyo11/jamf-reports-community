import Foundation
import XCTest
@testable import JamfReports

/// Jamf Pro workbook tabs read from rows with the keys and types jamf-cli writes (captured
/// from a collect on 2026-11-11; the values are invented).
final class WorkbookCapturedShapeTests: XCTestCase {

    nonisolated(unsafe) private var dataDir: URL!

    override func setUpWithError() throws {
        dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-captured-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dataDir)
    }

    private func snapshot(_ kind: String, _ json: Any) throws {
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json)
            .write(to: dir.appendingPathComponent("\(kind)_20261111T120000.json"))
    }

    /// The tab's rows below the header row named by `header`, as cell text by column.
    private func rows(
        _ tab: String, after header: String, write: (CoreDashboard) throws -> Void
    ) throws -> [[String]] {
        let workbook = Workbook()
        try write(CoreDashboard(config: ReportConfig(), dataDir: dataDir, workbook: workbook))
        let cells = try XCTUnwrap(workbook.sheet(named: tab), "no tab \(tab)").dedupedCells
        var byRow: [Int: [Int: String]] = [:]
        for cell in cells {
            switch cell.value {
            case .string(let text): byRow[cell.row, default: [:]][cell.col] = text
            case .int(let number): byRow[cell.row, default: [:]][cell.col] = String(number)
            case .blank: byRow[cell.row, default: [:]][cell.col] = ""
            default: break
            }
        }
        let ordered = byRow.sorted { $0.key < $1.key }.map { row in
            (0...(row.value.keys.max() ?? 0)).map { row.value[$0] ?? "" }
        }
        let start = try XCTUnwrap(ordered.firstIndex { $0.first == header }, "no header")
        return Array(ordered[(start + 1)...])
    }

    func testSoftwareInstallsReadsTitleVersionAndDeviceCount() throws {
        try snapshot("software-installs", [
            ["device_count": 2, "title": "Example Editor.app", "version": "4.1.0"],
            ["device_count": 1, "title": "Example Editor.app", "version": "4.0.2"],
            ["title": "No Count.app", "version": "1.0"],
        ])
        let found = try rows("Software Installs", after: "Name") { try $0.writeSoftwareInstalls() }
        XCTAssertEqual(found, [
            ["Example Editor.app", "4.1.0", "2"],
            ["Example Editor.app", "4.0.2", "1"],
            ["No Count.app", "1.0", ""],
        ], "a row without a count is blank, not 0")
    }

    func testEACoverageNamesTheMacAndFillsAUniqueSerial() throws {
        try snapshot("ea-results", [
            ["definition_id": "7", "device": "Mac-A", "ea_name": "Example EA", "value": "yes"],
            ["definition_id": "7", "device": "Twin", "ea_name": "Example EA", "value": ""],
            ["definition_id": "8", "device": "Twin", "ea_name": "Other EA", "value": "12"],
        ])
        try snapshot("computers", [
            ["id": "1", "general": ["name": "Mac-A"], "hardware": ["serialNumber": "SERA"]],
            ["id": "2", "general": ["name": "Twin"], "hardware": ["serialNumber": "SERB"]],
            ["id": "3", "general": ["name": "Twin"], "hardware": ["serialNumber": "SERC"]],
        ])
        let found = try rows("EA Coverage", after: "EA Name") { try $0.writeEACoverage() }
        XCTAssertEqual(found, [
            ["Example EA", "Mac-A", "SERA", "yes"],
            ["Example EA", "Twin", "", ""],
            ["Other EA", "Twin", "", "12"],
        ], "two Macs named Twin: no serial is guessed")
    }
}
