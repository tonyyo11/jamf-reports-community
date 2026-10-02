import Foundation
import XCTest
import ZIPFoundation
@testable import JamfReports

/// `branding.accent_color` reaches the workbook and the HTML report as one validated value:
/// the typed colour when it is #RGB or #RRGGBB, otherwise the default #2D5EA2.
final class AccentColourTests: XCTestCase {

    func testAnAccentColourThatIsNotHexLeavesTheStylesPartWellFormed() async throws {
        try await withScratch { scratch in
            let config = try ConfigLoader.loadFromString(
                "branding:\n  accent_color: 'red\"/><x'\n")
            XCTAssertEqual(config.branding?.accentColor, "red\"/><x", "the value as typed")
            for styles in try await stylesParts(config, in: scratch) {
                XCTAssertTrue(XMLParser(data: Data(styles.utf8)).parse(),
                              "styles.xml must stay well-formed")
                XCTAssertTrue(styles.contains("rgb=\"FF2D5EA2\""), "the default accent")
            }
        }
    }

    func testBothReportsUseTheSameValidatedAccentColour() async throws {
        let cases: [(typed: String, workbook: String, html: String)] = [
            ("#ABC", "FFAABBCC", "#ABC"),
            ("#1f6f8b", "FF1F6F8B", "#1f6f8b"),
            ("#12345", "FF2D5EA2", "#2D5EA2"),
            ("#2D5EA2FF", "FF2D5EA2", "#2D5EA2"),
            ("blue", "FF2D5EA2", "#2D5EA2"),
        ]
        try await withScratch { scratch in
            for (typed, workbook, html) in cases {
                let config = try branded(typed)
                for styles in try await stylesParts(config, in: scratch) {
                    XCTAssertTrue(styles.contains("<fgColor rgb=\"\(workbook)\"/>"),
                                  "\(typed): the workbook header fill")
                }
                let page = scratch.appendingPathComponent("report-\(UUID().uuidString).html")
                try await ReportEngine.generateHTML(
                    config: config, dataDir: scratch, outputURL: page)
                let text = try String(contentsOf: page, encoding: .utf8)
                XCTAssertTrue(text.contains("--accent: \(html);"), "\(typed): the HTML accent")
            }
        }
    }

    // MARK: - Helpers

    private func branded(_ colour: String) throws -> ReportConfig {
        try ConfigLoader.loadFromString("branding:\n  accent_color: \"\(colour)\"\n")
    }

    /// `xl/styles.xml` of the workbook each engine entry writes: generate and school-generate.
    private func stylesParts(_ config: ReportConfig, in scratch: URL) async throws -> [String] {
        let pro = scratch.appendingPathComponent("pro-\(UUID().uuidString).xlsx")
        try await ReportEngine(config: config, dataDir: scratch)
            .generate(csvURL: nil, outputURL: pro, template: ComplianceTemplate())
        let school = scratch.appendingPathComponent("school-\(UUID().uuidString).xlsx")
        try await ReportEngine.schoolGenerate(
            config: config, csvURL: nil, dataDir: scratch, outputURL: school)
        return try [pro, school].map { url in
            let archive = try Archive(url: url, accessMode: .read)
            let entry = try XCTUnwrap(archive["xl/styles.xml"])
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// A scratch folder that is also the workspaces root and an empty data folder.
    private func withScratch(_ body: (URL) async throws -> Void) async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-accent-\(UUID().uuidString)", isDirectory: true)
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
