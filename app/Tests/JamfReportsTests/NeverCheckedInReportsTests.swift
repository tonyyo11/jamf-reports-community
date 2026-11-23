import XCTest
@testable import JamfReports

/// A Mac that never checked in, in the shape jamf-cli gives `device-compliance` (the NFR
/// GG27 Mac), beside one that checked in: every stale count must read it as stale.
final class NeverCheckedInReportsTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private let rows: [[String: Any]] = [
        ["name": "never", "serial": "N1", "days_since_contact": "N/A", "last_contact": "",
         "managed": true, "os_version": "", "stale": false],
        ["name": "live", "serial": "L1", "days_since_contact": "3",
         "last_contact": "2026-11-10", "managed": true, "os_version": "26.6.2", "stale": false],
    ]

    private func dashboard() throws -> CoreDashboard {
        let root = GoldenFleetWorkspace.freshRoot()
        roots.append(root)
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        try GoldenFleetWorkspace.writeSnapshot(
            kind: "device-compliance", dataDir: dataDir, at: GoldenFleetClock.anchorNoon(),
            rows: rows)
        return CoreDashboard(
            config: try ConfigLoader.loadFromString(""), dataDir: dataDir, workbook: Workbook())
    }

    private func value(_ dash: CoreDashboard, _ sheet: String, _ label: String) throws -> String {
        let all = try XCTUnwrap(dash.workbook.sheet(named: sheet)?.dedupedCells)
        let first = try XCTUnwrap(all.first { $0.col == 0 && Self.text($0.value) == label },
                                  "\(sheet) has no \(label)")
        let cell = try XCTUnwrap(all.first { $0.row == first.row && $0.col == 1 })
        return Self.text(cell.value)
    }

    private static func text(_ value: CellValue) -> String {
        switch value {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .bool(let b): String(b)
        case .blank: ""
        }
    }

    func testActiveDevices() throws {
        let dash = try dashboard()
        try dash.writeActiveDevices()
        XCTAssertEqual(try value(dash, "Active Devices", "Stale Devices"), "1")
        XCTAssertEqual(try value(dash, "Active Devices", "Active (non-stale)"), "1")
    }

    func testCheckInHealth() throws {
        let dash = try dashboard()
        try dash.writeCheckinHealth()
        XCTAssertEqual(try value(dash, "Check-in Health", "Overdue (>7 days)"), "1")
        XCTAssertEqual(try value(dash, "Check-in Health", "Checked In (within 7 days)"), "1")
    }

    func testCompliancePosture() throws {
        let dash = try dashboard()
        try dash.writeCompliancePosture()
        XCTAssertEqual(try value(dash, "Compliance Posture", "Stale Devices (>30 days)"), "1")
    }

    func testExecutiveSummaryTiers() throws {
        let dash = try dashboard()
        let m = CoreDashboard.executiveMetrics(config: dash.config, dataDir: dash.dataDir)
        XCTAssertEqual(m.recentCount, 1, "only the Mac that checked in")
        XCTAssertEqual(m.dormantCount, 1, "never checked in")
    }

    func testDeviceComplianceSheet() throws {
        let dash = try dashboard()
        try dash.writeDeviceCompliance()
        let cells = try XCTUnwrap(dash.workbook.sheet(named: "Device Compliance")?.dedupedCells)
        let stale = cells.filter { $0.col == 3 }.map { Self.text($0.value) }
        XCTAssertEqual(stale.filter { $0 == "Yes" }.count, 1)
    }

    func testCheckedInScoreFactor() throws {
        let decoded = try JSONDecoder().decode(
            [DeviceComplianceRow].self, from: JSONSerialization.data(withJSONObject: rows))
        var sources = SecurityScoreInputs.Sources.none
        sources.complianceRows = decoded
        let factor = SecurityScoreFactor(.checkedIn, weight: 5)
        let measure = SecurityScoreInputs.measures(
            for: [factor], fleet: nil, sources: sources, config: nil)[factor.key]
        XCTAssertEqual(measure?.evaluated, 2)
        XCTAssertEqual(measure?.passing, 1, "the never-checked-in Mac does not pass")
    }
}
