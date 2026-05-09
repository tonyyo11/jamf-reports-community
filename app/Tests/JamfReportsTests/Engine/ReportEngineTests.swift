import Foundation
import XCTest
@testable import JamfReports

final class ReportEngineTests: XCTestCase {

    // MARK: - resolveOutputURL

    func testResolveOutputURLAddsTimestampWhenEnabled() {
        var config = ReportConfig()
        config.output = OutputConfig()
        config.output?.outputDir = "/tmp/reports"
        config.output?.timestampOutputs = true

        let engine = ReportEngine(config: config, dataDir: URL(fileURLWithPath: "/tmp"))
        let url = engine.resolveOutputURL(stem: "JamfReport")

        XCTAssertTrue(url.lastPathComponent.hasPrefix("JamfReport_"))
        XCTAssertTrue(url.pathExtension == "xlsx")
    }

    func testResolveOutputURLNoTimestampWhenDisabled() {
        var config = ReportConfig()
        config.output = OutputConfig()
        config.output?.outputDir = "/tmp/reports"
        config.output?.timestampOutputs = false

        let engine = ReportEngine(config: config, dataDir: URL(fileURLWithPath: "/tmp"))
        let url = engine.resolveOutputURL(stem: "JamfReport")

        XCTAssertEqual(url.lastPathComponent, "JamfReport.xlsx")
    }

    func testResolveOutputURLUsesDefaultDirWhenUnset() {
        let config = ReportConfig()
        let engine = ReportEngine(config: config, dataDir: URL(fileURLWithPath: "/tmp"))
        let url = engine.resolveOutputURL(stem: "test")

        // Without explicit output_dir, path should contain "Generated Reports".
        XCTAssertTrue(url.path.contains("Generated Reports"))
    }

    // MARK: - generate() — no cached data, no CSV → throws

    func testGenerateProducesDiagnosticWorkbookWhenNoCachedDataAndNoCSV() async throws {
        // Behavior change post-Cover-sheet: a workbook with only the always-on
        // Cover and Compliance Posture sheets is more diagnostic than a hard
        // failure — it dates the run and explains what would have been there.
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let config = ReportConfig()
        let engine = ReportEngine(config: config, dataDir: emptyDir)
        let outURL = emptyDir.appendingPathComponent("out.xlsx")

        try await engine.generate(csvURL: nil, outputURL: outURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path),
                      "Workbook with Cover sheet should be produced even without data")
    }

    // MARK: - generate() — CSV-only path

    func testGenerateWithDummyCSVProducesXLSXFile() async throws {
        let fixtureCSV = fixturesDir.appendingPathComponent("csv/dummy_all_macs.csv")
        let fixtureConfig = fixturesDir.appendingPathComponent("config/dummy.yaml")

        guard FileManager.default.fileExists(atPath: fixtureCSV.path),
              FileManager.default.fileExists(atPath: fixtureConfig.path) else {
            throw XCTSkip("Fixtures not available")
        }

        var config = try ConfigLoader.load(from: fixtureConfig)
        config = config.withDefaults()

        let emptyDataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-jamf-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyDataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDataDir) }

        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("report-out-\(UUID().uuidString)")
        let outURL = outDir.appendingPathComponent("test.xlsx")
        defer { try? FileManager.default.removeItem(at: outDir) }

        let engine = ReportEngine(config: config, dataDir: emptyDataDir)
        // CSV-only: no CoreDashboard data, but should succeed because CSV provides sheets.
        try await engine.generate(csvURL: fixtureCSV, outputURL: outURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        let data = try Data(contentsOf: outURL)
        // XLSX = ZIP = starts with PK magic bytes.
        XCTAssertEqual(data.prefix(2), Data([0x50, 0x4B]))
    }

    // MARK: - generate() — invalid CSV throws

    func testGenerateWithMalformedCSVThrows() async {
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        // Write a CSV with no header row (empty).
        let badCSV = emptyDir.appendingPathComponent("bad.csv")
        try? Data().write(to: badCSV)

        let engine = ReportEngine(config: ReportConfig(), dataDir: emptyDir)
        let outURL = emptyDir.appendingPathComponent("out.xlsx")

        do {
            try await engine.generate(csvURL: badCSV, outputURL: outURL)
            XCTFail("Expected csvParseFailed error")
        } catch ReportEngineError.csvParseFailed {
            // Expected.
        } catch {
            // Any error from empty CSV is acceptable.
        }
    }

    // MARK: - Helper

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Engine/
            .deletingLastPathComponent()   // JamfReportsTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // app/
            .deletingLastPathComponent()   // worktree root
            .appendingPathComponent("tests/fixtures")
    }
}
