import Foundation
import XCTest
@testable import JamfReports

/// Profile Status and App Status list the profiles and apps that errored, read from the
/// `{summary, failures}` envelope `pro report profile-status` and `app-status` print;
/// Package Lifecycle leaves out the columns Jamf's packages payload never fills.
///
/// Fixtures are invented but shaped like jamf-cli's output (checked against a production
/// snapshot's keys and types): `failures` rows carry device_type, devices, errors, id (a
/// string), last_error (a date), name and top_error.
final class WorkbookFailureSheetsTests: XCTestCase {

    private var tmpDirs: [URL] = []

    override func tearDown() {
        for dir in tmpDirs { try? FileManager.default.removeItem(at: dir) }
        tmpDirs.removeAll()
        super.tearDown()
    }

    private typealias Cell = (row: Int, col: Int, value: CellValue, format: CellFormat?)

    private func dashboard(
        _ snapshots: [(kind: String, hoursAgo: Int, rows: [[String: Any]])],
        yaml: String = ""
    ) throws -> CoreDashboard {
        let root = GoldenFleetWorkspace.freshRoot()
        tmpDirs.append(root)
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let anchor = GoldenFleetClock.anchorNoon()
        for snapshot in snapshots {
            let at = anchor.addingTimeInterval(TimeInterval(-snapshot.hoursAgo * 3600))
            try GoldenFleetWorkspace.writeSnapshot(
                kind: snapshot.kind, dataDir: dataDir, at: at, rows: snapshot.rows)
        }
        let config = try ConfigLoader.loadFromString(yaml)
        return CoreDashboard(config: config, dataDir: dataDir, workbook: Workbook())
    }

    private func text(_ value: CellValue) -> String {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        case .blank: return ""
        }
    }

    private func cells(_ dash: CoreDashboard, _ sheet: String) throws -> [Cell] {
        try XCTUnwrap(dash.workbook.sheet(named: sheet)?.dedupedCells, "no \(sheet) sheet")
    }

    /// The table under the header row whose first cell is `first`, as rows of cells by column.
    private func table(_ all: [Cell], header first: String) throws -> [[Int: Cell]] {
        let header = try XCTUnwrap(all.first { $0.col == 0 && text($0.value) == first }, first).row
        let rows = Set(all.filter { $0.row > header }.map(\.row)).sorted()
        return rows.map { row in
            Dictionary(uniqueKeysWithValues: all.filter { $0.row == row }.map { ($0.col, $0) })
        }
    }

    private func failure(
        _ id: String, _ name: String, errors: Int, devices: Int
    ) -> [String: Any] {
        ["device_type": "Computer", "devices": devices, "errors": errors, "id": id,
         "last_error": "2026-10-01", "name": name, "top_error": "Test failure for \(name)"]
    }

    private func envelope(
        _ failures: [[String: Any]], unique: String = "unique_profiles"
    ) -> [[String: Any]] {
        let totalErrors = failures.reduce(0) { $0 + ($1["errors"] as? Int ?? 0) }
        return [["summary": ["days": 30, "total_errors": totalErrors,
                      unique: failures.count, "unique_devices": 7],
          "failures": failures, "device_failures": [], "device_pending": []]]
    }

    // MARK: - Profile Status

    func testProfileStatusListsEachFailingProfileMostErrorsFirst() throws {
        let rows = envelope([
            failure("11", "Test Profile B", errors: 12, devices: 4),
            failure("12", "Test Profile A", errors: 40, devices: 6),
            failure("13", "Test Profile C", errors: 3, devices: 1),
        ])
        let dash = try dashboard([("profile-status", 0, rows)])
        try dash.writeProfileStatus()

        let all = try cells(dash, "Profile Status")
        let body = try table(all, header: "ID")
        XCTAssertEqual(body.map { text($0[1]?.value ?? .blank) },
                       ["Test Profile A", "Test Profile B", "Test Profile C"])
        XCTAssertEqual(body.map { text($0[3]?.value ?? .blank) }, ["40", "12", "3"])
        XCTAssertEqual(body.map { text($0[0]?.value ?? .blank) }, ["12", "11", "13"])
    }

    func testProfileStatusColoursErrorsAtTheConfiguredWarningThreshold() throws {
        let rows = envelope([
            failure("11", "Test Profile B", errors: 12, devices: 4),
            failure("12", "Test Profile A", errors: 40, devices: 6),
            failure("13", "Test Profile C", errors: 3, devices: 1),
        ])
        let dash = try dashboard([("profile-status", 0, rows)])
        try dash.writeProfileStatus()
        var body = try table(try cells(dash, "Profile Status"), header: "ID")
        XCTAssertEqual(body.map { $0[3]?.format }, [.yellow, .yellow, .cell],
                       "default warning is 10")

        let strict = try dashboard([("profile-status", 0, rows)],
                                   yaml: "thresholds:\n  profile_error_warning: 20\n")
        try strict.writeProfileStatus()
        body = try table(try cells(strict, "Profile Status"), header: "ID")
        XCTAssertEqual(body.map { $0[3]?.format }, [.yellow, .cell, .cell])
    }

    func testProfileStatusSummaryStatesTheWindowAndTotals() throws {
        let dash = try dashboard([("profile-status", 0, envelope([
            failure("12", "Test Profile A", errors: 40, devices: 6),
        ]))])
        try dash.writeProfileStatus()

        let all = try cells(dash, "Profile Status")
        func value(_ label: String) -> String? {
            guard let row = all.first(where: { $0.col == 0 && text($0.value) == label })?.row
            else { return nil }
            return all.first { $0.row == row && $0.col == 1 }.map { text($0.value) }
        }
        XCTAssertNotNil(all.first { text($0.value) == "Install errors, last 30 days" })
        XCTAssertEqual(value("Profiles with errors"), "1")
        XCTAssertEqual(value("Devices affected"), "7")
        XCTAssertEqual(value("Total errors"), "40")
    }

    func testProfileStatusWithNoFailuresSaysSoInsteadOfABlankRow() throws {
        let dash = try dashboard([("profile-status", 0, envelope([]))])
        try dash.writeProfileStatus()

        let all = try cells(dash, "Profile Status")
        XCTAssertNotNil(all.first { text($0.value) == "No profiles reported install errors." })
        XCTAssertNil(all.first { $0.col == 0 && text($0.value) == "ID" }, "no empty table")
    }

    func testProfileStatusReadsProfileStatusEvenWhenTheProfileListIsNewer() throws {
        let list: [[String: Any]] = [["id": 1, "name": "Test Profile A"]]
        let dash = try dashboard([
            ("profile-status", 2,
             envelope([failure("12", "Test Profile A", errors: 5, devices: 2)])),
            ("classic-macos-profiles", 0, list),
        ])
        try dash.writeProfileStatus()

        let body = try table(try cells(dash, "Profile Status"), header: "ID")
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(text(body[0][3]?.value ?? .blank), "5")
    }

    func testProfileStatusWithOnlyTheProfileListWritesNoSheet() throws {
        let list: [[String: Any]] = [["id": 1, "name": "Test Profile A"]]
        let dash = try dashboard([("classic-macos-profiles", 0, list)])
        XCTAssertThrowsError(try dash.writeProfileStatus())
    }

    // MARK: - App Status

    func testAppStatusListsEachFailingApp() throws {
        let rows = envelope([
            failure("21", "Test App B", errors: 3, devices: 2),
            failure("22", "Test App A", errors: 9, devices: 4),
        ], unique: "unique_apps")
        let dash = try dashboard([("app-status", 0, rows)])
        try dash.writeAppStatus()

        let all = try cells(dash, "App Status")
        let body = try table(all, header: "ID")
        XCTAssertEqual(body.map { text($0[1]?.value ?? .blank) }, ["Test App A", "Test App B"])
        XCTAssertEqual(body.map { $0[3]?.format }, [.yellow, .yellow], "any app error is flagged")
        XCTAssertNotNil(all.first { text($0.value) == "Apps with errors" })
    }

    func testAppStatusWithNoFailuresSaysSo() throws {
        let dash = try dashboard([("app-status", 0, envelope([], unique: "unique_apps"))])
        try dash.writeAppStatus()
        let all = try cells(dash, "App Status")
        XCTAssertNotNil(all.first { text($0.value) == "No apps reported install errors." })
    }

    // MARK: - Package Lifecycle

    /// The titles of the header row whose first cell is `first`, left to right.
    private func headerTitles(_ all: [Cell], first: String) throws -> [String] {
        let header = try XCTUnwrap(all.first { $0.col == 0 && text($0.value) == first }).row
        return all.filter { $0.row == header }.sorted { $0.col < $1.col }
            .map { text($0.value) }
    }

    private func package(_ name: String, size: Any = "", uploaded: String? = nil) -> [String: Any] {
        var row: [String: Any] = [
            "id": name, "packageName": name, "fileName": "\(name).pkg", "notes": "", "size": size,
        ]
        if let uploaded { row["uploadDate"] = uploaded }
        return row
    }

    func testPackageLifecycleLeavesOutColumnsJamfNeverFills() throws {
        let dash = try dashboard([("packages", 0, [package("Test A"), package("Test B")])])
        try dash.writePackageLifecycle()

        let all = try cells(dash, "Package Lifecycle")
        let titles = try headerTitles(all, first: "Package Name")
        XCTAssertEqual(titles, ["Package Name", "Filename", "Note"])
        XCTAssertFalse(all.contains { text($0.value) == "Unknown" })
        let known = try XCTUnwrap(all.first { text($0.value) == "Known Sizes" })
        XCTAssertEqual(text(all.first { $0.row == known.row && $0.col == known.col + 1 }?.value
                            ?? .blank), "0", "an empty size is not a known size")
        XCTAssertNotNil(all.first {
            text($0.value) == "Jamf reports no upload date or size for these packages, "
                + "so those columns are left out."
        })
    }

    func testPackageLifecycleKeepsTheColumnsWhenSomePackageCarriesThem() throws {
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400 * 5))
        let dash = try dashboard([("packages", 0, [
            package("Test A", size: 2_097_152, uploaded: recent), package("Test B"),
        ])])
        try dash.writePackageLifecycle()

        let all = try cells(dash, "Package Lifecycle")
        let titles = try headerTitles(all, first: "Package Name")
        XCTAssertEqual(titles, ["Package Name", "Filename", "Upload Date", "Age (days)",
                                "Age Bucket", "Size (MB)", "Note"])
        XCTAssertNotNil(all.first { text($0.value) == "0-30 days" })
        XCTAssertNotNil(all.first { text($0.value) == "Unknown" }, "the package with no date")
        XCTAssertNil(all.first { text($0.value).hasPrefix("Jamf reports no") })
    }
}
