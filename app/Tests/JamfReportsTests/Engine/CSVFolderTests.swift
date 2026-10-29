import Foundation
import XCTest
import ZIPFoundation
@testable import JamfReports

/// The CSV folder: one CSV per workbook tab beside the workbook, serialized from the cells the
/// tabs' writers put on the `Workbook`. The workbook file is the reference: every CSV must hold
/// the rows its tab holds in the `.xlsx`.
final class CSVFolderTests: XCTestCase {

    // MARK: - CSV rows equal workbook rows, per tab family

    func testTheJamfCLITabsAndEATabsHoldTheSameRowsInTheCSVsAsInTheWorkbook() async throws {
        try await withScratch { scratch in
            let dataDir = try fixtureData(
                ["overview", "security", "patch-status", "policy-status", "computers-list",
                 "computer-extension-attributes", "ea-results", "classic-computer-groups",
                 "mobile-devices-list"], in: scratch)
            let config = try ConfigLoader.loadFromString("""
            custom_eas:
              - {name: FileVault, column: "FileVault 2 - Status", type: boolean, true_value: Encrypted}
            """)
            let out = scratch.appendingPathComponent("out/report.xlsx")
            try await ReportEngine(config: config, dataDir: dataDir).generate(
                outputURL: out, csvFolder: true, locateJamfCLI: { nil })

            let tabs = try XLSXReader.tabs(of: out)
            XCTAssertGreaterThan(tabs.count, 4, "the fixture writes several tab families")
            try assertFolderMatches(tabs, folder: folder(of: out))
            XCTAssertEqual(
                Set(["Cover", "Fleet Overview", "Patch Compliance", "EA Warnings"]).subtracting(tabs.map(\.name)), [],
                "\(tabs.map(\.name))")
        }
    }

    func testTheEATabsPercentCellsReadAsTheWorkbookShowsThem() async throws {
        try await withScratch { scratch in
            let dataDir = try fixtureData([], in: scratch)
            let eaDir = dataDir.appendingPathComponent("ea-results", isDirectory: true)
            try FileManager.default.createDirectory(at: eaDir, withIntermediateDirectories: true)
            let rows = (1...4).map { n in
                ["definition_id": "1", "device": "Mac-\(n)", "ea_name": "FV",
                 "value": n == 1 ? "Off" : "Encrypted"]
            }
            try JSONSerialization.data(withJSONObject: rows)
                .write(to: eaDir.appendingPathComponent("ea-results_20261004T100000.json"))
            let config = try ConfigLoader.loadFromString("""
            custom_eas:
              - {name: FileVault, column: FV, type: boolean, true_value: Encrypted}
            """)
            let out = scratch.appendingPathComponent("out/report.xlsx")
            try await ReportEngine(config: config, dataDir: dataDir).generate(
                outputURL: out, csvFolder: true, locateJamfCLI: { nil })

            let csv = try String(
                contentsOf: folder(of: out).appendingPathComponent("FileVault.csv"),
                encoding: .utf8)
            XCTAssertTrue(csv.contains("75.0%"), csv)
            try assertFolderMatches(try XLSXReader.tabs(of: out), folder: folder(of: out))
        }
    }

    func testTheJamfSchoolTabsHoldTheSameRows() async throws {
        try await withScratch { scratch in
            let dataDir = try fixtureData(["school-ibeacons", "school-dep-devices"], in: scratch)
            let out = scratch.appendingPathComponent("out/school.xlsx")
            try await ReportEngine.schoolGenerate(
                config: ReportConfig(), dataDir: dataDir, outputURL: out, csvFolder: true)

            let tabs = try XLSXReader.tabs(of: out)
            XCTAssertEqual(tabs.map(\.name), ["DEP Devices", "iBeacons"])
            try assertFolderMatches(tabs, folder: folder(of: out))
        }
    }

    // MARK: - The formula guard

    func testEveryCellStartingWithAFormulaCharacterGetsOneTabPrefix() throws {
        let workbook = Workbook()
        let sheet = workbook.addSheet("Guard")
        let hostile = ["=SUM(A1)", "+1", "-1", "@x", "\tx", "\rx", "\r\nx"]
        for (index, value) in hostile.enumerated() { sheet.write(value, row: index, col: 0) }
        sheet.write("plain", row: 7, col: 0)
        sheet.write("a,b", row: 8, col: 0)
        sheet.write("say \"hi\"", row: 9, col: 0)
        sheet.write("two\nlines", row: 10, col: 0)
        let folder = scratchURL("guard_csv")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try workbook.writeCSVFolder(to: folder)

        let rows = Self.parseCSV(try String(
            contentsOf: folder.appendingPathComponent("Guard.csv"), encoding: .utf8))
        XCTAssertEqual(rows.map { $0[0] }, hostile.map { "\t" + $0 } + [
            "plain", "a,b", "say \"hi\"", "two\nlines"])
    }

    func testTheCSVAndTheCSVExportsShareOneGuard() {
        for value in ["=1", "+1", "-1", "@a", "\ta", "\ra", "\r\na", "plain", ""] {
            XCTAssertEqual(StaleDeviceService.formulaGuarded(value),
                           StaleDeviceService.csvField(value).replacingOccurrences(
                               of: "\"", with: ""),
                           value.debugDescription)
        }
    }

    // MARK: - Sheet settings and names

    func testSheetsSkipAndOnlyDecideWhichCSVsAreWritten() async throws {
        try await withScratch { scratch in
            let dataDir = try fixtureData(["overview", "security"], in: scratch)
            func files(_ yaml: String) async throws -> [String] {
                let out = scratch.appendingPathComponent("out-\(UUID().uuidString)/report.xlsx")
                try await ReportEngine(config: try ConfigLoader.loadFromString(yaml), dataDir: dataDir)
                    .generate(outputURL: out, csvFolder: true, locateJamfCLI: { nil })
                return try names(in: folder(of: out))
            }
            let all = try await files("columns: {}\n")
            XCTAssertTrue(all.contains("Fleet Overview.csv"), "\(all)")
            let skipped = try await files("sheets:\n  skip: [fleet overview]\n")
            XCTAssertEqual(skipped, all.filter { $0 != "Fleet Overview.csv" })
            let only = try await files("sheets:\n  only: [Cover, Fleet Overview]\n")
            XCTAssertEqual(only, ["Cover.csv", "Fleet Overview.csv"])
        }
    }

    func testATabNameBecomesAVisibleFileNameInsideTheFolder() throws {
        let workbook = Workbook()
        workbook.addSheet(".hidden %20 tab").write("x", row: 0, col: 0)
        let folder = scratchURL("names_csv")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try workbook.writeCSVFolder(to: folder)
        let written = try names(in: folder)
        XCTAssertEqual(written.count, 1)
        XCTAssertFalse(try XCTUnwrap(written.first).hasPrefix("."), "\(written)")
        XCTAssertTrue(try XCTUnwrap(written.first).hasSuffix(".csv"))
    }

    func testATabWithOnlyImagesWritesNoFile() throws {
        let workbook = Workbook()
        workbook.addSheet("Charts").insertImage(row: 0, col: 0, data: Data([1]), filename: "a.png")
        workbook.addSheet("Data").write("x", row: 0, col: 0)
        let folder = scratchURL("images_csv")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        XCTAssertEqual(try workbook.writeCSVFolder(to: folder), 1)
        XCTAssertEqual(try names(in: folder), ["Data.csv"])
    }

    // MARK: - When the folder is written

    func testTheConfigKeyWritesTheFolderAndAbsentOrMistypedDoesNot() async throws {
        try await withScratch { scratch in
            let dataDir = try fixtureData(["overview"], in: scratch)
            func run(_ yaml: String, csvFolder: Bool = false) async throws -> URL {
                let out = scratch.appendingPathComponent("out-\(UUID().uuidString)/report.xlsx")
                try await ReportEngine(config: try ConfigLoader.loadFromString(yaml), dataDir: dataDir)
                    .generate(outputURL: out, csvFolder: csvFolder, locateJamfCLI: { nil })
                return out
            }
            let on = try await run("output:\n  csv_folder: true\n")
            XCTAssertEqual(
                folder(of: on).lastPathComponent, "report_csv", "named as the workbook is")
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder(of: on).path))

            for yaml in ["columns: {}\n", "output:\n  csv_folder: false\n",
                         "output:\n  csv_folder: maybe\n"] {
                let out = try await run(yaml)
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder(of: out).path), yaml)
                XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), yaml)
            }
            let asked = try await run("output:\n  csv_folder: false\n", csvFolder: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder(of: asked).path))
        }
    }

    func testAMistypedKeyStillLoadsAndTheDoctorNamesIt() throws {
        let config = try ConfigLoader.loadFromString("output:\n  csv_folder: maybe\n")
        XCTAssertFalse(config.output?.writesCSVFolder ?? true)
        let rows = ConfigDoctorService.fileReadBooleanRows(["output": ["csv_folder": "maybe"]])
        XCTAssertEqual(rows.map(\.id), ["config.value.output.csv_folder"])
        XCTAssertTrue(ConfigSchema.unknownKeys(in: ["output": ["csv_folder": true]]).isEmpty)
    }

    func testARerunReplacesTheFolderWholeAndLeavesNoStagingFolder() async throws {
        try await withScratch { scratch in
            let dataDir = try fixtureData(["overview"], in: scratch)
            let out = scratch.appendingPathComponent("out/report.xlsx")
            let engine = ReportEngine(config: ReportConfig(), dataDir: dataDir)
            try await engine.generate(outputURL: out, csvFolder: true, locateJamfCLI: { nil })
            let stale = folder(of: out).appendingPathComponent("Old tab.csv")
            try "old".write(to: stale, atomically: true, encoding: .utf8)

            try await engine.generate(outputURL: out, csvFolder: true, locateJamfCLI: { nil })
            XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
            let beside = try FileManager.default.contentsOfDirectory(
                atPath: out.deletingLastPathComponent().path)
            XCTAssertFalse(beside.contains { $0.contains(".tmp-") }, "\(beside)")
        }
    }

    func testALinkAtTheFoldersNameIsReplacedNotWrittenThrough() async throws {
        try await withScratch { scratch in
            let dataDir = try fixtureData(["overview"], in: scratch)
            let out = scratch.appendingPathComponent("out/report.xlsx")
            let target = scratch.appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try "keep".write(to: target.appendingPathComponent("mine.txt"),
                             atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(
                at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: folder(of: out), withDestinationURL: target)
            let lines = Lines()

            try await ReportEngine(config: ReportConfig(), dataDir: dataDir).generate(
                outputURL: out, csvFolder: true, locateJamfCLI: { nil }, onLine: lines.add)

            XCTAssertEqual(try names(in: target), ["mine.txt"], "nothing written through, nothing removed")
            let attributes = try FileManager.default.attributesOfItem(atPath: folder(of: out).path)
            XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory,
                           "the link is gone and a real folder is in its place")
            XCTAssertTrue(try names(in: folder(of: out)).contains("Cover.csv"))
            XCTAssertFalse(lines.all.contains { $0.hasPrefix(ReportEngine.csvFolderFailureMarker) })
        }
    }

    func testALinkAtTheWorkbooksNameIsReplacedNotWrittenThrough() throws {
        let root = scratchURL("workbook-link")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let victim = root.appendingPathComponent("victim.txt")
        try "keep".write(to: victim, atomically: true, encoding: .utf8)
        let book = root.appendingPathComponent("report.xlsx")
        try FileManager.default.createSymbolicLink(at: book, withDestinationURL: victim)
        let workbook = Workbook()
        workbook.addSheet("Cover").write("x", row: 0, col: 0)

        try workbook.write(to: book)

        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "keep")
        XCTAssertEqual(try XLSXReader.tabs(of: book).map(\.name), ["Cover"])
        XCTAssertEqual(try names(in: root), ["report.xlsx", "victim.txt"], "no staging file left")
    }

    func testStagingLeftoversOlderThanADayAreRemovedFromBothWriters() throws {
        let parent = scratchURL("staging")
        defer { try? FileManager.default.removeItem(at: parent.deletingLastPathComponent()) }
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let noon = Date.testNoon
        func age(_ url: URL, _ seconds: TimeInterval) throws {
            try fm.setAttributes([.modificationDate: noon.addingTimeInterval(-seconds)],
                                 ofItemAtPath: url.path)
        }
        func folder(_ name: String, age seconds: TimeInterval) throws -> URL {
            let url = parent.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try "x".write(to: url.appendingPathComponent("Cover.csv"), atomically: true, encoding: .utf8)
            try age(url, seconds)
            return url
        }
        func file(_ name: String, age seconds: TimeInterval) throws -> URL {
            let url = parent.appendingPathComponent(name)
            try "x".write(to: url, atomically: true, encoding: .utf8)
            try age(url, seconds)
            return url
        }
        let day: TimeInterval = 86_400
        let oldFolder = try folder(".report_x_csv.tmp-\(UUID().uuidString)", age: 2 * day)
        let freshFolder = try folder(".report_x_csv.tmp-\(UUID().uuidString)", age: 3_600)
        let otherFolder = try folder(".other.tmp-\(UUID().uuidString)", age: 2 * day)
        let oldFile = try file(".report_x.xlsx.tmp-\(UUID().uuidString)", age: 2 * day)
        let freshFile = try file(".report_y.xlsx.tmp-\(UUID().uuidString)", age: 3_600)
        let notStaging = try file(".report_z.xlsx.tmp-notauuid", age: 2 * day)
        let otherTool = try file(".other.tmp-\(UUID().uuidString)", age: 2 * day)
        let visible = try file("report_x.xlsx.tmp-\(UUID().uuidString)", age: 2 * day)
        let outside = scratchURL("staging-target")
        defer { try? fm.removeItem(at: outside.deletingLastPathComponent()) }
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = parent.appendingPathComponent(".report_y_csv.tmp-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)

        let workbook = Workbook()
        workbook.addSheet("Cover").write("x", row: 0, col: 0)
        try workbook.writeCSVFolder(to: parent.appendingPathComponent("report_z_csv"), now: noon)

        XCTAssertFalse(fm.fileExists(atPath: oldFolder.path))
        XCTAssertFalse(fm.fileExists(atPath: oldFile.path), "an old staged workbook goes too")
        for kept in [freshFolder, otherFolder, freshFile, notStaging, visible, otherTool] {
            XCTAssertTrue(fm.fileExists(atPath: kept.path), kept.lastPathComponent)
        }
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: link.path), "a link is left alone")
        XCTAssertTrue(fm.fileExists(atPath: outside.path))

        // Workbook.write sweeps the same way (its clock is the real one: the planted files are
        // dated by the test clock, so plant an old one for it by absolute date).
        let ancient = try file(".report_w.xlsx.tmp-\(UUID().uuidString)", age: 0)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)],
                             ofItemAtPath: ancient.path)
        try workbook.write(to: parent.appendingPathComponent("report_w.xlsx"))
        XCTAssertFalse(fm.fileExists(atPath: ancient.path))
        XCTAssertTrue(fm.fileExists(atPath: parent.appendingPathComponent("report_w.xlsx").path))
    }

    /// The six remaining `replaceItemAt` callers (status file, state files, manifests, SOFA
    /// cache, config.yaml, jamf-cli install) rely on it failing closed over a link: it throws
    /// (as of macOS 27) and neither writes through the link nor removes it. If a future macOS
    /// replaced the link instead, that is also safe; only a write through it would fail this.
    func testReplaceItemAtNeverWritesThroughALinkAtTheDestination() throws {
        let dir = scratchURL("replace")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let victim = dir.appendingPathComponent("victim.txt")
        try "keep".write(to: victim, atomically: true, encoding: .utf8)
        let destination = dir.appendingPathComponent("status.json")
        try fm.createSymbolicLink(at: destination, withDestinationURL: victim)
        let staged = dir.appendingPathComponent("staged.tmp")
        try "new".write(to: staged, atomically: true, encoding: .utf8)

        _ = try? fm.replaceItemAt(destination, withItemAt: staged)

        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "keep")
    }

    func testTwoTabsThatTheVolumeReadsAsOneNameGetASuffix() throws {
        let workbook = Workbook()
        workbook.addSheet("Straße").write("a", row: 0, col: 0)
        workbook.addSheet("STRASSE").write("b", row: 0, col: 0)
        workbook.addSheet("strasse").write("c", row: 0, col: 0)
        let folder = scratchURL("fold_csv")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        XCTAssertEqual(try workbook.writeCSVFolder(to: folder), 3)
        let written = try names(in: folder)
        XCTAssertEqual(written.count, 3, "\(written)")
        XCTAssertEqual(Set(written.map(ProfileName.folderKey)).count, 3,
                       "no two names are one file on the volume: \(written)")
        XCTAssertTrue(written.contains("Straße.csv") && written.contains("STRASSE_2.csv"),
                      "\(written)")
    }

    func testCsvTextWritesNumbersAsTheWorkbookShowsThem() {
        let sheet = Worksheet(name: "N")
        sheet.write(7, row: 0, col: 0)
        sheet.write(2.5, row: 0, col: 1)
        sheet.write(-3.0, row: 0, col: 2)
        sheet.write(-0.25, row: 1, col: 0)
        sheet.write(0.8333, row: 1, col: 1, format: .pct)
        sheet.write(true, row: 1, col: 2)
        XCTAssertEqual(sheet.csvText(), "7,2.5,-3\n-0.25,83.3%,true\n")
    }

    func testGenerateReportNamesTheFolderItWrote() async throws {
        try await withScratch { scratch in
            let dataDir = try fixtureData(["overview"], in: scratch)
            let out = scratch.appendingPathComponent("out/report.xlsx")
            let engine = ReportEngine(config: ReportConfig(), dataDir: dataDir)
            let written = try await engine.generateReport(
                outputURL: out, csvFolder: true, locateJamfCLI: { nil })
            XCTAssertEqual(written.csvFolder, folder(of: out))
            let none = try await engine.generateReport(
                outputURL: scratch.appendingPathComponent("out2/report.xlsx"),
                locateJamfCLI: { nil })
            XCTAssertNil(none.csvFolder)
        }
    }

    // MARK: - Run rotation

    func testAWorkbooksCSVFolderRotatesWithItAndAStandaloneFolderStays() throws {
        let root = scratchURL("rotation")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let output = root.appendingPathComponent("reports", isDirectory: true)
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        let runs = ["report_acme_2024-01-01_100000", "report_acme_2024-01-02_100000",
                    "report_acme_2024-01-03_100000"]
        for run in runs {
            try FileManager.default.createDirectory(
                at: output.appendingPathComponent("\(run)_csv"), withIntermediateDirectories: true)
            try "x".write(to: output.appendingPathComponent("\(run)_csv/Cover.csv"),
                          atomically: true, encoding: .utf8)
            try "x".write(to: output.appendingPathComponent("\(run).xlsx"),
                          atomically: true, encoding: .utf8)
        }
        let standalone = output.appendingPathComponent("report_acme_2023-01-01_100000_csv")
        try FileManager.default.createDirectory(at: standalone, withIntermediateDirectories: true)

        ReportEngine(config: ReportConfig(), dataDir: root).archiveOldRuns(
            outputDir: output, archiveDir: archive, stem: "report_acme", keep: 2)

        XCTAssertEqual(try names(in: archive), ["\(runs[0])_csv", "\(runs[0]).xlsx"].sorted())
        XCTAssertEqual(try names(in: archive.appendingPathComponent("\(runs[0])_csv")),
                       ["Cover.csv"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: standalone.path))
        for run in runs.dropFirst() {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: output.appendingPathComponent("\(run)_csv/Cover.csv").path), run)
        }
    }

    // MARK: - Generate sheet, GUI generate and the Reports list

    @MainActor
    func testTheCSVFolderFormatRunsTheWorkbookStepOnceAndSharesItsOutcome() async {
        func run(_ types: Set<GenerateOutputType>, exit: Int32 = 0)
            async -> (GenerateAllResult, Int) {
            var calls = 0
            let result = await CLIBridge.runGenerateAll(
                types: types, onLine: CLIBridge.noOpOnLine,
                generateXLSX: { calls += 1; return exit }, generateHTML: { 0 },
                generatePDF: { 0 }, generateCSV: { 0 }, tighten: {})
            return (result, calls)
        }
        let (alone, aloneCalls) = await run([.csvFolder])
        XCTAssertEqual(alone.succeeded, [.csvFolder])
        XCTAssertEqual(aloneCalls, 1)
        let (both, bothCalls) = await run([.xlsx, .csvFolder])
        XCTAssertEqual(Set(both.succeeded), [.xlsx, .csvFolder])
        XCTAssertEqual(bothCalls, 1)
        let (failed, _) = await run([.xlsx, .csvFolder], exit: 1)
        XCTAssertEqual(Set(failed.failed.map(\.type)), [.xlsx, .csvFolder])
        let (none, noneCalls) = await run([.html])
        XCTAssertEqual(noneCalls, 0)
        XCTAssertTrue(none.failed.isEmpty)
    }

    @MainActor
    func testTheSheetOffersTheFormatOnEveryWorkspaceAndNamesWhatItWrites() {
        let state = GenerateSheetState()
        XCTAssertTrue(state.offeredTypes.contains(.csvFolder))
        XCTAssertEqual(state.selectedTypes, [.xlsx], ".xlsx stays the default")
        state.schoolWorkspace = true
        XCTAssertEqual(state.offeredTypes, [.xlsx, .csvFolder])
        let line = GenerateSheetState.writtenFiles(
            for: .csvFolder, profile: "acme", schoolMode: false)
        XCTAssertTrue(line.hasPrefix("report_acme_<date>_csv/"), line)
        state.csvFolderConfigured = true
        state.selectedTypes = [.html]
        XCTAssertFalse(state.writesCSVFolderFromConfig, "no workbook is asked for")
        state.selectedTypes = [.xlsx]
        XCTAssertTrue(state.writesCSVFolderFromConfig, "output.csv_folder adds the folder")
        state.selectedTypes = [.xlsx, .csvFolder]
        XCTAssertFalse(state.writesCSVFolderFromConfig, "the ticked format has its own line")
        state.csvFolderConfigured = false
        state.schoolWorkspace = false
        state.selectedTemplateID = FullInstanceTemplate().identifier
        state.selectedTypes = [.csvFolder]
        state.htmlWithWorkbook = true
        XCTAssertTrue(state.writesHTMLWithWorkbook, "the workbook is written, so its HTML is")
    }

    @MainActor
    func testGenerateAllOfTheFormatLeavesTheFolderBesideTheWorkbookAndTheReportsListShowsIt()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-csv-folder-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("csvfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        try "columns: {}\n".write(to: workspace.appendingPathComponent("config.yaml"),
                                  atomically: true, encoding: .utf8)

        let result = await CLIBridge().generateAll(
            types: [.csvFolder], outputDir: nil, profile: "csvfolder",
            onLine: CLIBridge.noOpOnLine)

        XCTAssertEqual(result.succeeded, [.csvFolder])
        let reports = workspace.appendingPathComponent("Generated Reports", isDirectory: true)
        let written = try names(in: reports)
        let workbook = try XCTUnwrap(written.first { $0.hasSuffix(".xlsx") })
        XCTAssertTrue(written.contains(String(workbook.dropLast(5)) + "_csv"), "\(written)")

        let listed = ReportLibrary().list(profile: "csvfolder")
        let folderRow = try XCTUnwrap(listed.first { $0.name.hasSuffix("_csv") }, "\(listed)")
        XCTAssertTrue(folderRow.source.hasPrefix("CSV folder"), folderRow.source)
        XCTAssertNil(listed.first { $0.name.hasSuffix(".csv") }, "its files are not reports")
        XCTAssertEqual(ReportsView.profile(fromReportFilename: folderRow.name), "csvfolder")
    }

    // MARK: - The Reports list, free-text profile names

    @MainActor
    func testADottedProfilesFolderIsListedByItsSuffixAndReadsBackItsProfile() throws {
        try withReportsFixture(profile: "acme.jamfcloud.com") { reports, library in
            let name = "report_acme.jamfcloud.com_2026-10-04_091500_csv"
            try FileManager.default.createDirectory(
                at: reports.appendingPathComponent(name), withIntermediateDirectories: true)
            try "x".write(to: reports.appendingPathComponent("\(name)/Cover.csv"),
                          atomically: true, encoding: .utf8)

            let rows = library.list(profile: "acme.jamfcloud.com")
            let row = try XCTUnwrap(rows.first { $0.name == name }, "\(rows.map(\.name))")
            XCTAssertEqual(row.source, "CSV folder")
            XCTAssertEqual(row.size, FileDisplay.size(1))
            XCTAssertEqual(library.url(profile: "acme.jamfcloud.com", reportName: name)?
                .lastPathComponent, name)
            XCTAssertEqual(ReportsView.profile(fromReportFilename: name), "acme.jamfcloud.com")
            XCTAssertEqual(ReportsView.profile(
                fromReportFilename: "report_acme.jamfcloud.com_2026-10-04_091500.xlsx"),
                           "acme.jamfcloud.com")
            XCTAssertEqual(ReportLibrary.kindLabel(forFilename: name), "CSV folder")
        }
    }

    @MainActor
    func testALinkNamedAsAFolderAndAHugeFolderAreHandled() throws {
        try withReportsFixture(profile: "linked") { reports, library in
            let fm = FileManager.default
            let outside = reports.deletingLastPathComponent()
                .appendingPathComponent("outside", isDirectory: true)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            let inside = reports.appendingPathComponent("real", isDirectory: true)
            try fm.createDirectory(at: inside, withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                at: reports.appendingPathComponent("a_2026-10-04_091500_csv"),
                withDestinationURL: outside)
            try fm.createSymbolicLink(
                at: reports.appendingPathComponent("b_2026-10-04_091500_csv"),
                withDestinationURL: inside)
            let huge = reports.appendingPathComponent("c_2026-10-04_091500_csv")
            try fm.createDirectory(at: huge, withIntermediateDirectories: true)
            for n in 0...ReportLibrary.maxFolderEntriesRead {
                fm.createFile(atPath: huge.appendingPathComponent("f\(n).csv").path,
                              contents: Data("x".utf8))
            }

            let rows = library.list(profile: "linked")
            XCTAssertEqual(rows.map(\.name), ["c_2026-10-04_091500_csv"])
            XCTAssertEqual(rows.first?.size, "—", "too many entries to size")
        }
    }

    @MainActor
    private func withReportsFixture(
        profile: String, _ body: (URL, ReportLibrary) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-csv-lib-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent(ProfileName.pathComponent(profile), isDirectory: true)
        let reports = workspace.appendingPathComponent("Generated Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
            else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
            try? FileManager.default.removeItem(at: root)
        }
        try body(reports, ReportLibrary())
    }

    // MARK: - Helpers

    private func folder(of workbook: URL) -> URL { ReportEngine.csvFolderURL(besideWorkbook: workbook) }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func scratchURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-csvf-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: CLIBridge.LogLine) { lock.lock(); stored.append(line.text); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
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
    /// workbook can reach a real workspace.
    private func withScratch(_ body: (URL) async throws -> Void) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-csvfolder-\(UUID().uuidString)", isDirectory: true)
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

    /// Every workbook tab has a CSV of its name holding the same rows, and the folder holds
    /// nothing else.
    private func assertFolderMatches(
        _ tabs: [XLSXReader.Tab], folder: URL, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var expectedFiles: [String] = []
        for tab in tabs where !tab.rows.isEmpty {
            let name = ProfileName.pathComponent(tab.name) + ".csv"
            expectedFiles.append(name)
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            let csv = Self.parseCSV(text)
            XCTAssertEqual(csv.count, tab.rows.count, "\(tab.name): row count", file: file, line: line)
            for (index, row) in tab.rows.enumerated() where index < csv.count {
                XCTAssertEqual(csv[index].count, row.count, "\(tab.name) row \(index)",
                               file: file, line: line)
                for (column, cell) in row.enumerated() where column < csv[index].count {
                    XCTAssertTrue(
                        XLSXReader.matches(cell, csv: csv[index][column]),
                        "\(tab.name) r\(index + 1)c\(column + 1): \(cell) vs \(csv[index][column])",
                        file: file, line: line)
                }
            }
        }
        XCTAssertEqual(try names(in: folder), expectedFiles.sorted(), file: file, line: line)
    }

    /// RFC 4180, without trimming: the guard's leading tab must survive.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var scalars = Array(text.unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            if quoted {
                if scalar == "\"" {
                    if scalars.first == "\"" { field.unicodeScalars.append(scalar); scalars.removeFirst() }
                    else { quoted = false }
                } else { field.unicodeScalars.append(scalar) }
            } else if scalar == "\"" { quoted = true }
            else if scalar == "," { row.append(field); field = "" }
            else if scalar == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.unicodeScalars.append(scalar) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

/// A minimal `.xlsx` reader for the writer's own output: shared and inline strings, numbers
/// and booleans, as a dense grid per tab.
enum XLSXReader {
    struct Tab {
        let name: String
        let rows: [[Cell]]
    }
    enum Cell: CustomStringConvertible {
        case text(String), number(Double), bool(Bool), blank
        var description: String {
            switch self {
            case .text(let s): return "text(\(s.debugDescription))"
            case .number(let n): return "number(\(n))"
            case .bool(let b): return "bool(\(b))"
            case .blank: return "blank"
            }
        }
    }

    /// True when `csv` is how `cell` is written to a CSV: a percentage-format number reads as
    /// `83.3%`, so a CSV number with a `%` is compared as a percentage.
    static func matches(_ cell: Cell, csv: String) -> Bool {
        switch cell {
        case .blank: return csv.isEmpty
        case .text(let s): return csv == s
        case .bool(let b): return csv == (b ? "true" : "false")
        case .number(let n):
            if csv.hasSuffix("%"), let percent = Double(csv.dropLast()) {
                return abs(percent / 100 - n) < 0.0006
            }
            guard let value = Double(csv) else { return false }
            return abs(value - n) < 1e-9 * max(1, abs(n))
        }
    }

    static func tabs(of xlsx: URL) throws -> [Tab] {
        let archive = try Archive(url: xlsx, accessMode: .read)
        func entry(_ path: String) throws -> String {
            let found = try XCTUnwrap(archive[path], path)
            var data = Data()
            _ = try archive.extract(found) { data.append($0) }
            return String(decoding: data, as: UTF8.self)
        }
        let shared = try entry("xl/sharedStrings.xml").matches(of: #/(?s)<si><t[^>]*>(.*?)</t></si>/#)
            .map { unescape(String($0.output.1)) }
        let names = try entry("xl/workbook.xml").matches(of: #/<sheet name="([^"]*)"/#)
            .map { unescape(String($0.output.1)) }
        return try names.enumerated().map { index, name in
            Tab(name: name, rows: grid(try entry("xl/worksheets/sheet\(index + 1).xml"), shared))
        }
    }

    private static func grid(_ xml: String, _ shared: [String]) -> [[Cell]] {
        var cells: [Int: [Int: Cell]] = [:]
        let pattern = #/(?s)<c r="([A-Z]+)(\d+)"([^>]*?)(?:/>|>(.*?)</c>)/#
        for match in xml.matches(of: pattern) {
            let attrs = String(match.output.3)
            let body = match.output.4.map(String.init) ?? ""
            let value = body.firstMatch(of: #/(?s)<v>(.*?)</v>/#).map { String($0.output.1) }
            let inline = body.firstMatch(of: #/(?s)<t[^>]*>(.*?)</t>/#).map { String($0.output.1) }
            let cell: Cell
            if attrs.contains("t=\"s\""), let value, let index = Int(value) {
                cell = .text(shared[index])
            } else if attrs.contains("t=\"inlineStr\"") {
                cell = .text(unescape(inline ?? ""))
            } else if attrs.contains("t=\"b\""), let value {
                cell = .bool(value == "1")
            } else if let value, let number = Double(value) {
                cell = .number(number)
            } else {
                cell = .blank
            }
            let column = String(match.output.1).unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
            cells[(Int(match.output.2) ?? 1) - 1, default: [:]][column] = cell
        }
        guard let lastRow = cells.keys.max() else { return [] }
        let width = (cells.values.flatMap(\.keys).max() ?? 0) + 1
        return (0...lastRow).map { row in (0..<width).map { cells[row]?[$0] ?? .blank } }
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
