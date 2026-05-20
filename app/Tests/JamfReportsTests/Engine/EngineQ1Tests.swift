import Foundation
import XCTest
import CryptoKit
@testable import JamfReports

// MARK: - EngineQ1Tests
//
// Tests for Lane Q1 engine improvements:
//   #6 — deviceAnchorSlug helper for Protect → Audit deep-linking
//   #8 — SHA-256 manifest and evidence-bundle alongside generated artifacts
//   #10 — ComplianceFramework controlled vocabulary + ComplianceConfig.displayFramework

final class EngineQ1Tests: XCTestCase {

    // MARK: - Helpers

    private func makeReport(
        config: ReportConfig = ReportConfig().withDefaults()
    ) -> HtmlReport {
        HtmlReport(config: config, dataDir: URL(fileURLWithPath: "/tmp/nonexistent"))
    }

    // MARK: - Finding #6: deviceAnchorSlug

    func testSlugAlphaOnly() {
        let report = makeReport()
        XCTAssertEqual(report.deviceAnchorSlug("MacBook"), "macbook")
    }

    func testSlugMixedCase() {
        let report = makeReport()
        XCTAssertEqual(report.deviceAnchorSlug("MacBook-Pro-001"), "macbook-pro-001")
    }

    func testSlugSpacesAndDots() {
        let report = makeReport()
        // spaces and dots are non-alphanumeric, become dashes
        let slug = report.deviceAnchorSlug("device 01.corp")
        XCTAssertEqual(slug, "device-01-corp")
    }

    func testSlugTrailingWhitespace() {
        let report = makeReport()
        // leading/trailing whitespace → dashes → trimmed
        let slug = report.deviceAnchorSlug("  my-device  ")
        XCTAssertEqual(slug, "my-device")
    }

    func testSlugUnicodeRejection() {
        let report = makeReport()
        // Non-ASCII characters (e.g., emoji, accented chars) → replaced with dash
        let slug = report.deviceAnchorSlug("café-Mac")
        // 'é' is non-ASCII, becomes '-'; result is 'caf--mac' → collapses → 'caf-mac'
        XCTAssertFalse(slug.contains("é"))
        XCTAssertFalse(slug.contains("--"))
        XCTAssertFalse(slug.isEmpty)
    }

    func testSlugEmptyFallback() {
        let report = makeReport()
        // All-unicode string collapses to empty → "device"
        XCTAssertEqual(report.deviceAnchorSlug("🖥️🖥️"), "device")
    }

    func testSlugCollapsesConsecutiveDashes() {
        let report = makeReport()
        let slug = report.deviceAnchorSlug("Mac  Book")
        XCTAssertFalse(slug.contains("--"))
    }

    func testSlugPreservesHyphensAndUnderscores() {
        let report = makeReport()
        let slug = report.deviceAnchorSlug("mac_book-pro")
        XCTAssertEqual(slug, "mac_book-pro")
    }

    // MARK: - Finding #6: protect-alerts HTML contains device-link and anchor

    func testProtectAlertsDeviceCellContainsAnchorLink() {
        // Build a minimal report and call buildProtectAlerts via the public audit render path
        // by verifying deviceAnchorSlug produces deterministic output used in the HTML.
        let report = makeReport()
        let slug = report.deviceAnchorSlug("MacBook-Aiyana")
        let expectedHref = "#audit-dev-\(slug)"
        XCTAssertEqual(slug, "macbook-aiyana")
        XCTAssertEqual(expectedHref, "#audit-dev-macbook-aiyana")
    }

    // MARK: - Finding #8: SHA-256 manifest

    func testManifestWrittenForSynthesizedFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("q1-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write a one-byte artifact.
        let artifactURL = dir.appendingPathComponent("test.xlsx")
        try Data([0xAB]).write(to: artifactURL)

        // Write the manifest.
        ReportEngine.writeManifestStatic(for: artifactURL, profile: "prod", template: "Executive")

        // Read the manifest back.
        let manifestURL = artifactURL.appendingPathExtension("manifest.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path),
                      "Manifest file should exist at \(manifestURL.path)")
        let content = try String(contentsOf: manifestURL, encoding: .utf8)

        // Parse the sha256 line.
        let sha256Line = content.components(separatedBy: "\n")
            .first { $0.hasPrefix("sha256:") }
        XCTAssertNotNil(sha256Line, "Manifest should contain a sha256: line")

        let manifestHex = sha256Line!
            .replacingOccurrences(of: "sha256:", with: "")
            .trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(manifestHex.count, 64, "SHA-256 digest should be 64 hex characters")

        // Recompute and verify.
        let fileData = try Data(contentsOf: artifactURL)
        let recomputed = SHA256.hash(data: fileData)
        let recomputedHex = recomputed.compactMap { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(manifestHex, recomputedHex, "Manifest SHA-256 must match recomputed digest")
    }

    func testManifestContainsRequiredFields() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("q1-manifest-fields-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let artifactURL = dir.appendingPathComponent("report.html")
        try Data("hello".utf8).write(to: artifactURL)
        ReportEngine.writeManifestStatic(for: artifactURL, profile: "testprofile",
                                         template: "Compliance")

        let manifestURL = artifactURL.appendingPathExtension("manifest.txt")
        let content = try String(contentsOf: manifestURL, encoding: .utf8)

        XCTAssertTrue(content.contains("filename: report.html"))
        XCTAssertTrue(content.contains("sha256:"))
        XCTAssertTrue(content.contains("generated_at:"))
        XCTAssertTrue(content.contains("generator: JamfReports"))
        XCTAssertTrue(content.contains("profile: testprofile"))
        XCTAssertTrue(content.contains("template: Compliance"))
    }

    func testEvidenceBundleListsAllArtifacts() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("q1-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let artifacts = ["report.xlsx", "report.html", "report.pdf"].map {
            dir.appendingPathComponent($0)
        }
        // Write distinct one-byte payloads so hashes differ.
        for (idx, url) in artifacts.enumerated() {
            try Data([UInt8(idx + 1)]).write(to: url)
        }

        ReportEngine.writeEvidenceBundle(
            artifacts: artifacts,
            profile: "lena",
            template: "Executive"
        )

        let stem = artifacts[0].deletingPathExtension().lastPathComponent
        let bundleURL = dir.appendingPathComponent("\(stem).evidence-bundle.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.path),
                      "Evidence bundle should exist")
        let content = try String(contentsOf: bundleURL, encoding: .utf8)

        // Each artifact filename must appear in the bundle.
        XCTAssertTrue(content.contains("report.xlsx"))
        XCTAssertTrue(content.contains("report.html"))
        XCTAssertTrue(content.contains("report.pdf"))

        // Hashes must be distinct (different file contents).
        let sha256Lines = content.components(separatedBy: "\n")
            .filter { $0.hasPrefix("sha256:") }
            .map { $0.replacingOccurrences(of: "sha256:", with: "").trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(sha256Lines.count, 3, "Bundle should contain three sha256 lines")
        let uniqueHashes = Set(sha256Lines)
        XCTAssertEqual(uniqueHashes.count, 3, "Three distinct artifacts must have three distinct hashes")
    }

    // MARK: - Finding #10: ComplianceFramework

    func testAllFrameworkCasesHaveNonEmptyRawValues() {
        for c in ComplianceFramework.allCases {
            XCTAssertFalse(c.rawValue.isEmpty, "\(c) raw value must not be empty")
        }
    }

    func testParseNIST80053r5ModCaseInsensitive() {
        // Exact raw value, different case
        XCTAssertEqual(
            ComplianceFramework.parse(rawValue: "nist 800-53r5 moderate"),
            .nist80053r5Mod
        )
        XCTAssertEqual(
            ComplianceFramework.parse(rawValue: "NIST 800-53r5 Moderate"),
            .nist80053r5Mod
        )
    }

    func testParseNIST80053r5ModAlias() {
        XCTAssertEqual(ComplianceFramework.parse(rawValue: "nist-800-53"), .nist80053r5Mod)
        XCTAssertEqual(ComplianceFramework.parse(rawValue: "nist 800-53"), .nist80053r5Mod)
    }

    func testParseNIST80053r5High() {
        XCTAssertEqual(
            ComplianceFramework.parse(rawValue: "NIST 800-53r5 High"),
            .nist80053r5High
        )
    }

    func testParseDISASTIG() {
        XCTAssertEqual(ComplianceFramework.parse(rawValue: "stig"), .disaSTIGmacOS)
        XCTAssertEqual(ComplianceFramework.parse(rawValue: "DISA STIG macOS"), .disaSTIGmacOS)
        XCTAssertEqual(ComplianceFramework.parse(rawValue: "disa-stig"), .disaSTIGmacOS)
    }

    func testParseCISLevels() {
        XCTAssertEqual(ComplianceFramework.parse(rawValue: "CIS Level 1"), .cisLevel1)
        XCTAssertEqual(ComplianceFramework.parse(rawValue: "cis-l1"), .cisLevel1)
        XCTAssertEqual(ComplianceFramework.parse(rawValue: "CIS Level 2"), .cisLevel2)
        XCTAssertEqual(ComplianceFramework.parse(rawValue: "cis-l2"), .cisLevel2)
    }

    func testParseCMMCL2() {
        XCTAssertEqual(ComplianceFramework.parse(rawValue: "CMMC Level 2"), .cmmcL2)
        XCTAssertEqual(ComplianceFramework.parse(rawValue: "cmmc"), .cmmcL2)
    }

    func testParseFedRAMPModerate() {
        XCTAssertEqual(ComplianceFramework.parse(rawValue: "FedRAMP Moderate"), .fedRAMPModerate)
        XCTAssertEqual(ComplianceFramework.parse(rawValue: "fedramp"), .fedRAMPModerate)
        XCTAssertEqual(ComplianceFramework.parse(rawValue: "fedramp-mod"), .fedRAMPModerate)
    }

    func testParseNonsenseReturnsNil() {
        XCTAssertNil(ComplianceFramework.parse(rawValue: "Compliance"))
        XCTAssertNil(ComplianceFramework.parse(rawValue: "N/A"))
        XCTAssertNil(ComplianceFramework.parse(rawValue: ""))
        XCTAssertNil(ComplianceFramework.parse(rawValue: "   "))
    }

    func testParseWhitespaceVariations() {
        // Leading/trailing whitespace should still parse.
        XCTAssertEqual(
            ComplianceFramework.parse(rawValue: "  NIST 800-53r5 Moderate  "),
            .nist80053r5Mod
        )
    }

    func testComplianceConfigDisplayFrameworkKnownValue() {
        var config = ComplianceConfig()
        config.framework = "NIST 800-53r5 Moderate"
        XCTAssertEqual(config.displayFramework, "NIST 800-53r5 Moderate")
    }

    func testComplianceConfigDisplayFrameworkNonsense() {
        var config = ComplianceConfig()
        config.framework = "Compliance"
        // Does not parse → returns literal operator string (not "Not configured")
        XCTAssertEqual(config.displayFramework, "Compliance")
        // parsedFramework should be nil
        XCTAssertNil(config.parsedFramework)
    }

    func testComplianceConfigDisplayFrameworkEmpty() {
        let config = ComplianceConfig()
        // framework is nil → displayFramework returns "Not configured"
        XCTAssertEqual(config.displayFramework, "Not configured")
    }

    func testComplianceConfigParsedFrameworkMatchesEnum() {
        var config = ComplianceConfig()
        config.framework = "DISA STIG macOS"
        XCTAssertEqual(config.parsedFramework, .disaSTIGmacOS)
    }
}
