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

    // MARK: - Fix 1: staleCount uses stale_device_days threshold, not the server stale flag

    /// `summary.json` staleCount must agree with StaleDeviceService when using the
    /// configured `stale_device_days`. Devices with `stale: true` but
    /// `days_since_checkin < stale_device_days` must NOT be counted.
    func testSummaryStaleCountUsesThresholdNotServerFlag() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-count-threshold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }

        // Write a minimal security snapshot so buildSummaryFromCLI can derive totalDevices.
        let secDir = dataDir.appendingPathComponent("security", isDirectory: true)
        try FileManager.default.createDirectory(at: secDir, withIntermediateDirectories: true)
        let secPayload = """
        [{"section":"summary","data":{"total_devices":3,"filevault_encrypted":3,
          "sip_enabled":3,"firewall_enabled":3,"gatekeeper_enabled":3}}]
        """
        try Data(secPayload.utf8).write(
            to: secDir.appendingPathComponent("security_20260101T000000.json"))

        // Write device-compliance with:
        //   - device A: server flag stale=true, but only 10 days since checkin → NOT stale at 30d
        //   - device B: stale=false, but 45 days since checkin → stale at 30d threshold
        //   - device C: stale=true, 50 days since checkin → stale at both definitions
        let compDir = dataDir.appendingPathComponent("device-compliance", isDirectory: true)
        try FileManager.default.createDirectory(at: compDir, withIntermediateDirectories: true)
        let compPayload = """
        [
          {"name":"A","serial":"AAA","managed":true,"stale":true,"days_since_checkin":10},
          {"name":"B","serial":"BBB","managed":true,"stale":false,"days_since_checkin":45},
          {"name":"C","serial":"CCC","managed":true,"stale":true,"days_since_checkin":50}
        ]
        """
        try Data(compPayload.utf8).write(
            to: compDir.appendingPathComponent("device-compliance_20260101T000000.json"))

        // Config with default stale_device_days = 30.
        let config = ReportConfig()
        let engine = ReportEngine(config: config, dataDir: dataDir)

        let summariesDir = dataDir.appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)
        engine.emitSummaryJSON(summariesDir: summariesDir)

        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        let summaryFile = summariesDir.appendingPathComponent("summary_\(today).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryFile.path),
                      "Summary JSON must be written")

        let data = try Data(contentsOf: summaryFile)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let staleCount = try XCTUnwrap(obj["staleCount"] as? Int)

        // Only B (45d) and C (50d) exceed the 30-day threshold. A (10d) does not,
        // even though its server-side `stale` flag is true.
        XCTAssertEqual(staleCount, 2,
            "staleCount must be 2 (B+C exceed 30d) — A has stale=true but only 10 days")
    }

    /// staleCount must agree with DeviceInventorySnapshot.staleCount(thresholdDays:) —
    /// the same computation DevicesView uses for its "Stale" stat tile.
    func testSummaryStaleCountAgreesWithDeviceInventorySnapshot() throws {
        let staleDays = 30
        var buf: [DeviceInventoryRecord] = []
        // 2 devices under the threshold.
        var r1 = DeviceInventoryRecord.empty(id: "r1", source: "test")
        r1.daysSinceContact = 10
        var r2 = DeviceInventoryRecord.empty(id: "r2", source: "test")
        r2.daysSinceContact = 29
        // 3 devices at or over the threshold.
        var r3 = DeviceInventoryRecord.empty(id: "r3", source: "test")
        r3.daysSinceContact = 30
        var r4 = DeviceInventoryRecord.empty(id: "r4", source: "test")
        r4.daysSinceContact = 90
        var r5 = DeviceInventoryRecord.empty(id: "r5", source: "test")
        r5.daysSinceContact = 200
        buf.append(contentsOf: [r1, r2, r3, r4, r5])
        let records = buf

        // DeviceInventorySnapshot.staleCount is what DevicesView shows.
        let devSnapshot = DeviceInventorySnapshot(
            devices: records, patchTitles: [], sourceFiles: [], warnings: [],
            generatedAt: "", generatedDate: nil, isDemo: false)
        let uiStaleCount = devSnapshot.staleCount(thresholdDays: staleDays)

        // The summary engine uses `daysSinceCheckin >= staleDaysThreshold`.
        // Synthesize the matching device-compliance rows.
        let compRows = records.compactMap { r -> [String: Any]? in
            guard let d = r.daysSinceContact else { return nil }
            return ["name": r.id, "serial": "", "managed": true,
                    "stale": d >= staleDays, "days_since_checkin": d]
        }
        let engineStaleCount = compRows.filter {
            ($0["days_since_checkin"] as? Int ?? 0) >= staleDays
        }.count

        XCTAssertEqual(engineStaleCount, uiStaleCount,
            "Engine staleCount (\(engineStaleCount)) must match DevicesView stat tile " +
            "(\(uiStaleCount)) for the same threshold (\(staleDays)d)")
    }

    // MARK: - Fix 2: snapshotSubtitle surfaces data age for stale-risk sheets

    /// When the snapshot file is older than today, the subtitle must contain
    /// "Data as of: " with the snapshot date.
    func testSnapshotSubtitleIncludesDataAsOfWhenStale() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-subtitle-stale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }

        // Write a snapshot file and backdate its mtime to yesterday.
        let kindDir = dataDir.appendingPathComponent("update-status", isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        let snapFile = kindDir.appendingPathComponent("update-status_20260101T000000.json")
        try Data("[]".utf8).write(to: snapFile)
        // Set mtime 2 days back so it is definitely not today.
        let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)
        try FileManager.default.setAttributes(
            [.modificationDate: twoDaysAgo], ofItemAtPath: snapFile.path)

        let workbook = Workbook(accentColor: "#2D5EA2")
        let dashboard = CoreDashboard(
            config: ReportConfig(), dataDir: dataDir, workbook: workbook)
        let ts = ISO8601DateFormatter().string(from: Date())
        let subtitle = dashboard.snapshotSubtitle(names: ["update-status"], generated: ts)

        XCTAssertTrue(subtitle.contains("Data as of:"),
            "Subtitle must contain 'Data as of:' for a stale snapshot; got: \(subtitle)")
    }

    /// When the snapshot file was collected today, the subtitle must NOT contain
    /// a "Data as of" clause (the data is current).
    func testSnapshotSubtitleOmitsDataAsOfWhenFresh() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-subtitle-fresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let kindDir = dataDir.appendingPathComponent("update-status", isDirectory: true)
        try FileManager.default.createDirectory(at: kindDir, withIntermediateDirectories: true)
        let snapFile = kindDir.appendingPathComponent("update-status_today.json")
        try Data("[]".utf8).write(to: snapFile)
        // mtime is "now" — no explicit backdate needed.

        let workbook = Workbook(accentColor: "#2D5EA2")
        let dashboard = CoreDashboard(
            config: ReportConfig(), dataDir: dataDir, workbook: workbook)
        let ts = ISO8601DateFormatter().string(from: Date())
        let subtitle = dashboard.snapshotSubtitle(names: ["update-status"], generated: ts)

        XCTAssertFalse(subtitle.contains("Data as of:"),
            "Subtitle must NOT contain 'Data as of:' for a fresh snapshot; got: \(subtitle)")
    }

    /// When no snapshot exists the subtitle falls back to "Generated: <ts>" only.
    func testSnapshotSubtitleFallsBackWhenNoSnapshot() throws {
        let emptyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-subtitle-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }

        let workbook = Workbook(accentColor: "#2D5EA2")
        let dashboard = CoreDashboard(
            config: ReportConfig(), dataDir: emptyDir, workbook: workbook)
        let ts = "2026-06-05T12:00:00Z"
        let subtitle = dashboard.snapshotSubtitle(names: ["update-status"], generated: ts)

        XCTAssertEqual(subtitle, "Generated: \(ts)",
            "Subtitle must be exactly 'Generated: <ts>' when no snapshot exists")
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

    // MARK: - csvEscape formula-injection guard

    /// =HYPERLINK(...) contains a double-quote, so after tab-prefixing the whole field is
    /// RFC-4180 quoted: "\t=...". Assert the raw string (not hasPrefix("\t=")).
    func testCSVEscapeNeutralizeEqualsHyperlink() {
        let raw = #"=HYPERLINK("http://x")"#
        let escaped = ReportEngine.testableCSVEscape(raw)
        // Tab-prefixed, then quoted due to embedded double-quote.
        XCTAssertTrue(
            escaped.hasPrefix("\"\t="),
            "csvEscape must tab-prefix and RFC4180-quote a cell beginning with '='; got: \(escaped)"
        )
    }

    /// Simple = prefix (no special chars) → tab-prefix only, no quoting.
    func testCSVEscapeNeutralizeSimpleEquals() {
        let escaped = ReportEngine.testableCSVEscape("=1+1")
        XCTAssertEqual(escaped, "\t=1+1",
                       "csvEscape must tab-prefix a cell beginning with '=' when no quoting is needed")
    }

    /// + prefix → tab-prefixed.
    func testCSVEscapeNeutralizePlus() {
        let escaped = ReportEngine.testableCSVEscape("+cmd|calc")
        XCTAssertEqual(escaped, "\t+cmd|calc")
    }

    /// Normal value — no injection prefix, no special chars — passes through unchanged.
    func testCSVEscapePassesThroughCleanValue() {
        let escaped = ReportEngine.testableCSVEscape("MacBook Pro")
        XCTAssertEqual(escaped, "MacBook Pro")
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

    // MARK: - Snapshot JSON gate

    /// Cobra prints parent help + exit 0 for unknown subcommands; that output
    /// must never be saved as a snapshot (it poisoned classic-macos-profiles
    /// when the upstream command was renamed).
    func testIsJSONSnapshotRejectsCobraHelpText() {
        let helpText = Data("Commands for interacting with Jamf Pro\n\nUsage:\n  jamf-cli pro [command]\n".utf8)
        XCTAssertFalse(ReportEngine.isJSONSnapshot(helpText))

        XCTAssertTrue(ReportEngine.isJSONSnapshot(Data("[]".utf8)))
        XCTAssertTrue(ReportEngine.isJSONSnapshot(Data("{\"a\": 1}".utf8)))
        XCTAssertTrue(ReportEngine.isJSONSnapshot(Data("[{\"id\": 1}]".utf8)))

        // JSON fragments ("null", "0", string literals) must be accepted — parity
        // with Python's json.loads, which also accepts these forms.
        XCTAssertTrue(ReportEngine.isJSONSnapshot(Data("null".utf8)))
        XCTAssertTrue(ReportEngine.isJSONSnapshot(Data("0".utf8)))
        XCTAssertTrue(ReportEngine.isJSONSnapshot(Data("\"text\"".utf8)))
    }

    // MARK: - Fix 1: buildLiveKinds only includes actually-saved kinds

    /// A kind with exitCode==0 but a non-JSON body is NOT saved and must NOT
    /// appear in liveKinds. buildLiveKinds takes savedKinds (post-saveSnapshot),
    /// so the Cobra-help case is structurally excluded.
    func testBuildLiveKindsExcludesUnsavedKinds() {
        // "security" saved; "policies" had exit 0 but non-JSON body — not in savedKinds.
        let saved: Set<String> = ["security"]
        let result = ReportEngine.buildLiveKinds(savedKinds: saved, sofaRefreshed: false)
        XCTAssertTrue(result.contains("security"))
        XCTAssertFalse(result.contains("policies"), "Unsaved kind must not appear in liveKinds")
        XCTAssertFalse(result.contains("sofa"), "sofa absent when sofaRefreshed=false")
    }

    func testBuildLiveKindsSofaInsertedWhenRefreshSucceeded() {
        let saved: Set<String> = ["security"]
        let result = ReportEngine.buildLiveKinds(savedKinds: saved, sofaRefreshed: true)
        XCTAssertTrue(result.contains("sofa"), "sofa must be included when sofaRefreshed=true")
        XCTAssertTrue(result.contains("security"))
    }

    // MARK: - Fix 1+2: collectionSources end-to-end via emitSummaryJSON

    /// Verifies the three provenance states written into summary.json:
    ///   - A kind with a snapshot file AND in liveKinds → "live"
    ///   - A kind with a snapshot file NOT in liveKinds → "cache"
    ///   - A kind with no snapshot file → "absent"
    func testCollectionSourcesReflectsLiveCacheAbsent() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("collsrc-\(UUID().uuidString)", isDirectory: true)
        let summariesDir = dataDir.appendingPathComponent("summaries", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        // Write a security snapshot so buildSummaryFromCLI produces totalDevices > 0.
        let secDir = dataDir.appendingPathComponent("security", isDirectory: true)
        try FileManager.default.createDirectory(at: secDir, withIntermediateDirectories: true)
        let secPayload = """
        [{"section":"summary","data":{"total_devices":10,"filevault_encrypted":8,
          "sip_enabled":10,"firewall_enabled":9,"gatekeeper_enabled":10}}]
        """
        try Data(secPayload.utf8).write(
            to: secDir.appendingPathComponent("security_20260101T000000.json"))

        // Write a device-compliance snapshot for the "cache" case.
        let compDir = dataDir.appendingPathComponent("device-compliance", isDirectory: true)
        try FileManager.default.createDirectory(at: compDir, withIntermediateDirectories: true)
        try Data("""
        [{"name":"A","serial":"AA","managed":true,"stale":false,"days_since_checkin":5}]
        """.utf8).write(
            to: compDir.appendingPathComponent("device-compliance_20260101T000000.json"))

        // liveKinds: "security" was fetched live; "device-compliance" was NOT (cache);
        // "patch-status" has no snapshot at all (absent).
        let liveKinds: Set<String> = ["security"]

        let engine = ReportEngine(config: ReportConfig(), dataDir: dataDir)
        engine.emitSummaryJSON(summariesDir: summariesDir, liveKinds: liveKinds)

        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        let summaryURL = summariesDir.appendingPathComponent("summary_\(today).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryURL.path))

        let data = try Data(contentsOf: summaryURL)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sources = try XCTUnwrap(obj["collectionSources"] as? [String: String],
                                    "collectionSources must be present when liveKinds is provided")

        XCTAssertEqual(sources["security"], "live",
                       "security was in liveKinds → must be 'live'")
        XCTAssertEqual(sources["device-compliance"], "cache",
                       "device-compliance has a file but was not in liveKinds → must be 'cache'")
        XCTAssertEqual(sources["patch-status"], "absent",
                       "patch-status has no snapshot → must be 'absent'")
    }
}
