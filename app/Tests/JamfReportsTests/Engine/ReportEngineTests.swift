import Foundation
import XCTest
import CryptoKit
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

    // MARK: - PR-10 / threat-model T-11: strict-manifest pre-flight

    /// `jamf_cli.require_manifest: true` + a tampered snapshot must abort
    /// the whole generate run with `snapshotIntegrityViolation`, not just
    /// skip the affected sheet. Closes the GUI false-promise gap where the
    /// "Require snapshot manifest" toggle previously had no effect on the
    /// Swift engine path.
    func testGenerateAbortsOnSnapshotMismatchWhenRequireManifestEnabled() async throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-mismatch-\(UUID().uuidString)")
        let auditDir = dataDir.appendingPathComponent("audit", isDirectory: true)
        try FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let snapshot = auditDir.appendingPathComponent("audit_20260101T000000.json")
        let originalData = Data(#"{"ok":true}"#.utf8)
        try originalData.write(to: snapshot)

        // Manifest pinned to original hash; we then overwrite the snapshot
        // to simulate tampering between collect (manifest write) and generate.
        let originalHash = SHA256.hash(data: originalData)
            .map { String(format: "%02x", $0) }.joined()
        let manifest = auditDir.appendingPathComponent(SnapshotManifest.fileName)
        let manifestPayload: [String: Any] = [
            "algorithm": "sha256",
            "files": [snapshot.lastPathComponent: originalHash],
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifestPayload, options: [.sortedKeys]
        )
        try manifestData.write(to: manifest)
        try Data(#"{"ok":false}"#.utf8).write(to: snapshot)

        var config = ReportConfig()
        var jamfCLI = JamfCLIConfig()
        jamfCLI.requireManifest = true
        config.jamfCli = jamfCLI

        let engine = ReportEngine(config: config, dataDir: dataDir)
        let outURL = dataDir.appendingPathComponent("out.xlsx")

        do {
            try await engine.generate(csvURL: nil, outputURL: outURL)
            XCTFail("Expected snapshotIntegrityViolation, generate returned cleanly")
        } catch let ReportEngineError.snapshotIntegrityViolation(summary, _) {
            XCTAssertEqual(summary.mismatch, 1)
            XCTAssertEqual(summary.corrupt, 0)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outURL.path),
                       "Workbook must not be written when pre-flight aborts")
    }

    /// `.absent` and `.omitted` results must NOT trip strict mode — they
    /// represent legacy snapshots and partial collects that can't be
    /// retroactively verified. Only `.mismatch` and `.corrupt` should abort.
    func testGeneratePermitsAbsentManifestEvenWhenRequireManifestEnabled() async throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-absent-\(UUID().uuidString)")
        let auditDir = dataDir.appendingPathComponent("audit", isDirectory: true)
        try FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        // Snapshot with no sibling manifest — `.absent`, the legacy case.
        let snapshot = auditDir.appendingPathComponent("audit_20260101T000000.json")
        try Data(#"{"ok":true}"#.utf8).write(to: snapshot)

        var config = ReportConfig()
        var jamfCLI = JamfCLIConfig()
        jamfCLI.requireManifest = true
        config.jamfCli = jamfCLI

        let engine = ReportEngine(config: config, dataDir: dataDir)
        let outURL = dataDir.appendingPathComponent("out.xlsx")

        // Should NOT throw snapshotIntegrityViolation. May skip sheets due
        // to schema mismatch — the test goal is "didn't pre-flight-abort."
        try await engine.generate(csvURL: nil, outputURL: outURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path),
                      "Workbook should be written when only .absent results exist")
    }

    /// HTML generation (a primary GUI entry point) must also enforce the
    /// pre-flight. Catches the security-reviewer 2nd-review M-01 finding
    /// where `generateHTML` was originally exempt from strict-mode checks.
    func testGenerateHTMLAbortsOnSnapshotMismatchWhenRequireManifestEnabled() async throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-html-\(UUID().uuidString)")
        let auditDir = dataDir.appendingPathComponent("audit", isDirectory: true)
        try FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let snapshot = auditDir.appendingPathComponent("audit_20260101T000000.json")
        let originalData = Data(#"{"ok":true}"#.utf8)
        try originalData.write(to: snapshot)
        let originalHash = SHA256.hash(data: originalData)
            .map { String(format: "%02x", $0) }.joined()
        let manifest = auditDir.appendingPathComponent(SnapshotManifest.fileName)
        try JSONSerialization.data(withJSONObject: [
            "algorithm": "sha256",
            "files": [snapshot.lastPathComponent: originalHash],
        ], options: [.sortedKeys]).write(to: manifest)
        try Data(#"{"ok":false}"#.utf8).write(to: snapshot)

        var config = ReportConfig()
        var jamfCLI = JamfCLIConfig()
        jamfCLI.requireManifest = true
        config.jamfCli = jamfCLI

        let outURL = dataDir.appendingPathComponent("out.html")

        do {
            try await ReportEngine.generateHTML(
                config: config, dataDir: dataDir, outputURL: outURL
            )
            XCTFail("Expected snapshotIntegrityViolation, generateHTML returned cleanly")
        } catch ReportEngineError.snapshotIntegrityViolation { /* expected */ }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outURL.path),
                       "HTML must not be written when pre-flight aborts")
    }

    /// schoolGenerate must enforce strict-mode pre-flight too — school
    /// snapshots share the same workspace data dir and manifest discipline.
    func testGenerateSchoolAbortsOnSnapshotMismatchWhenRequireManifestEnabled() async throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-school-\(UUID().uuidString)")
        let auditDir = dataDir.appendingPathComponent("audit", isDirectory: true)
        try FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let snapshot = auditDir.appendingPathComponent("audit_20260101T000000.json")
        let originalData = Data(#"{"ok":true}"#.utf8)
        try originalData.write(to: snapshot)
        let originalHash = SHA256.hash(data: originalData)
            .map { String(format: "%02x", $0) }.joined()
        let manifest = auditDir.appendingPathComponent(SnapshotManifest.fileName)
        try JSONSerialization.data(withJSONObject: [
            "algorithm": "sha256",
            "files": [snapshot.lastPathComponent: originalHash],
        ], options: [.sortedKeys]).write(to: manifest)
        try Data(#"{"ok":false}"#.utf8).write(to: snapshot)

        var config = ReportConfig()
        var jamfCLI = JamfCLIConfig()
        jamfCLI.requireManifest = true
        config.jamfCli = jamfCLI

        let outURL = dataDir.appendingPathComponent("out.xlsx")

        do {
            _ = try await ReportEngine.schoolGenerate(
                config: config, csvURL: nil, dataDir: dataDir, outputURL: outURL
            )
            XCTFail("Expected snapshotIntegrityViolation, schoolGenerate returned cleanly")
        } catch ReportEngineError.snapshotIntegrityViolation { /* expected */ }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outURL.path),
                       "School workbook must not be written when pre-flight aborts")
    }

    /// Pre-flight must be a no-op when `require_manifest: false` (the
    /// default). Same tampered setup as the strict-mode test, but
    /// permissive config — generate must complete and write the workbook.
    func testGeneratePermitsMismatchWhenRequireManifestDisabled() async throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-permissive-\(UUID().uuidString)")
        let auditDir = dataDir.appendingPathComponent("audit", isDirectory: true)
        try FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let snapshot = auditDir.appendingPathComponent("audit_20260101T000000.json")
        let originalData = Data(#"{"ok":true}"#.utf8)
        try originalData.write(to: snapshot)
        let originalHash = SHA256.hash(data: originalData)
            .map { String(format: "%02x", $0) }.joined()
        let manifest = auditDir.appendingPathComponent(SnapshotManifest.fileName)
        let manifestPayload: [String: Any] = [
            "algorithm": "sha256",
            "files": [snapshot.lastPathComponent: originalHash],
        ]
        try JSONSerialization.data(withJSONObject: manifestPayload, options: [.sortedKeys])
            .write(to: manifest)
        try Data(#"{"ok":false}"#.utf8).write(to: snapshot)

        // Default config — require_manifest is false / unset.
        let config = ReportConfig()
        let engine = ReportEngine(config: config, dataDir: dataDir)
        let outURL = dataDir.appendingPathComponent("out.xlsx")

        try await engine.generate(csvURL: nil, outputURL: outURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path),
                      "Permissive mode must not abort on mismatch")
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

    // MARK: - PR-18: emitSummaryJSON logging surfaces silent early-return paths

    /// When a same-day `summary_*.json` already exists and is valid,
    /// `emitSummaryJSON` correctly leaves it in place — but the prior silent
    /// behavior left operators wondering why Refresh wasn't clearing the
    /// StaleDataBanner. The fix emits a `[info]` line so the reason is visible
    /// in Run logs.
    func testEmitSummaryJSONLogsInfoWhenSameDaySummaryAlreadyExists() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emit-summary-skip-\(UUID().uuidString)")
        let summariesDir = dataDir.appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        // Seed today's summary so emit will short-circuit.
        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        let existing = summariesDir.appendingPathComponent("summary_\(today).json")
        let payload: [String: Any] = [
            "date": today, "totalDevices": 42, "source": "jamf-cli",
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: existing)

        let engine = ReportEngine(config: ReportConfig(), dataDir: dataDir)
        let captured = LogCapture()
        engine.emitSummaryJSON(summariesDir: summariesDir) { line in
            captured.append(line)
        }

        let lines = captured.snapshot()
        XCTAssertTrue(
            lines.contains { $0.level == .info && $0.text.contains("already exists") },
            "Expected an [info] log line explaining the same-day skip; got: \(lines.map(\.text))"
        )
    }

    /// When no cached jamf-cli snapshots exist, `buildSummaryFromCLI` returns
    /// nil and no summary file is written. PR-18 surfaces a `[warn]` log line
    /// so operators understand why Generate succeeded but didn't refresh
    /// the trend chart or StaleDataBanner.
    func testEmitSummaryJSONLogsWarnWhenNoSnapshotsAvailable() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emit-summary-empty-\(UUID().uuidString)")
        let summariesDir = dataDir.appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        // dataDir contains NO jamf-cli snapshot dirs — buildSummaryFromCLI
        // will return nil because every kind comes back empty.
        let engine = ReportEngine(config: ReportConfig(), dataDir: dataDir)
        let captured = LogCapture()
        engine.emitSummaryJSON(summariesDir: summariesDir) { line in
            captured.append(line)
        }

        let lines = captured.snapshot()
        XCTAssertTrue(
            lines.contains { $0.level == .warn && $0.text.contains("no jamf-cli snapshots") },
            "Expected a [warn] log line explaining no snapshots to summarize; got: \(lines.map(\.text))"
        )

        // No file should have been written.
        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        let summaryFile = summariesDir.appendingPathComponent("summary_\(today).json")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: summaryFile.path),
            "No summary file should be written when there are no snapshots to summarize"
        )
    }

    // MARK: - Helpers

    /// Thread-safe collector for `@Sendable` log-line closures so Swift 6
    /// strict concurrency lets us aggregate emitted lines under a single
    /// captured reference.
    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [CLIBridge.LogLine] = []

        func append(_ line: CLIBridge.LogLine) {
            lock.lock(); defer { lock.unlock() }
            lines.append(line)
        }

        func snapshot() -> [CLIBridge.LogLine] {
            lock.lock(); defer { lock.unlock() }
            return lines
        }
    }

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
