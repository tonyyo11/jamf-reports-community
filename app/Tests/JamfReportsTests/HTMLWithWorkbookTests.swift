import Foundation
import XCTest
@testable import JamfReports

// `html.with_workbook`: the HTML report written beside every report workbook by the one shared
// step, `ReportEngine.writeHTMLWithWorkbook`, from each path that writes a workbook: the engine
// itself, the GUI generate (`CLIBridge`), the included CLI's `generate` and a scheduled run.

// MARK: - Fixture

/// A workspace under a temporary root that `ProfileService` resolves, with no snapshots: the
/// workbook and the HTML report still render, from the sections that need no data.
private struct HTMLWorkbookFixture {
    let root: URL
    let profile = "htmlwb"
    var workspace: URL { root.appendingPathComponent(profile, isDirectory: true) }
    /// Where `WorkspacePaths.reportsDir` puts a report with no `output_dir` set.
    var reports: URL { workspace.appendingPathComponent("Generated Reports", isDirectory: true) }

    func writeConfig(_ yaml: String) throws {
        try yaml.write(to: workspace.appendingPathComponent("config.yaml"),
                       atomically: true, encoding: .utf8)
    }

    func engine(config yaml: String) throws -> ReportEngine {
        try writeConfig(yaml)
        return ReportEngine(
            config: try ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml")),
            dataDir: workspace.appendingPathComponent("jamf-cli-data"))
    }

    func files(in folder: URL? = nil, ending suffix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: (folder ?? reports).path)) ?? [])
            .filter { $0.hasSuffix(suffix) }.sorted()
    }

    /// The report files of one run: the workbook and HTML names without extension.
    func stems(in folder: URL? = nil) -> (workbooks: [String], pages: [String]) {
        (files(in: folder, ending: ".xlsx").map { String($0.dropLast(5)) },
         files(in: folder, ending: ".html").map { String($0.dropLast(5)) })
    }
}

/// Runs `body` against a fresh workspace, with `JRC_TEST_WORKSPACES_ROOT` pointing at it for
/// the duration, so nothing reads or writes the real ~/Jamf-Reports.
private func withHTMLWorkbookFixture(
    isolation: isolated (any Actor)? = #isolation,
    _ body: (HTMLWorkbookFixture) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("jrc-html-wb-\(UUID().uuidString)", isDirectory: true)
    let fixture = HTMLWorkbookFixture(root: root)
    try FileManager.default.createDirectory(
        at: fixture.workspace, withIntermediateDirectories: true)
    let saved = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
    setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    defer {
        if let saved { setenv("JRC_TEST_WORKSPACES_ROOT", saved, 1) }
        else { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        try? FileManager.default.removeItem(at: root)
    }
    try await body(fixture)
}

private final class HTMLWorkbookLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: CLIBridge.LogLine) { lock.lock(); stored.append(line.text); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

private let withWorkbookOn = "html:\n  with_workbook: true\n"

// MARK: - The shared step

final class HTMLWithWorkbookTests: XCTestCase {

    func testAGenerateWithTheOptionOnLeavesOneHTMLBesideTheWorkbookWithItsName() async throws {
        try await withHTMLWorkbookFixture { fixture in
            let engine = try fixture.engine(config: withWorkbookOn)
            let lines = HTMLWorkbookLines()
            let workbook = engine.resolveOutputURL(stem: "report", profile: fixture.profile)
            try await engine.generate(csvURL: nil, outputURL: workbook, locateJamfCLI: { nil })
            let page = await engine.writeHTMLWithWorkbook(
                besideWorkbook: workbook, template: FullInstanceTemplate(), onLine: lines.add)

            XCTAssertEqual(page, workbook.deletingPathExtension().appendingPathExtension("html"))
            let stems = fixture.stems()
            XCTAssertEqual(stems.workbooks.count, 1)
            XCTAssertEqual(stems.pages, stems.workbooks, "one HTML, named as the workbook is")
            let html = try String(contentsOf: try XCTUnwrap(page), encoding: .utf8)
            XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
            let name = page?.lastPathComponent ?? ""
            XCTAssertTrue(lines.all.contains("[ok] HTML report written: \(name)"), "\(lines.all)")
            let fingerprints = lines.all.filter {
                $0.hasPrefix("[ok] sha256: ") && $0.hasSuffix(".html")
            }
            XCTAssertEqual(fingerprints.count, 1, "the integrity line the sheet and the toast read")
        }
    }

    func testTheOptionOffOrAbsentOrMistypedWritesNoHTML() async throws {
        for yaml in ["columns:\n  computer_name: Name\n", "html:\n  with_workbook: false\n",
                     "html:\n  track_history: true\n", "html:\n  with_workbook: maybe\n"] {
            try await withHTMLWorkbookFixture { fixture in
                let engine = try fixture.engine(config: yaml)
                let workbook = engine.resolveOutputURL(stem: "report", profile: fixture.profile)
                try await engine.generate(csvURL: nil, outputURL: workbook, locateJamfCLI: { nil })
                let page = await engine.writeHTMLWithWorkbook(
                    besideWorkbook: workbook, template: FullInstanceTemplate())

                XCTAssertNil(page, yaml)
                XCTAssertEqual(fixture.files(ending: ".html"), [], yaml)
                XCTAssertEqual(fixture.files(ending: ".xlsx").count, 1, yaml)
            }
        }
    }

    /// The workbook is on disk when the step runs. A failure is one `[warn]` line: `[partial]`
    /// would make Run History read the run as Partial and the tick retry a run no retry fixes.
    func testAnHTMLFailureLeavesTheWorkbookAndWarnsOnceWithoutPartial() async throws {
        try await withHTMLWorkbookFixture { fixture in
            let engine = try fixture.engine(
                config: "output:\n  timestamp_outputs: false\n" + withWorkbookOn)
            let workbook = engine.resolveOutputURL(stem: "report", profile: fixture.profile)
            let blocked = workbook.deletingPathExtension().appendingPathExtension("html")
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: blocked.appendingPathComponent("held"))
            let lines = HTMLWorkbookLines()
            try await engine.generate(csvURL: nil, outputURL: workbook, locateJamfCLI: { nil })

            let page = await engine.writeHTMLWithWorkbook(
                besideWorkbook: workbook, template: FullInstanceTemplate(), onLine: lines.add)

            XCTAssertNil(page)
            XCTAssertTrue(FileManager.default.fileExists(atPath: workbook.path))
            let marker = ReportEngine.htmlWithWorkbookFailureMarker
            let warnings = lines.all.filter { $0.hasPrefix(marker) }
            XCTAssertEqual(warnings.count, 1, "\(lines.all)")
            XCTAssertEqual(warnings.first.map { $0.hasPrefix("[warn] HTML report not written: ") },
                           true)
            XCTAssertFalse(lines.all.contains { $0.contains("[partial]") }, "\(lines.all)")
            XCTAssertFalse(lines.all.contains { $0.hasPrefix("[ok] HTML report written") })
        }
    }

    /// The HTML takes the workbook's template: the Executive sections, not the Operational ones.
    func testTheHTMLHasTheSectionsOfTheTemplateTheWorkbookUsed() async throws {
        try await withHTMLWorkbookFixture { fixture in
            let engine = try fixture.engine(config: withWorkbookOn)
            var pages: [String: String] = [:]
            for template in [ExecutiveTemplate() as any ReportTemplate, OperationalTemplate()] {
                let workbook = fixture.reports.appendingPathComponent(
                    "\(template.identifier).xlsx")
                let page = await engine.writeHTMLWithWorkbook(
                    besideWorkbook: workbook, template: template)
                pages[template.identifier] = try String(
                    contentsOf: try XCTUnwrap(page), encoding: .utf8)
            }
            let executive = try XCTUnwrap(pages["executive"])
            let operational = try XCTUnwrap(pages["operational"])
            XCTAssertTrue(executive.contains("id=\"exec-summary\""))
            XCTAssertFalse(executive.contains("id=\"patch-queue\""))
            XCTAssertTrue(operational.contains("id=\"patch-queue\""))
            XCTAssertFalse(operational.contains("id=\"exec-summary\""))
        }
    }

    /// The GUI's one narrative goes into the workbook and into this HTML report.
    func testTheNarrativeReachesTheHTML() async throws {
        try await withHTMLWorkbookFixture { fixture in
            let engine = try fixture.engine(config: withWorkbookOn)
            let page = await engine.writeHTMLWithWorkbook(
                besideWorkbook: fixture.reports.appendingPathComponent("n.xlsx"),
                template: ExecutiveTemplate(), aiNarrative: "Narrative marker 7731.")
            let html = try String(contentsOf: try XCTUnwrap(page), encoding: .utf8)
            XCTAssertTrue(html.contains("Narrative marker 7731."))
        }
    }

    func testTheHTMLNameIsTheWorkbooksNameWithAnHTMLExtension() {
        let folder = URL(fileURLWithPath: "/tmp/reports")
        XCTAssertEqual(
            ReportEngine.htmlURL(besideWorkbook: folder.appendingPathComponent("report_a.b.xlsx")),
            folder.appendingPathComponent("report_a.b.html"))
        XCTAssertEqual(
            ReportEngine.htmlURL(besideWorkbook: folder.appendingPathComponent("noext")),
            folder.appendingPathComponent("noext.html"))
    }
}

// MARK: - GUI generate (CLIBridge)

@MainActor
final class HTMLWithWorkbookGUITests: XCTestCase {

    func testGenerateAllOfTheWorkbookAlsoWritesTheHTML() async throws {
        try await withHTMLWorkbookFixture { fixture in
            try fixture.writeConfig(withWorkbookOn)
            let lines = HTMLWorkbookLines()
            let result = await CLIBridge().generateAll(
                types: [.xlsx], outputDir: nil, profile: fixture.profile, onLine: lines.add)

            XCTAssertEqual(result.succeeded, [.xlsx], "\(lines.all)")
            let stems = fixture.stems()
            XCTAssertEqual(stems.workbooks.count, 1, "\(lines.all)")
            XCTAssertEqual(stems.pages, stems.workbooks)
            XCTAssertTrue(try XCTUnwrap(stems.pages.first).hasPrefix("report_htmlwb_"))
        }
    }

    func testTheOptionOffLeavesTheWorkbookAlone() async throws {
        try await withHTMLWorkbookFixture { fixture in
            try fixture.writeConfig("html:\n  with_workbook: false\n")
            let result = await CLIBridge().generateAll(
                types: [.xlsx], outputDir: nil, profile: fixture.profile,
                onLine: CLIBridge.noOpOnLine)
            XCTAssertEqual(result.succeeded, [.xlsx])
            XCTAssertEqual(fixture.files(ending: ".xlsx").count, 1)
            XCTAssertEqual(fixture.files(ending: ".html"), [])
        }
    }

    /// The Generate sheet with HTML ticked: that HTML is the run's one, so the option does not
    /// write a second.
    func testAChosenHTMLFormatIsTheRunsOnlyHTML() async throws {
        try await withHTMLWorkbookFixture { fixture in
            try fixture.writeConfig(withWorkbookOn)
            let lines = HTMLWorkbookLines()
            let result = await CLIBridge().generateAll(
                types: [.xlsx, .html], outputDir: nil, profile: fixture.profile,
                onLine: lines.add)

            XCTAssertEqual(Set(result.succeeded), [.xlsx, .html], "\(lines.all)")
            let pages = fixture.files(ending: ".html")
            XCTAssertEqual(pages.count, 1, "\(pages)")
            XCTAssertTrue(try XCTUnwrap(pages.first).hasPrefix("jamf_report_htmlwb_"),
                          "the HTML format's own name: \(pages)")
        }
    }

    func testAnHTMLOnlyRunWritesOneHTMLAndNoWorkbook() async throws {
        try await withHTMLWorkbookFixture { fixture in
            try fixture.writeConfig(withWorkbookOn)
            let result = await CLIBridge().generateAll(
                types: [.html], outputDir: nil, profile: fixture.profile,
                onLine: CLIBridge.noOpOnLine)
            XCTAssertEqual(result.succeeded, [.html])
            XCTAssertEqual(fixture.files(ending: ".html").count, 1)
            XCTAssertEqual(fixture.files(ending: ".xlsx"), [])
        }
    }

    /// The Generate sheet's folder picker: both files go where the workbook goes.
    func testAFolderChosenOnTheSheetReceivesBothFiles() async throws {
        try await withHTMLWorkbookFixture { fixture in
            try fixture.writeConfig(withWorkbookOn)
            let picked = fixture.root.appendingPathComponent("picked", isDirectory: true)
            try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
            let result = await CLIBridge().generateAll(
                types: [.xlsx], outputDir: picked, profile: fixture.profile,
                onLine: CLIBridge.noOpOnLine)

            XCTAssertEqual(result.succeeded, [.xlsx])
            let stems = fixture.stems(in: picked)
            XCTAssertEqual(stems.workbooks.count, 1)
            XCTAssertEqual(stems.pages, stems.workbooks)
            XCTAssertEqual(fixture.files(ending: ".html"), [], "nothing in the default folder")
        }
    }

    /// Onboarding's first generate and the Overview call `generate` directly.
    func testGenerateWritesTheHTMLUnlessTheCallerWritesItsOwn() async throws {
        try await withHTMLWorkbookFixture { fixture in
            try fixture.writeConfig(withWorkbookOn)
            let bridge = CLIBridge()
            let first = try await bridge.generate(
                profile: fixture.profile, csvPath: nil, onLine: CLIBridge.noOpOnLine)
            XCTAssertEqual(first, 0)
            XCTAssertEqual(fixture.files(ending: ".html").count, 1)

            let other = fixture.root.appendingPathComponent("other", isDirectory: true)
            let second = try await bridge.generate(
                profile: fixture.profile, csvPath: nil, outputDir: other,
                htmlWithWorkbook: false, onLine: CLIBridge.noOpOnLine)
            XCTAssertEqual(second, 0)
            XCTAssertEqual(fixture.files(in: other, ending: ".xlsx").count, 1)
            XCTAssertEqual(fixture.files(in: other, ending: ".html"), [])
        }
    }

    func testAnHTMLFailureLeavesTheGenerateSucceededAndTheLogHonest() async throws {
        try await withHTMLWorkbookFixture { fixture in
            try fixture.writeConfig("output:\n  timestamp_outputs: false\n" + withWorkbookOn)
            let blocked = fixture.reports.appendingPathComponent("report_htmlwb.html")
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: blocked.appendingPathComponent("held"))
            let lines = HTMLWorkbookLines()

            let result = await CLIBridge().generateAll(
                types: [.xlsx], outputDir: nil, profile: fixture.profile, onLine: lines.add)

            XCTAssertTrue(result.allSucceeded, "the workbook's result stands: \(lines.all)")
            XCTAssertEqual(result.succeeded, [.xlsx])
            XCTAssertEqual(fixture.files(ending: ".xlsx"), ["report_htmlwb.xlsx"])
            XCTAssertEqual(
                lines.all.filter { $0.hasPrefix("[warn] HTML report not written: ") }.count, 1,
                "\(lines.all)")
            XCTAssertFalse(lines.all.contains { $0.contains("[partial]") })
        }
    }
}

// MARK: - The included CLI and a scheduled run

final class HTMLWithWorkbookHeadlessTests: XCTestCase {

    func testTheCLIGenerateWritesTheHTMLToo() async throws {
        try await withHTMLWorkbookFixture { fixture in
            try fixture.writeConfig(withWorkbookOn)
            try await Generate.parse(["--profile", fixture.profile]).run()

            let stems = fixture.stems()
            XCTAssertEqual(stems.workbooks.count, 1)
            XCTAssertEqual(stems.pages, stems.workbooks)
        }
    }

    func testTheCLIGenerateWithTheOptionOffWritesTheWorkbookOnly() async throws {
        try await withHTMLWorkbookFixture { fixture in
            try fixture.writeConfig("columns:\n  computer_name: Name\n")
            try await Generate.parse(["--profile", fixture.profile]).run()
            XCTAssertEqual(fixture.files(ending: ".xlsx").count, 1)
            XCTAssertEqual(fixture.files(ending: ".html"), [])
        }
    }

    /// `jamf-reports html` is its own command and writes one HTML either way.
    func testTheHTMLCommandIsUnaffected() async throws {
        try await withHTMLWorkbookFixture { fixture in
            try fixture.writeConfig(withWorkbookOn)
            try await Html.parse(["--profile", fixture.profile]).run()
            XCTAssertEqual(fixture.files(ending: ".html").count, 1)
            XCTAssertEqual(fixture.files(ending: ".xlsx"), [])
        }
    }

    /// A scheduled generate-from-cache run, through the same `runSchedule` the background item
    /// and an external scheduler call.
    func testAScheduledRunWritesTheHTMLAndRecordsItAsAnArtifact() async throws {
        try await withHTMLWorkbookFixture { fixture in
            try fixture.writeConfig(withWorkbookOn)
            let outcome = await runSchedule(Self.schedule(for: fixture.profile), verbose: false)

            XCTAssertEqual(outcome.exitCode, 0)
            XCTAssertFalse(outcome.incomplete)
            let stems = fixture.stems()
            XCTAssertEqual(stems.workbooks.count, 1)
            XCTAssertEqual(stems.pages, stems.workbooks)
            let status = try Self.statusPayload(in: fixture.workspace)
            XCTAssertEqual((status["xlsx_report_path"] as? String).map(URL.init(fileURLWithPath:))?
                .lastPathComponent, (stems.workbooks.first ?? "") + ".xlsx")
            XCTAssertEqual((status["html_report_path"] as? String).map(URL.init(fileURLWithPath:))?
                .lastPathComponent, (stems.pages.first ?? "") + ".html")
        }
    }

    func testAScheduledRunWithTheOptionOffWritesNoHTML() async throws {
        try await withHTMLWorkbookFixture { fixture in
            try fixture.writeConfig("columns:\n  computer_name: Name\n")
            let outcome = await runSchedule(Self.schedule(for: fixture.profile), verbose: false)
            XCTAssertEqual(outcome.exitCode, 0)
            XCTAssertEqual(fixture.files(ending: ".xlsx").count, 1)
            XCTAssertEqual(fixture.files(ending: ".html"), [])
            XCTAssertNil(try Self.statusPayload(in: fixture.workspace)["html_report_path"])
        }
    }

    /// The run succeeded and is not Partial: the workbook is there and no retry could write the
    /// HTML. The reason is in the run's own log.
    func testAScheduledRunWhoseHTMLFailsStillSucceedsAndIsNotPartial() async throws {
        try await withHTMLWorkbookFixture { fixture in
            try fixture.writeConfig("output:\n  timestamp_outputs: false\n" + withWorkbookOn)
            let blocked = fixture.reports.appendingPathComponent("report_htmlwb.html")
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: blocked.appendingPathComponent("held"))

            let outcome = await runSchedule(Self.schedule(for: fixture.profile), verbose: false)

            XCTAssertEqual(outcome.exitCode, 0)
            XCTAssertFalse(outcome.incomplete, "a [warn] line does not read as Partial")
            XCTAssertEqual(fixture.files(ending: ".xlsx"), ["report_htmlwb.xlsx"])
            let status = try Self.statusPayload(in: fixture.workspace)
            XCTAssertEqual(status["success"] as? Bool, true)
            XCTAssertNil(status["html_report_path"])
            let log = try Self.runLog(in: fixture.workspace)
            XCTAssertEqual(
                log.components(separatedBy: "\n")
                    .filter { $0.hasPrefix("[warn] HTML report not written: ") }.count, 1, log)
            XCTAssertFalse(log.contains("[partial]"), log)
        }
    }

    // MARK: Helpers

    private static func schedule(for profile: String) -> Schedule {
        Schedule(
            name: "html-with-workbook", profile: profile, schedule: "manual", cadence: "custom",
            mode: .jamfCLIOnly, next: "—", last: "—", lastStatus: .ok, artifacts: [],
            enabled: true, launchAgentLabel: nil, multiTarget: nil, tiers: nil,
            excludedProfiles: nil)
    }

    private static func statusPayload(in workspace: URL) throws -> [String: Any] {
        let automation = workspace.appendingPathComponent("automation", isDirectory: true)
        let status = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: automation.path)
                .first { $0.hasSuffix("_status.json") }, "no status file in automation/")
        let data = try Data(contentsOf: automation.appendingPathComponent(status))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func runLog(in workspace: URL) throws -> String {
        let logs = workspace.appendingPathComponent("automation/logs", isDirectory: true)
        let name = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: logs.path)
                .first { $0.hasSuffix(".log") }, "no run log in automation/logs/")
        return try String(contentsOf: logs.appendingPathComponent(name), encoding: .utf8)
    }
}
