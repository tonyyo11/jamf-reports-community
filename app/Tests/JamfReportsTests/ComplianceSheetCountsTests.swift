import XCTest
@testable import JamfReports

/// The Compliance Devices and Compliance Rules sheets leave a count cell blank when the snapshot
/// carries no figure, as the mobile sheets do; 0 would claim a measured result.
final class ComplianceSheetCountsTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func dashboard(kind: String, rows: [[String: Any]]) throws -> CoreDashboard {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        try GoldenFleetWorkspace.writeSnapshot(
            kind: kind, dataDir: dataDir, at: GoldenFleetClock.anchorNoon(), rows: rows)
        return CoreDashboard(
            config: try ConfigLoader.loadFromString(""), dataDir: dataDir, workbook: Workbook())
    }

    private func text(_ value: CellValue?) -> String {
        switch value {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .bool(let b): String(b)
        case .blank, nil: ""
        }
    }

    /// The cells of the row whose first column reads `label`, by column.
    private func row(
        _ dash: CoreDashboard, _ sheet: String, _ label: String
    ) throws -> [Int: String] {
        let all = try XCTUnwrap(dash.workbook.sheet(named: sheet)?.dedupedCells, "no \(sheet)")
        let first = try XCTUnwrap(all.first { $0.col == 0 && text($0.value) == label })
        return Dictionary(uniqueKeysWithValues: all.filter { $0.row == first.row }
            .map { ($0.col, text($0.value)) })
    }

    func testComplianceDevicesLeavesAMissingCountBlank() throws {
        let dash = try dashboard(kind: "compliance-devices", rows: [
            ["benchmark": "NoCounts", "device": "Mac-1", "deviceId": "1", "compliance": "50%"],
            ["benchmark": "Zeros", "device": "Mac-2", "deviceId": "2", "rulesPassed": 0,
             "rulesFailed": 0, "compliance": "0%"],
        ])
        try dash.writeComplianceDevices()
        let missing = try row(dash, "Compliance Devices", "NoCounts")
        XCTAssertEqual(missing[3] ?? "", "")
        XCTAssertEqual(missing[4] ?? "", "")
        let measured = try row(dash, "Compliance Devices", "Zeros")
        XCTAssertEqual(measured[3], "0", "a measured zero stays 0")
        XCTAssertEqual(measured[4], "0")
    }

    func testComplianceRulesLeavesAMissingCountBlank() throws {
        let dash = try dashboard(kind: "compliance-rules", rows: [
            ["benchmark": "NoCounts", "rule": "r1", "passRate": "50%"],
            ["benchmark": "Zeros", "rule": "r2", "passed": 0, "failed": 0, "unknown": 0,
             "devices": 0, "passRate": "0%"],
        ])
        try dash.writeComplianceRules()
        let missing = try row(dash, "Compliance Rules", "NoCounts")
        for col in 2...5 { XCTAssertEqual(missing[col] ?? "", "", "column \(col)") }
        let measured = try row(dash, "Compliance Rules", "Zeros")
        for col in 2...5 { XCTAssertEqual(measured[col], "0", "column \(col)") }
    }
}
