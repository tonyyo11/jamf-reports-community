import XCTest
@testable import JamfReports

final class DeploymentHealthSheetTests: XCTestCase {

    private func dataDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-deploy-sheet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func land(_ fixture: String, kind: String, in dir: URL) throws {
        let data = try Data(contentsOf: TestFixtures.dir("deployment-health/\(fixture)"))
        let reduced = try XCTUnwrap(DeploymentSourceReduction.reduce(kind: kind, payload: data))
        let kindDir = dir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        try reduced.write(to: kindDir.appendingPathComponent("\(kind)_20261125T120000.json"))
    }

    private func texts(_ sheet: Worksheet) -> [Int: [Int: String]] {
        sheet.cells.reduce(into: [:]) { result, cell in
            if case .string(let text) = cell.value { result[cell.row, default: [:]][cell.col] = text }
        }
    }

    func testBothSectionsWithTheirColumnsAndOrder() throws {
        let dir = try dataDir()
        try land("app-installers-deployments-list.json", kind: "app-installers-deployments",
                 in: dir)
        try land("patch-policies-list.json", kind: "patch-policies", in: dir)
        let workbook = Workbook()
        try CoreDashboard(config: ReportConfig(), dataDir: dir, workbook: workbook)
            .writeDeploymentHealth()
        let sheet = try XCTUnwrap(workbook.sheet(named: "Deployment Health"))
        let rows = texts(sheet)
        let headerRows = rows.filter { $0.value[0] == "Name" }.keys.sorted()
        XCTAssertEqual(headerRows.count, 2)
        XCTAssertEqual(rows[headerRows[0]]?[6], "Assigned to another deployment")
        XCTAssertEqual(rows[headerRows[1]]?[10], "Patch title")
        // App Installers: the 40-of-400 deployment (10%) is at warning, ahead of the 0% one.
        XCTAssertEqual(rows[headerRows[0] + 1]?[0], "Example Browser")
        XCTAssertEqual(rows[headerRows[0] + 1]?[5], "At warning")
        XCTAssertEqual(rows[headerRows[0] + 2]?[9], "Pinned")
        // Patch policies: 15 of 100 at warning first, the not-enabled one under its heading.
        XCTAssertEqual(rows[headerRows[1] + 1]?[0], "Example Browser latest")
        XCTAssertTrue(rows.values.contains { $0[0] == "Not enabled" })
        let shares = sheet.cells.filter {
            if case .double = $0.value { return $0.format == .pctYellow } else { return false }
        }
        XCTAssertFalse(shares.isEmpty, "the share is a percentage cell")
    }

    func testEachStateIsWrittenAndTheTabIsSkippedOnlyWithNeither() throws {
        let dir = try dataDir()
        XCTAssertThrowsError(try CoreDashboard(
            config: ReportConfig(), dataDir: dir, workbook: Workbook()).writeDeploymentHealth())
        let kindDir = dir.appendingPathComponent("patch-policies", isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        try "nope".write(to: kindDir.appendingPathComponent("patch-policies_20261125T120000.json"),
                         atomically: true, encoding: .utf8)
        let workbook = Workbook()
        let log = SheetLog()
        try CoreDashboard(config: ReportConfig(), dataDir: dir, workbook: workbook,
                          onLine: log.append).writeDeploymentHealth()
        let all = texts(try XCTUnwrap(workbook.sheet(named: "Deployment Health")))
            .values.flatMap(\.values)
        XCTAssertTrue(all.contains("Could not be read"))
        XCTAssertTrue(all.contains("Not collected yet"))
        XCTAssertTrue(log.texts.contains {
            $0.contains("Deployment Health: the patch-policies snapshot could not be read")
        })
    }
}

private final class SheetLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in self.lock.withLock { self.lines.append(line.text) } }
    }
    var texts: [String] { lock.withLock { lines } }
}
