import Foundation
import XCTest
import ZIPFoundation
@testable import JamfReports

/// `sheets.only`, `skip` and `order` decide the tabs of every workbook the app writes: the
/// jamf-cli tabs, the CSV tabs and the Jamf School tabs, after the template chose its sheets.
final class SheetsSettingsTests: XCTestCase {

    // MARK: - Generated workbooks

    func testSkipRemovesAJamfCLITabFromTheWorkbookGenerateWrites() async throws {
        try await withScratch { scratch in
            let dataDir = try fixtureData(["overview"], in: scratch)
            let plain = try await generate(ReportConfig(), dataDir: dataDir, in: scratch)
            XCTAssertTrue(plain.contains("Fleet Overview"), "the fixture writes the tab: \(plain)")

            let skipped = try await generate(
                try ConfigLoader.loadFromString("sheets:\n  skip: [fleet overview]\n"),
                dataDir: dataDir, in: scratch)
            XCTAssertFalse(skipped.contains("Fleet Overview"), "\(skipped)")
            XCTAssertTrue(skipped.contains("Cover"))
        }
    }

    func testOrderMovesACSVTabAheadOfTheJamfCLITabs() async throws {
        try await withScratch { scratch in
            let config = try ConfigLoader.loadFromString("""
            columns:
              computer_name: Computer Name
              serial_number: Serial Number
              operating_system: Operating System
              last_checkin: Last Check-in
            sheets:
              order: ["Device Inventory", "Cover"]
            """)
            let tabs = try await generate(
                config, dataDir: try fixtureData([], in: scratch), in: scratch,
                csv: TestFixtures.dir("csv/dummy_all_macs.csv"))
            XCTAssertEqual(Array(tabs.prefix(2)), ["Device Inventory", "Cover"], "\(tabs)")
        }
    }

    func testOnlyAndTheCustomTemplatesSelectionBothApply() async throws {
        try await withScratch { scratch in
            let config = try ConfigLoader.loadFromString(
                "sheets:\n  only: [Cover, Fleet Overview, Security Posture]\n")
            let template = CustomTemplate(
                includedSheets: [.cover, .compliancePosture, .fleetOverview])
            let tabs = try await generate(
                config, dataDir: try fixtureData(["overview", "security"], in: scratch),
                in: scratch, template: template)
            XCTAssertEqual(tabs, ["Cover", "Fleet Overview"],
                           "Security Posture is not in the template, Compliance Posture not in only")
        }
    }

    func testTheJamfSchoolWorkbookHonoursSkipAndOrder() async throws {
        try await withScratch { scratch in
            let dataDir = try fixtureData(["school-ibeacons", "school-dep-devices"], in: scratch)
            func school(_ yaml: String) async throws -> [String] {
                let out = scratch.appendingPathComponent("school-\(UUID().uuidString).xlsx")
                try await ReportEngine.schoolGenerate(
                    config: try ConfigLoader.loadFromString(yaml), csvURL: nil,
                    dataDir: dataDir, outputURL: out)
                return try Self.tabs(of: out)
            }
            let plain = try await school("sheets:\n  order: []\n")
            let ordered = try await school("sheets:\n  order: [ibeacons]\n")
            let skipped = try await school("sheets:\n  skip: [IBEACONS]\n")
            XCTAssertEqual(plain, ["DEP Devices", "iBeacons"])
            XCTAssertEqual(ordered, ["iBeacons", "DEP Devices"])
            XCTAssertEqual(skipped, ["DEP Devices"])
        }
    }

    // MARK: - The pieces

    func testASheetSkipLeavesOutNeverRunsSoItCannotFailTheRun() {
        struct Broken: Error {}
        var ran = false
        let registry = SheetRegistry(plan: [
            (SheetID.cover.rawValue, { ran = true; throw Broken() }),
            (SheetID.fleetOverview.rawValue, {}),
        ])
        let (written, failures, _) = registry.writeSelected(
            template: CustomTemplate(includedSheets: [.cover, .fleetOverview]),
            sheets: SheetsConfig(only: nil, skip: ["COVER"], order: nil))
        XCTAssertEqual(written, ["Fleet Overview"])
        XCTAssertTrue(failures.isEmpty)
        XCTAssertFalse(ran)
    }

    func testArrangeMatchesTabNamesTheWayTheWorkbookWritesThem() {
        let longName = "Endpoint Detection Agent Status Long Name"
        let workbook = Workbook()
        for name in ["Cover", ReportEngine.chartsSheetName, longName, "Fleet Overview"] {
            workbook.addSheet(name)
        }
        workbook.arrange(by: SheetsConfig(only: nil, skip: ["charts"], order: [longName]))
        XCTAssertNil(workbook.sheet(named: "Charts"), "the Charts tab follows skip too")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-arrange-\(UUID().uuidString).xlsx")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertNoThrow(try workbook.write(to: out))
        XCTAssertEqual(try Self.tabs(of: out),
                       [String(longName.prefix(31)), "Cover", "Fleet Overview"])
    }

    // MARK: - Helpers

    /// Tab names in workbook order, from `xl/workbook.xml`.
    static func tabs(of xlsx: URL) throws -> [String] {
        let archive = try Archive(url: xlsx, accessMode: .read)
        let entry = try XCTUnwrap(archive["xl/workbook.xml"])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let xml = String(decoding: data, as: UTF8.self)
        return xml.matches(of: #/<sheet name="([^"]*)"/#).map { String($0.output.1) }
    }

    private func generate(
        _ config: ReportConfig, dataDir: URL, in scratch: URL, csv: URL? = nil,
        template: any ReportTemplate = FullInstanceTemplate()
    ) async throws -> [String] {
        let out = scratch.appendingPathComponent("out-\(UUID().uuidString)/report.xlsx")
        try await ReportEngine(config: config, dataDir: dataDir)
            .generate(csvURL: csv, outputURL: out, template: template)
        return try Self.tabs(of: out)
    }

    private func fixtureData(_ kinds: [String], in scratch: URL) throws -> URL {
        let dataDir = scratch.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        for kind in kinds {
            try TestFixtures.copyDir("jamf-cli-data/\(kind)",
                                     to: dataDir.appendingPathComponent(kind, isDirectory: true))
        }
        return dataDir
    }

    /// A scratch folder that is also the workspaces root, so nothing generate writes beside the
    /// workbook (summaries, archives) can reach a real workspace.
    private func withScratch(_ body: (URL) async throws -> Void) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-sheets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", scratch.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: scratch)
        }
        try await body(scratch)
    }
}
