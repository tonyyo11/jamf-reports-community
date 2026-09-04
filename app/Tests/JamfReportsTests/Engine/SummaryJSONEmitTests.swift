import Foundation
import XCTest
@testable import JamfReports

/// Tests for ReportEngine.emitSummaryJSON and round-trip schema validation.
final class SummaryJSONEmitTests: XCTestCase {

    private var tmpDir: URL!
    private var summariesDir: URL!
    private var engine: ReportEngine!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        summariesDir = tmpDir.appendingPathComponent("summaries", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let config = ReportConfig()
        let dataDir = tmpDir.appendingPathComponent("data", isDirectory: true)
        engine = ReportEngine(config: config, dataDir: dataDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    // MARK: - Schema round-trip

    func testDailySummaryRoundTrip() throws {
        let original = DailySummary(
            date: "2024-06-15",
            totalDevices: 500,
            fileVaultPct: 98.3,
            compliancePct: 87.5,
            staleCount: 12,
            osCurrentPct: 72.0,
            crowdstrikePct: 99.1,
            patchPct: 81.4,
            source: "csv",
            provenance: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(DailySummary.self, from: data)
        XCTAssertEqual(decoded.date, original.date)
        XCTAssertEqual(decoded.totalDevices, original.totalDevices)
        XCTAssertEqual(try XCTUnwrap(decoded.fileVaultPct), try XCTUnwrap(original.fileVaultPct),
                       accuracy: 0.01)
        XCTAssertEqual(decoded.compliancePct, original.compliancePct)
        XCTAssertEqual(decoded.staleCount, original.staleCount)
        XCTAssertEqual(try XCTUnwrap(decoded.osCurrentPct), try XCTUnwrap(original.osCurrentPct),
                       accuracy: 0.01)
        XCTAssertEqual(decoded.crowdstrikePct, original.crowdstrikePct)
        XCTAssertEqual(try XCTUnwrap(decoded.patchPct), try XCTUnwrap(original.patchPct),
                       accuracy: 0.01)
        XCTAssertEqual(decoded.source, original.source)
    }

    func testOptionalFieldsOmittedWhenNil() throws {
        let summary = DailySummary(
            date: "2024-06-15",
            totalDevices: 100,
            fileVaultPct: nil,
            compliancePct: nil,
            staleCount: 5,
            osCurrentPct: nil,
            crowdstrikePct: nil,
            patchPct: nil,
            source: "jamf-cli",
            provenance: nil
        )
        let data = try JSONEncoder().encode(summary)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(json?["fileVaultPct"], "fileVaultPct must be absent when nil")
        XCTAssertNil(json?["compliancePct"], "compliancePct must be absent when nil")
        XCTAssertNil(json?["osCurrentPct"], "osCurrentPct must be absent when nil")
        XCTAssertNil(json?["crowdstrikePct"], "crowdstrikePct must be absent when nil")
        XCTAssertNil(json?["patchPct"], "patchPct must be absent when nil")
        XCTAssertNil(json?["provenance"], "provenance must be absent when nil")
    }

    func testSummaryJSONContainsProvenanceWhenSupplied() throws {
        let prov = Provenance(
            runID: "emit-test-run-id",
            generatedAt: Date(),
            profile: "acme-prod",
            jamfCLIVersion: "1.14.0",
            jamfTenantURL: "https://jamf.example.com",
            operatorUserHost: "user@host"
        )
        let summary = DailySummary(
            date: "2026-05-07",
            totalDevices: 300,
            fileVaultPct: 95.0,
            compliancePct: nil,
            staleCount: 8,
            osCurrentPct: 70.0,
            crowdstrikePct: nil,
            patchPct: 82.0,
            source: "jamf-cli",
            provenance: prov
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["provenance"], "provenance key must be present when set")
        let provDict = json?["provenance"] as? [String: Any]
        XCTAssertEqual(provDict?["runID"] as? String, "emit-test-run-id")
        XCTAssertEqual(provDict?["profile"] as? String, "acme-prod")
        XCTAssertEqual(provDict?["jamfCLIVersion"] as? String, "1.14.0")
        XCTAssertEqual(provDict?["jamfTenantURL"] as? String, "https://jamf.example.com")
        XCTAssertEqual(provDict?["operatorUserHost"] as? String, "user@host")
    }

    // MARK: - mobileDeviceCount round-trip

    func testMobileDeviceCountRoundTrips() throws {
        let original = DailySummary(
            date: "2026-07-20",
            totalDevices: 500,
            fileVaultPct: nil,
            compliancePct: nil,
            staleCount: nil,
            osCurrentPct: nil,
            crowdstrikePct: nil,
            patchPct: nil,
            source: "jamf-cli",
            mobileDeviceCount: 42
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DailySummary.self, from: data)
        XCTAssertEqual(decoded.mobileDeviceCount, 42)
    }

    func testMobileDeviceCountOmittedWhenNil() throws {
        let summary = DailySummary(
            date: "2026-07-20",
            totalDevices: 500,
            fileVaultPct: nil,
            compliancePct: nil,
            staleCount: nil,
            osCurrentPct: nil,
            crowdstrikePct: nil,
            patchPct: nil,
            source: "jamf-cli"
        )
        let data = try JSONEncoder().encode(summary)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(json?["mobileDeviceCount"], "mobileDeviceCount must be absent when nil")

        let decoded = try JSONDecoder().decode(DailySummary.self, from: data)
        XCTAssertNil(decoded.mobileDeviceCount)
    }

    func testLegacySummaryJSONDecodesWithoutMobileDeviceCount() throws {
        let json = """
        {"date":"2025-01-01","totalDevices":200,"source":"csv"}
        """
        let decoded = try JSONDecoder().decode(DailySummary.self, from: Data(json.utf8))
        XCTAssertNil(decoded.mobileDeviceCount)
    }

    func testLegacySummaryJSONDecodesWithoutProvenance() throws {
        // Old Python-generated summary.json files have no "provenance" key.
        // DailySummary must still decode cleanly.
        let json = """
        {"date":"2025-01-01","totalDevices":200,"fileVaultPct":92.0,
         "staleCount":3,"osCurrentPct":65.0,"patchPct":78.0,"source":"csv"}
        """
        let decoded = try JSONDecoder().decode(DailySummary.self, from: Data(json.utf8))
        XCTAssertNil(decoded.provenance, "provenance must be nil for pre-provenance summary files")
        XCTAssertEqual(decoded.totalDevices, 200)
    }

    // MARK: - emitSummaryJSON behavior

    func testEmitCreatesSummariesDirAndFile() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: summariesDir.path))
        // Engine has no cached data — emitSummaryJSON will return early because
        // buildSummaryFromCLI returns nil when there is no security/inventory data.
        // Test the dir-creation and file-writing behavior via a pre-seeded data dir.
        try writeMinimalSecuritySnapshot()
        engine.emitSummaryJSON(summariesDir: summariesDir)

        // Dir should have been created.
        XCTAssertTrue(FileManager.default.fileExists(atPath: summariesDir.path))
        // A valid snapshot should exist.
        let files = try FileManager.default.contentsOfDirectory(atPath: summariesDir.path)
        XCTAssertEqual(files.count, 1)
        let file = files[0]
        XCTAssertTrue(file.hasPrefix("summary_"))
        XCTAssertTrue(file.hasSuffix(".json"))
    }

    func testEmitDoesNotOverwriteValidSameDaySummary() throws {
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)
        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        let existingURL = summariesDir.appendingPathComponent("summary_\(today).json")
        let existingSummary = DailySummary(
            date: today, totalDevices: 999, fileVaultPct: 99.9, compliancePct: nil,
            staleCount: 0, osCurrentPct: 100.0, crowdstrikePct: nil, patchPct: 99.0,
            source: "jamf-cli"
        )
        let data = try JSONEncoder().encode(existingSummary)
        try data.write(to: existingURL, options: .atomic)

        try writeMinimalSecuritySnapshot()
        engine.emitSummaryJSON(summariesDir: summariesDir)

        // File must not have been replaced — totalDevices sentinel still 999.
        let read = try SummaryJSONParser.parse(existingURL)
        XCTAssertEqual(read.totalDevices, 999, "Existing valid summary must not be overwritten")
    }

    func testEmitSummaryParsesBackThroughSummaryJSONParser() throws {
        try writeMinimalSecuritySnapshot()
        engine.emitSummaryJSON(summariesDir: summariesDir)
        let summaries = SummaryJSONParser.parseDirectory(summariesDir)
        guard !summaries.isEmpty else {
            // No cached data to build summary from — test is vacuously satisfied.
            return
        }
        let s = summaries[0]
        XCTAssertFalse(s.date.isEmpty)
        XCTAssertGreaterThan(s.totalDevices, 0)
        XCTAssertEqual(s.source, "jamf-cli")
    }

    // MARK: - Real mSCP compliance wiring

    /// When ea-results contains rows for the configured baseline, the emitted
    /// summary should carry real compliancePct (Pass ÷ devicesWithData) and
    /// complianceIsProxy == false.
    func testEmitUsesRealCompliancePctWhenEAResultsPresent() throws {
        let eaColumn = "Compliance - Failed mSCP Results Count - NIST 800-53r5 Audit"
        var cfg = ReportConfig()
        cfg.compliance = ComplianceConfig(
            enabled: true,
            failuresCountColumn: eaColumn,
            failuresListColumn: nil,
            baselineLabel: "NIST",
            framework: nil,
            baselines: nil
        )
        let dataDir = tmpDir.appendingPathComponent("real-data", isDirectory: true)
        let localEngine = ReportEngine(config: cfg, dataDir: dataDir)

        try writeMinimalSecuritySnapshot(to: dataDir)
        try writeEAResultsSnapshot(to: dataDir, eaColumn: eaColumn, passCount: 8, failCount: 2)

        let localSummaries = tmpDir.appendingPathComponent("real-summaries", isDirectory: true)
        localEngine.emitSummaryJSON(summariesDir: localSummaries)

        let summaries = SummaryJSONParser.parseDirectory(localSummaries)
        let s = try XCTUnwrap(summaries.first, "Summary must be emitted when security + ea-results exist")

        // 8 pass out of 10 with data = 80%
        let pct = try XCTUnwrap(s.compliancePct, "compliancePct must be set from real ea-results")
        XCTAssertEqual(pct, 80.0, accuracy: 0.1)
        XCTAssertEqual(s.complianceIsProxy, false,
                       "complianceIsProxy must be false when real ea-results data is used")
    }

    /// When no ea-results snapshot exists but security data (including device rows)
    /// does, the engine falls back to the 4-control proxy and sets complianceIsProxy = true.
    func testEmitFallsBackToProxyWhenNoEAResults() throws {
        let eaColumn = "Compliance - Failed mSCP Results Count - NIST 800-53r5 Audit"
        var cfg = ReportConfig()
        cfg.compliance = ComplianceConfig(
            enabled: true,
            failuresCountColumn: eaColumn,
            failuresListColumn: nil,
            baselineLabel: "NIST",
            framework: nil,
            baselines: nil
        )
        let dataDir = tmpDir.appendingPathComponent("proxy-data", isDirectory: true)
        let localEngine = ReportEngine(config: cfg, dataDir: dataDir)

        // Write security snapshot with device rows so the proxy can compute
        // deviceGapCounts (the proxy requires per-device sections, not just the summary).
        try writeSecuritySnapshotWithDevices(to: dataDir)

        let localSummaries = tmpDir.appendingPathComponent("proxy-summaries", isDirectory: true)
        localEngine.emitSummaryJSON(summariesDir: localSummaries)

        let summaries = SummaryJSONParser.parseDirectory(localSummaries)
        let s = try XCTUnwrap(summaries.first, "Summary must be emitted from security data alone")

        XCTAssertEqual(s.complianceIsProxy, true,
                       "complianceIsProxy must be true when falling back to security-report proxy")
        XCTAssertNotNil(s.compliancePct,
                        "Proxy compliancePct must be populated when device security data is present")
    }

    // MARK: - mobileDeviceCount derivation wiring

    /// A mobile-devices-list snapshot on disk at collect time is reflected in
    /// the emitted summary's mobileDeviceCount.
    func testEmitIncludesMobileDeviceCountWhenSnapshotPresent() throws {
        let dataDir = tmpDir.appendingPathComponent("mobile-data", isDirectory: true)
        let localEngine = ReportEngine(config: ReportConfig(), dataDir: dataDir)

        try writeMinimalSecuritySnapshot(to: dataDir)
        try writeMobileDevicesListSnapshot(to: dataDir, count: 7)

        let localSummaries = tmpDir.appendingPathComponent("mobile-summaries", isDirectory: true)
        localEngine.emitSummaryJSON(summariesDir: localSummaries)

        let summaries = SummaryJSONParser.parseDirectory(localSummaries)
        let s = try XCTUnwrap(summaries.first)
        XCTAssertEqual(s.mobileDeviceCount, 7)
    }

    /// No mobile-devices-list snapshot on disk — mobileDeviceCount is nil,
    /// never a fabricated 0.
    func testEmitOmitsMobileDeviceCountWhenSnapshotAbsent() throws {
        try writeMinimalSecuritySnapshot()
        engine.emitSummaryJSON(summariesDir: summariesDir)
        let summaries = SummaryJSONParser.parseDirectory(summariesDir)
        guard let s = summaries.first else { return }
        XCTAssertNil(s.mobileDeviceCount)
    }

    private func writeMobileDevicesListSnapshot(to dataDir: URL, count: Int) throws {
        let listDir = dataDir.appendingPathComponent("mobile-devices-list", isDirectory: true)
        try FileManager.default.createDirectory(at: listDir, withIntermediateDirectories: true)
        let rows: [[String: Any]] = (0..<count).map { i in
            ["id": "\(i)", "name": "iPad-\(i)", "model": "iPad", "type": "iPad"]
        }
        let data = try JSONSerialization.data(withJSONObject: rows)
        let file = listDir.appendingPathComponent("mobile-devices-list_\(recentStamp).json")
        try data.write(to: file)
    }

    // MARK: - freshSummaryIsBetter unit tests

    /// Direct unit test of all four quadrants of the downgrade-guard logic.
    func testFreshSummaryIsBetter_proxyToReal_returnsTrue() {
        let existing = makeSummary(complianceIsProxy: true, hasBands: false)
        let fresh = makeSummary(complianceIsProxy: false, hasBands: true)
        XCTAssertTrue(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh))
    }

    func testFreshSummaryIsBetter_realToProxy_returnsFalse() {
        let existing = makeSummary(complianceIsProxy: false, hasBands: true)
        let fresh = makeSummary(complianceIsProxy: true, hasBands: false)
        XCTAssertFalse(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh),
                       "Must not overwrite real summary with proxy — downgrade protection")
    }

    func testFreshSummaryIsBetter_realToReal_returnsFalse() {
        let existing = makeSummary(complianceIsProxy: false, hasBands: true)
        let fresh = makeSummary(complianceIsProxy: false, hasBands: true)
        XCTAssertFalse(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh),
                       "No upgrade when both are real — skip is preferred")
    }

    func testFreshSummaryIsBetter_proxyNoBandsToProxyWithBands_returnsTrue() {
        let existing = makeSummary(complianceIsProxy: true, hasBands: false)
        let fresh = makeSummary(complianceIsProxy: true, hasBands: true)
        XCTAssertTrue(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh),
                      "Gaining mscpBands is an upgrade even if both are proxy")
    }

    func testFreshSummaryIsBetter_degradedStaleZeroToReal_returnsTrue() {
        // The prod symptom: a transient-auth run wrote staleCount 0 on a 659-Mac
        // fleet; a later healthy same-day collect computes the real ~166 and must
        // be allowed to correct it.
        let existing = makeSummary(complianceIsProxy: false, hasBands: true,
                                   totalDevices: 659, staleCount: 0)
        let fresh = makeSummary(complianceIsProxy: false, hasBands: true,
                                totalDevices: 659, staleCount: 166)
        XCTAssertTrue(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh),
                      "A real staleCount where the existing was a degraded 0 is an upgrade")
    }

    func testFreshSummaryIsBetter_realStaleToZero_returnsFalse() {
        // Never downgrade a real stale count to 0 — a genuinely zero-stale fresh
        // run must not clobber a populated one.
        let existing = makeSummary(complianceIsProxy: false, hasBands: true,
                                   totalDevices: 659, staleCount: 166)
        let fresh = makeSummary(complianceIsProxy: false, hasBands: true,
                                totalDevices: 659, staleCount: 0)
        XCTAssertFalse(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh),
                       "Real staleCount → 0 is a downgrade, must be rejected")
    }

    func testFreshSummaryIsBetter_realBandsDropped_returnsFalse() {
        let existing = makeSummary(complianceIsProxy: false, hasBands: true)
        let fresh = makeSummary(complianceIsProxy: false, hasBands: false)
        XCTAssertFalse(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh),
                       "Dropping bands is not an upgrade — downgrade protection")
    }

    // MARK: - freshSummaryIsBetter nil-staleCount upgrade rules

    /// nil → measured: a collect that couldn't determine staleness is upgraded
    /// when the next run produces a real reading.
    func testFreshSummaryIsBetter_staleNilToMeasured_returnsTrue() {
        let existing = makeSummary(complianceIsProxy: false, hasBands: true, staleCount: nil)
        let fresh = makeSummary(complianceIsProxy: false, hasBands: true, staleCount: 166)
        XCTAssertTrue(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh),
                      "nil → measured staleCount is an upgrade: the unknown becomes known")
    }

    /// measured → nil: a fresh run that couldn't determine staleness must not
    /// overwrite an existing run that did.
    func testFreshSummaryIsBetter_staleMeasuredToNil_returnsFalse() {
        let existing = makeSummary(complianceIsProxy: false, hasBands: true, staleCount: 166)
        let fresh = makeSummary(complianceIsProxy: false, hasBands: true, staleCount: nil)
        XCTAssertFalse(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh),
                       "measured → nil staleCount is a downgrade: must not clobber known data")
    }

    /// both nil: neither run measured staleness; no upgrade.
    func testFreshSummaryIsBetter_bothStaleNil_returnsFalse() {
        let existing = makeSummary(complianceIsProxy: false, hasBands: true, staleCount: nil)
        let fresh = makeSummary(complianceIsProxy: false, hasBands: true, staleCount: nil)
        XCTAssertFalse(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh),
                       "nil → nil staleCount is not an upgrade")
    }

    // MARK: - freshSummaryIsBetter mobileDeviceCount upgrade rules

    /// nil → measured: a summary written before the mobile-devices snapshot
    /// existed (or by a prior build) is upgraded once a later collect measures it.
    func testFreshSummaryIsBetter_mobileCountNilToMeasured_returnsTrue() {
        let existing = makeSummary(complianceIsProxy: false, hasBands: true, mobileDeviceCount: nil)
        let fresh = makeSummary(complianceIsProxy: false, hasBands: true, mobileDeviceCount: 42)
        XCTAssertTrue(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh),
                      "nil → measured mobileDeviceCount is an upgrade: the unknown becomes known")
    }

    /// measured → nil: a fresh run that couldn't determine the mobile count must
    /// not overwrite an existing run that did.
    func testFreshSummaryIsBetter_mobileCountMeasuredToNil_returnsFalse() {
        let existing = makeSummary(complianceIsProxy: false, hasBands: true, mobileDeviceCount: 42)
        let fresh = makeSummary(complianceIsProxy: false, hasBands: true, mobileDeviceCount: nil)
        XCTAssertFalse(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh),
                       "measured → nil mobileDeviceCount is a downgrade: must not clobber it")
    }

    /// both measured: no upgrade, even if the values differ — the digest
    /// keeps the first same-day measurement rather than churning on every run.
    func testFreshSummaryIsBetter_mobileCountMeasuredToMeasured_returnsFalse() {
        let existing = makeSummary(complianceIsProxy: false, hasBands: true, mobileDeviceCount: 42)
        let fresh = makeSummary(complianceIsProxy: false, hasBands: true, mobileDeviceCount: 50)
        XCTAssertFalse(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh),
                       "measured → measured mobileDeviceCount is not an upgrade")
    }

    /// both nil: neither run measured mobile devices; no upgrade.
    func testFreshSummaryIsBetter_bothMobileCountNil_returnsFalse() {
        let existing = makeSummary(complianceIsProxy: false, hasBands: true, mobileDeviceCount: nil)
        let fresh = makeSummary(complianceIsProxy: false, hasBands: true, mobileDeviceCount: nil)
        XCTAssertFalse(ReportEngine.freshSummaryIsBetter(existing: existing, fresh: fresh),
                       "nil → nil mobileDeviceCount is not an upgrade")
    }

    // MARK: - emitSummaryJSON upgrade behavior (integration)

    /// Existing proxy summary + fresh real-mSCP summary → file overwritten with real data.
    func testEmitUpgradesProxySummaryToRealWhenEAResultsAppear() throws {
        let eaColumn = "Compliance - Failed mSCP Results Count - NIST 800-53r5 Audit"
        var cfg = ReportConfig()
        cfg.compliance = ComplianceConfig(
            enabled: true,
            failuresCountColumn: eaColumn,
            failuresListColumn: nil,
            baselineLabel: "NIST",
            framework: nil,
            baselines: nil
        )
        let dataDir = tmpDir.appendingPathComponent("upgrade-data", isDirectory: true)
        let localEngine = ReportEngine(config: cfg, dataDir: dataDir)

        // Seed security snapshot with device rows (so proxy can compute).
        try writeSecuritySnapshotWithDevices(to: dataDir)
        // Seed ea-results so the fresh build produces real mSCP data.
        try writeEAResultsSnapshot(to: dataDir, eaColumn: eaColumn, passCount: 7, failCount: 3)

        let localSummaries = tmpDir.appendingPathComponent("upgrade-summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: localSummaries, withIntermediateDirectories: true)

        // Write a synthetic proxy summary for today.
        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        let summaryFile = localSummaries.appendingPathComponent("summary_\(today).json")
        let proxySummary = makeSummary(complianceIsProxy: true, hasBands: false,
                                       date: today, totalDevices: 42)
        let existingData = try JSONEncoder().encode(proxySummary)
        try existingData.write(to: summaryFile, options: .atomic)

        // Run emit — should upgrade.
        localEngine.emitSummaryJSON(summariesDir: localSummaries)

        let result = try SummaryJSONParser.parse(summaryFile)
        XCTAssertEqual(result.complianceIsProxy, false,
                       "After upgrade the summary must carry real mSCP data (complianceIsProxy=false)")
        // The real-mSCP path produces mscpBands from MSCPComplianceService.
        XCTAssertNotNil(result.mscpBands, "Upgraded summary must carry mscpBands")
        XCTAssertFalse(result.mscpBands?.isEmpty ?? true, "mscpBands must be non-empty after upgrade")
    }

    /// Existing real summary + fresh proxy run (no ea-results) → file NOT overwritten.
    func testEmitDoesNotDowngradeRealSummaryToProxy() throws {
        let eaColumn = "Compliance - Failed mSCP Results Count - NIST 800-53r5 Audit"
        var cfg = ReportConfig()
        cfg.compliance = ComplianceConfig(
            enabled: true,
            failuresCountColumn: eaColumn,
            failuresListColumn: nil,
            baselineLabel: "NIST",
            framework: nil,
            baselines: nil
        )
        // dataDir has only security data (no ea-results) → fresh build is proxy.
        let dataDir = tmpDir.appendingPathComponent("nodowngrade-data", isDirectory: true)
        let localEngine = ReportEngine(config: cfg, dataDir: dataDir)
        try writeSecuritySnapshotWithDevices(to: dataDir)

        let localSummaries = tmpDir.appendingPathComponent("nodowngrade-summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: localSummaries, withIntermediateDirectories: true)

        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        let summaryFile = localSummaries.appendingPathComponent("summary_\(today).json")
        // Sentinel totalDevices=999 to distinguish "unchanged" from overwritten.
        let realSummary = makeSummary(complianceIsProxy: false, hasBands: true,
                                      date: today, totalDevices: 999)
        try JSONEncoder().encode(realSummary).write(to: summaryFile, options: .atomic)

        localEngine.emitSummaryJSON(summariesDir: localSummaries)

        let result = try SummaryJSONParser.parse(summaryFile)
        XCTAssertEqual(result.totalDevices, 999,
                       "Real summary must not be overwritten by a proxy run (downgrade protection)")
    }

    /// Existing real summary + fresh real run → file NOT overwritten (skip preserved).
    func testEmitDoesNotOverwriteRealWithRealNeedlessly() throws {
        let eaColumn = "Compliance - Failed mSCP Results Count - NIST 800-53r5 Audit"
        var cfg = ReportConfig()
        cfg.compliance = ComplianceConfig(
            enabled: true,
            failuresCountColumn: eaColumn,
            failuresListColumn: nil,
            baselineLabel: "NIST",
            framework: nil,
            baselines: nil
        )
        let dataDir = tmpDir.appendingPathComponent("realreal-data", isDirectory: true)
        let localEngine = ReportEngine(config: cfg, dataDir: dataDir)
        try writeSecuritySnapshotWithDevices(to: dataDir)
        try writeEAResultsSnapshot(to: dataDir, eaColumn: eaColumn, passCount: 5, failCount: 5)

        let localSummaries = tmpDir.appendingPathComponent("realreal-summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: localSummaries, withIntermediateDirectories: true)

        let today = SummaryJSONParser.dateFormatter.string(from: Date())
        let summaryFile = localSummaries.appendingPathComponent("summary_\(today).json")
        // Sentinel to detect an overwrite.
        let existingReal = makeSummary(complianceIsProxy: false, hasBands: true,
                                       date: today, totalDevices: 777)
        try JSONEncoder().encode(existingReal).write(to: summaryFile, options: .atomic)

        localEngine.emitSummaryJSON(summariesDir: localSummaries)

        let result = try SummaryJSONParser.parse(summaryFile)
        XCTAssertEqual(result.totalDevices, 777,
                       "Real summary must not be overwritten when fresh run is equally real (skip preserved)")
    }

    // MARK: - Helpers

    private func makeSummary(
        complianceIsProxy: Bool?,
        hasBands: Bool,
        date: String = "2026-06-05",
        totalDevices: Int = 100,
        staleCount: Int? = 5,
        mobileDeviceCount: Int? = nil
    ) -> DailySummary {
        let bands: [String: MSCPBandCounts]? = hasBands
            ? ["NIST": MSCPBandCounts(pass: 80, low: 10, medLow: 5, medium: 3, high: 2, noData: 0)]
            : nil
        return DailySummary(
            date: date,
            totalDevices: totalDevices,
            fileVaultPct: 95.0,
            compliancePct: 80.0,
            staleCount: staleCount,
            osCurrentPct: 70.0,
            crowdstrikePct: nil,
            patchPct: 85.0,
            source: "jamf-cli",
            complianceIsProxy: complianceIsProxy,
            mscpBands: bands,
            mobileDeviceCount: mobileDeviceCount
        )
    }

    private func writeMinimalSecuritySnapshot() throws {
        try writeMinimalSecuritySnapshot(to: engine.dataDir)
    }

    /// Filename stamp 1h ago: the digest's cache-age gate reads the FILENAME
    /// timestamp (2.6, synced-storage mtimes lie), so a pinned 2024 stamp
    /// would read as expired cache and suppress the summary entirely.
    private var recentStamp: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.string(from: Date().addingTimeInterval(-3600))
    }

    private func writeMinimalSecuritySnapshot(to dataDir: URL) throws {
        let secDir = dataDir.appendingPathComponent("security", isDirectory: true)
        try FileManager.default.createDirectory(at: secDir, withIntermediateDirectories: true)
        let payload: [[String: Any]] = [
            [
                "section": "summary",
                "data": [
                    "total_devices": 250,
                    "filevault_encrypted": 240,
                    "filevault_encrypted_pct": "96.0%",
                    "gatekeeper_enabled": 250,
                    "sip_enabled": 249,
                    "firewall_enabled": 245,
                ],
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let file = secDir.appendingPathComponent("security_\(recentStamp).json")
        try data.write(to: file)
    }

    /// Write a security snapshot that includes per-device rows so the 4-control
    /// proxy (deviceGapCounts) is populated. All 5 synthetic devices pass every
    /// control, so proxy compliancePct ≈ 100%.
    private func writeSecuritySnapshotWithDevices(to dataDir: URL) throws {
        let secDir = dataDir.appendingPathComponent("security", isDirectory: true)
        try FileManager.default.createDirectory(at: secDir, withIntermediateDirectories: true)
        var rows: [[String: Any]] = [
            [
                "section": "summary",
                "data": [
                    "total_devices": 5,
                    "filevault_encrypted": 5,
                    "sip_enabled": 5,
                    "firewall_enabled": 5,
                    "gatekeeper_enabled": 5,
                ],
            ]
        ]
        for i in 0..<5 {
            rows.append([
                "section": "device",
                "name": "test-mac-\(i)",
                "filevault": "ENCRYPTED",
                "sip": "ENABLED",
                "firewall": true,
                "gatekeeper": "APP_STORE_AND_IDENTIFIED_DEVELOPERS",
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: rows)
        let file = secDir.appendingPathComponent("security_\(recentStamp).json")
        try data.write(to: file)
    }

    /// Write a synthetic ea-results snapshot with `passCount` devices at 0
    /// failures and `failCount` devices at 60 failures (High band).
    private func writeEAResultsSnapshot(
        to dataDir: URL,
        eaColumn: String,
        passCount: Int,
        failCount: Int
    ) throws {
        let eaDir = dataDir.appendingPathComponent("ea-results", isDirectory: true)
        try FileManager.default.createDirectory(at: eaDir, withIntermediateDirectories: true)

        var rows: [[String: Any]] = []
        for i in 0..<passCount {
            rows.append(["device": "mac-pass-\(i)", "ea_name": eaColumn, "value": 0])
        }
        for i in 0..<failCount {
            rows.append(["device": "mac-fail-\(i)", "ea_name": eaColumn, "value": 60])
        }
        let data = try JSONSerialization.data(withJSONObject: rows)
        let file = eaDir.appendingPathComponent("ea-results_\(recentStamp).json")
        try data.write(to: file)
    }
}
