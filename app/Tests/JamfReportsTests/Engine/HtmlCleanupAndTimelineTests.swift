import Foundation
import XCTest
@testable import JamfReports

// MARK: - HtmlCleanupAndTimelineTests
//
// Tests for the cleanupAnalysis and timeline HTML section builders.
// All tests use injected dictionaries directly rather than the filesystem
// to keep them fast and deterministic.

final class HtmlCleanupAndTimelineTests: XCTestCase {

    // MARK: - Helpers

    private func makeReport() -> HtmlReport {
        HtmlReport(config: ReportConfig().withDefaults(), dataDir: URL(fileURLWithPath: "/tmp/nonexistent-html-tests"))
    }

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("HtmlCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - cleanupAnalysis: flat-list snapshot (no detail)

    func testCleanupAnalysisEmptyWhenNoPoliciesOrProfiles() {
        let report = makeReport()
        let html = report.buildCleanupAnalysis(
            classicPolicies: [],
            classicProfiles: [],
            packages: [],
            scripts: []
        )
        // Must produce a non-empty section (emptySection placeholder).
        XCTAssertTrue(html.contains("cleanup-analysis") || html.contains("Cleanup"))
        // Must not claim "None found" when data was never evaluated.
        XCTAssertFalse(html.contains("None found"))
    }

    func testCleanupAnalysisFlatListEmitsHonestNote() {
        let report = makeReport()
        // Flat list (id + name only — no `general` or `scope` fields).
        let flatPolicies: [[String: Any]] = [
            ["id": 1, "name": "Policy A"],
            ["id": 2, "name": "Policy B"],
        ]
        let html = report.buildCleanupAnalysis(
            classicPolicies: flatPolicies,
            classicProfiles: [],
            packages: [],
            scripts: []
        )
        // Must tell the user detail is required, not "None found".
        XCTAssertFalse(html.contains("None found"), "Must not claim clean when data is absent")
        XCTAssertTrue(
            html.contains("detail") || html.contains("per-policy") || html.contains("not present"),
            "Must explain that detail is missing"
        )
    }

    // MARK: - cleanupAnalysis: with detail fields

    func testCleanupDisabledPoliciesExtractsCorrectly() {
        let report = makeReport()
        let policies: [[String: Any]] = [
            ["general": ["name": "Active Policy", "enabled": true], "scope": [:]],
            ["general": ["name": "Disabled Policy", "enabled": false], "scope": [:]],
            ["general": ["name": "Another Active", "enabled": true], "scope": ["all_computers": true]],
        ]
        let disabled = report.cleanupDisabledPolicies(policies)
        XCTAssertEqual(disabled, ["Disabled Policy"])
    }

    func testCleanupDisabledPoliciesSkipsFlatRecords() {
        // Flat records (no `general`) must produce no results.
        let report = makeReport()
        let policies: [[String: Any]] = [
            ["id": 1, "name": "Flat Policy A"],
        ]
        XCTAssertTrue(report.cleanupDisabledPolicies(policies).isEmpty)
    }

    func testCleanupUnscopedPoliciesAllComputersScopeExcluded() {
        let report = makeReport()
        let policies: [[String: Any]] = [
            ["general": ["name": "All Computers", "enabled": true],
             "scope": ["all_computers": true]],
            ["general": ["name": "No Scope", "enabled": true],
             "scope": ["computers": [], "computer_groups": [], "buildings": [], "departments": []]],
        ]
        let unscoped = report.cleanupUnscopedPolicies(policies)
        XCTAssertEqual(unscoped, ["No Scope"])
    }

    func testCleanupUnscopedPoliciesExcludesDisabled() {
        let report = makeReport()
        let policies: [[String: Any]] = [
            ["general": ["name": "Disabled No Scope", "enabled": false],
             "scope": ["computers": [], "computer_groups": []]],
        ]
        // Disabled policies must NOT appear in unscoped list.
        let unscoped = report.cleanupUnscopedPolicies(policies)
        XCTAssertTrue(unscoped.isEmpty)
    }

    func testCleanupUnscopedProfilesAllComputersScopeExcluded() {
        let report = makeReport()
        let profiles: [[String: Any]] = [
            ["general": ["name": "Broad Profile"],
             "scope": ["all_computers": true]],
            ["general": ["name": "Empty Scope Profile"],
             "scope": ["computers": [], "computer_groups": [], "buildings": [], "departments": []]],
        ]
        let unscoped = report.cleanupUnscopedProfiles(profiles)
        XCTAssertEqual(unscoped, ["Empty Scope Profile"])
    }

    // MARK: - cleanupUnusedPackages: critical guard test (all-flagged-unused prevention)

    func testCleanupUnusedPackagesReturnsEmptyWhenNoPackageDetail() {
        // When no policy carries `package_configuration`, we must NOT flag all packages
        // as unused — that would be catastrophically wrong.
        let report = makeReport()
        let packages: [[String: Any]] = [
            ["id": "1", "packageName": "Firefox.pkg"],
            ["id": "2", "packageName": "Zoom.pkg"],
        ]
        let flatPolicies: [[String: Any]] = [
            ["id": 1, "name": "Policy A"],  // no package_configuration
        ]
        let result = report.cleanupUnusedPackages(packages, policies: flatPolicies)
        XCTAssertTrue(result.isEmpty, "Must not flag packages unused when detail is absent")
    }

    func testCleanupUnusedPackagesExcludesReferencedID() {
        let report = makeReport()
        let packages: [[String: Any]] = [
            ["id": "1", "packageName": "Firefox.pkg"],
            ["id": "2", "packageName": "Orphan.pkg"],
        ]
        // Policy references package id "1" only.
        let policies: [[String: Any]] = [
            ["package_configuration": ["packages": [["id": "1", "name": "Firefox.pkg"]]]],
        ]
        let result = report.cleanupUnusedPackages(packages, policies: policies)
        XCTAssertEqual(result, ["Orphan.pkg"])
        XCTAssertFalse(result.contains("Firefox.pkg"))
    }

    func testCleanupUnusedPackagesAllReferencedReturnsEmpty() {
        let report = makeReport()
        let packages: [[String: Any]] = [
            ["id": "5", "packageName": "Referenced.pkg"],
        ]
        let policies: [[String: Any]] = [
            ["package_configuration": ["packages": [["id": "5"]]]],
        ]
        XCTAssertTrue(report.cleanupUnusedPackages(packages, policies: policies).isEmpty)
    }

    // MARK: - cleanupUnusedScripts: same guard pattern

    func testCleanupUnusedScriptsReturnsEmptyWhenNoScriptDetail() {
        let report = makeReport()
        let scripts: [[String: Any]] = [["id": "1", "name": "my_script.sh"]]
        let flatPolicies: [[String: Any]] = [["id": 1, "name": "Policy A"]]
        XCTAssertTrue(report.cleanupUnusedScripts(scripts, policies: flatPolicies).isEmpty)
    }

    func testCleanupUnusedScriptsExcludesReferencedID() {
        let report = makeReport()
        let scripts: [[String: Any]] = [
            ["id": "3", "name": "Used Script"],
            ["id": "7", "name": "Orphan Script"],
        ]
        let policies: [[String: Any]] = [
            ["scripts": [["id": "3", "name": "Used Script"]]],
        ]
        let result = report.cleanupUnusedScripts(scripts, policies: policies)
        XCTAssertEqual(result, ["Orphan Script"])
        XCTAssertFalse(result.contains("Used Script"))
    }

    // MARK: - cleanupAnalysis: full detail render

    func testCleanupAnalysisRendersWithDetailFields() {
        let report = makeReport()
        let policies: [[String: Any]] = [
            ["general": ["name": "Disabled Policy", "enabled": false],
             "scope": [:]],
            ["general": ["name": "Active All Computers", "enabled": true],
             "scope": ["all_computers": true],
             "package_configuration": ["packages": [["id": "1"]]]],
        ]
        let html = report.buildCleanupAnalysis(
            classicPolicies: policies,
            classicProfiles: [],
            packages: [["id": "2", "packageName": "Orphan.pkg"]],
            scripts: []
        )
        XCTAssertTrue(html.contains("cleanup-analysis"))
        XCTAssertTrue(html.contains("Cleanup Analysis"))
        XCTAssertTrue(html.contains("Disabled Policy"))
        // Tabs must be rendered
        XCTAssertTrue(html.contains("cleanup-tab"))
    }

    // MARK: - cleanupAnalysis: XSS in data values

    func testCleanupAnalysisXSSEscaped() {
        let report = makeReport()
        let xss = "<script>alert(1)</script>"
        let policies: [[String: Any]] = [
            ["general": ["name": xss, "enabled": false], "scope": [:]],
        ]
        let html = report.buildCleanupAnalysis(
            classicPolicies: policies,
            classicProfiles: [],
            packages: [],
            scripts: []
        )
        XCTAssertFalse(html.contains("<script>"), "XSS in policy names must be escaped")
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    // MARK: - timeline: loadSummarySnapshots via temp dir

    func testLoadSummarySnapshotsEmptyWhenDirMissing() {
        let report = makeReport()
        let result = report.loadSummarySnapshots()
        // dataDir is /tmp/nonexistent-html-tests so snapshots/summaries doesn't exist.
        XCTAssertTrue(result.isEmpty)
    }

    func testLoadSummarySnapshotsParsesValidFiles() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create the snapshots/summaries directory structure.
        let summariesDir = tmp
            .appendingPathComponent("jamf-cli-data", isDirectory: true)
            .deletingLastPathComponent()
            .appendingPathComponent("snapshots/summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)

        let summary: [String: Any] = [
            "date": "2026-01-15",
            "totalDevices": 100,
            "fileVaultPct": 95.0,
            "sipPct": 99.0,
            "compliancePct": 88.5,
            "source": "jamf-cli",
            "staleCount": 5,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary)
        try data.write(to: summariesDir.appendingPathComponent("summary_2026-01-15.json"))

        // HtmlReport's dataDir is workspace/jamf-cli-data; summaries are at workspace/snapshots/summaries.
        let dataDir = tmp.appendingPathComponent("jamf-cli-data", isDirectory: true)
        let report = HtmlReport(config: ReportConfig().withDefaults(), dataDir: dataDir)
        let snapshots = report.loadSummarySnapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.date, "2026-01-15")
        XCTAssertEqual(snapshots.first?.totalDevices, 100)
        XCTAssertEqual(snapshots.first?.fileVaultPct, 95.0)
        XCTAssertEqual(snapshots.first?.sipPct, 99.0)
        XCTAssertEqual(snapshots.first?.compliancePct, 88.5)
    }

    func testLoadSummarySnapshotsHandlesIntPct() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let summariesDir = tmp
            .appendingPathComponent("snapshots/summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)

        // Write an integer fileVaultPct (as the dummy workspace shows: 99 not 99.0).
        let summary: [String: Any] = [
            "date": "2026-05-31",
            "totalDevices": 101,
            "fileVaultPct": 99,
            "sipPct": 1,
            "source": "jamf-cli",
            "staleCount": 101,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary)
        try data.write(to: summariesDir.appendingPathComponent("summary_2026-05-31.json"))

        let dataDir = tmp.appendingPathComponent("jamf-cli-data", isDirectory: true)
        let report = HtmlReport(config: ReportConfig().withDefaults(), dataDir: dataDir)
        let snapshots = report.loadSummarySnapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.fileVaultPct, 99.0)
        XCTAssertEqual(snapshots.first?.sipPct, 1.0)
    }

    func testLoadSummarySnapshotsSortedOldestFirst() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let summariesDir = tmp.appendingPathComponent("snapshots/summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)

        for (idx, date) in ["2026-03-01", "2026-01-01", "2026-02-01"].enumerated() {
            let s: [String: Any] = [
                "date": date, "totalDevices": idx + 1,
                "source": "jamf-cli", "staleCount": 0,
            ]
            let d = try JSONSerialization.data(withJSONObject: s)
            try d.write(to: summariesDir.appendingPathComponent("summary_\(date).json"))
        }

        let dataDir = tmp.appendingPathComponent("jamf-cli-data", isDirectory: true)
        let report = HtmlReport(config: ReportConfig().withDefaults(), dataDir: dataDir)
        let snapshots = report.loadSummarySnapshots()

        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots[0].date, "2026-01-01")
        XCTAssertEqual(snapshots[1].date, "2026-02-01")
        XCTAssertEqual(snapshots[2].date, "2026-03-01")
    }

    // MARK: - timeline section render

    func testBuildTimelineSectionEmptyPlaceholderWhenNoSummaries() {
        let report = makeReport()
        let html = report.buildTimelineSection()
        XCTAssertTrue(html.contains("empty-section") || html.contains("Trends"))
        XCTAssertFalse(html.contains("<svg"), "No SVG expected with zero summaries")
    }

    func testBuildTimelineSectionSingleSnapshotNote() {
        let report = makeReport()
        // Inject a single snapshot by using a custom report with a temp dir containing 1 summary.
        let snapshots = [HtmlReport.SummarySnapshot(
            date: "2026-06-01",
            totalDevices: 50,
            fileVaultPct: 90.0,
            sipPct: nil,
            compliancePct: nil
        )]
        let svg = report.renderTimelineSVG(summaries: snapshots)
        XCTAssertTrue(svg.contains("empty-note"), "Single point should emit empty note from SVG helper")
    }

    func testBuildTimelineSectionMultipleSnapshotsRendersSVG() {
        let report = makeReport()
        let snapshots = [
            HtmlReport.SummarySnapshot(date: "2026-04-01", totalDevices: 90, fileVaultPct: 88.0, sipPct: 95.0, compliancePct: 70.0),
            HtmlReport.SummarySnapshot(date: "2026-05-01", totalDevices: 95, fileVaultPct: 92.0, sipPct: 97.0, compliancePct: 75.0),
            HtmlReport.SummarySnapshot(date: "2026-06-01", totalDevices: 100, fileVaultPct: 96.0, sipPct: 99.0, compliancePct: 80.0),
        ]
        let svg = report.renderTimelineSVG(summaries: snapshots)
        XCTAssertTrue(svg.contains("<svg"), "SVG element expected with multiple snapshots")
        XCTAssertTrue(svg.contains("<polyline"), "Trend polyline expected")
        XCTAssertTrue(svg.contains("FileVault"), "FileVault series label expected")
        XCTAssertFalse(svg.contains("<script>"), "No script tags in SVG")
    }

    func testBuildTimelineSectionAllNilMetricsProducesNoSeries() {
        let report = makeReport()
        // Snapshots with only totalDevices, no pct metrics.
        let snapshots = [
            HtmlReport.SummarySnapshot(date: "2026-04-01", totalDevices: 90, fileVaultPct: nil, sipPct: nil, compliancePct: nil),
            HtmlReport.SummarySnapshot(date: "2026-05-01", totalDevices: 95, fileVaultPct: nil, sipPct: nil, compliancePct: nil),
        ]
        let svg = report.renderTimelineSVG(summaries: snapshots)
        // No active series → no polyline segments (but SVG wrapper still present).
        XCTAssertTrue(svg.contains("<svg"))
        XCTAssertFalse(svg.contains("<polyline"))
    }

    // MARK: - timeline: XSS in date labels

    func testTimelineSVGXSSInDateEscaped() {
        let report = makeReport()
        let xss = "<script>alert(1)</script>"
        let snapshots = [
            HtmlReport.SummarySnapshot(date: xss, totalDevices: 50, fileVaultPct: 90.0, sipPct: nil, compliancePct: nil),
            HtmlReport.SummarySnapshot(date: "2026-05-01", totalDevices: 55, fileVaultPct: 91.0, sipPct: nil, compliancePct: nil),
        ]
        let svg = report.renderTimelineSVG(summaries: snapshots)
        XCTAssertFalse(svg.contains("<script>"), "XSS in date strings must be escaped")
        XCTAssertTrue(svg.contains("&lt;script&gt;"))
    }

    // MARK: - buildNewSectionEntries wiring

    func testBuildNewSectionEntriesContainsNewKeys() {
        let report = makeReport()
        let entries = report.buildNewSectionEntries(
            security: [],
            deviceCompliance: [],
            patchStatus: [],
            patchFailures: [],
            updateFailures: [],
            computersInventory: [],
            auditFindings: []
        )
        XCTAssertNotNil(entries[.cleanupAnalysis], "cleanupAnalysis must be in section map")
        XCTAssertNotNil(entries[.timeline], "timeline must be in section map")
    }
}
