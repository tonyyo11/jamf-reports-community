import CryptoKit
import Foundation
import XCTest
@testable import JamfReports

/// T-13 integrity envelope: HTML meta+footer and XLSX `.sha256` sidecar.
///
/// Mirrors `tests/test_integrity_envelope.py` on the Swift side. Verifies that
/// HtmlReport substitutes the placeholder hash for the real digest, and that
/// ReportEngine.writeSHA256Sidecar emits `shasum -a 256` compatible files.
final class IntegrityEnvelopeTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "IntegrityEnvelopeTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - HtmlReport

    func testHtmlGenerateEmbedsReportSha256MetaTag() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = HtmlReport(config: ReportConfig().withDefaults(), dataDir: dir)
        let outURL = dir.appendingPathComponent("report.html")
        let digest = try await report.generate(outputURL: outURL)

        let text = try String(contentsOf: outURL, encoding: .utf8)
        XCTAssertTrue(
            text.contains("<meta name=\"report-sha256\" content=\"\(digest)\">"),
            "embedded meta tag must carry the returned digest"
        )
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy { $0.isHexDigit })
        XCTAssertFalse(
            text.contains(String(repeating: "0", count: 64)),
            "placeholder must be fully substituted in the written file"
        )
    }

    func testHtmlGenerateFooterIncludesVerifyCommand() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = HtmlReport(config: ReportConfig().withDefaults(), dataDir: dir)
        let outURL = dir.appendingPathComponent("report.html")
        _ = try await report.generate(outputURL: outURL)

        let text = try String(contentsOf: outURL, encoding: .utf8)
        XCTAssertTrue(text.contains("class=\"verify-footer\""),
                      "footer must carry the verify-footer class")
        XCTAssertTrue(text.contains("shasum -a 256 report.html"),
                      "footer must reference the actual output filename")
        XCTAssertTrue(text.contains("report-sha256"),
                      "footer should reference the meta tag name so users know what to verify")
    }

    func testHtmlMetaHashMatchesPlaceholderVersionBytes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = HtmlReport(config: ReportConfig().withDefaults(), dataDir: dir)
        let outURL = dir.appendingPathComponent("report.html")
        let digest = try await report.generate(outputURL: outURL)

        let text = try String(contentsOf: outURL, encoding: .utf8)
        // External verifier procedure: substitute the embedded hash back to the
        // 64-zero placeholder and re-hash. The result must equal the embedded hash.
        let placeholderText = text.replacingOccurrences(
            of: digest, with: String(repeating: "0", count: 64)
        )
        let reproduced = SHA256.hash(data: Data(placeholderText.utf8))
            .compactMap { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(reproduced, digest,
                       "verifier procedure must reproduce the embedded fingerprint")
    }

    // MARK: - ReportEngine.writeSHA256Sidecar

    func testSha256SidecarUsesShasumFormat() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let artifact = dir.appendingPathComponent("report.xlsx")
        let body = Data("dummy xlsx body".utf8)
        try body.write(to: artifact)
        let expected = SHA256.hash(data: body)
            .compactMap { String(format: "%02x", $0) }.joined()

        let returned = ReportEngine.writeSHA256Sidecar(for: artifact)
        XCTAssertEqual(returned, expected)

        let sidecarURL = artifact.appendingPathExtension("sha256")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
        let text = try String(contentsOf: sidecarURL, encoding: .utf8)
        XCTAssertEqual(
            text, "\(expected)  report.xlsx\n",
            "sidecar must be exactly `<hash><two-spaces><basename><LF>` so shasum -c accepts it"
        )
    }

    func testSha256SidecarReturnsNilWhenArtifactMissing() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).xlsx")
        let returned = ReportEngine.writeSHA256Sidecar(for: dir)
        XCTAssertNil(returned)
    }

    func testXlsxSidecarSha256MatchesFileContent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // PK\x03\x04 header + payload, so the body looks plausibly like an XLSX.
        var blob = Data([0x50, 0x4b, 0x03, 0x04])
        blob.append(Data(repeating: 0x41, count: 1200))
        let artifact = dir.appendingPathComponent("jamf_report_2026-05-17.xlsx")
        try blob.write(to: artifact)
        let expected = SHA256.hash(data: blob)
            .compactMap { String(format: "%02x", $0) }.joined()

        _ = ReportEngine.writeSHA256Sidecar(for: artifact)
        let sidecar = artifact.appendingPathExtension("sha256")
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let parts = trimmed.components(separatedBy: "  ")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0], expected)
        XCTAssertEqual(parts[1], artifact.lastPathComponent)
    }

    // MARK: - GenerateSheetState.parseSHA256LogLine

    func testParseSHA256LogLineHappyPath() {
        let hash = String(repeating: "a", count: 64)
        let text = "[ok] sha256: \(hash) report.xlsx"
        let parsed = GenerateSheetState.parseSHA256LogLine(text)
        XCTAssertEqual(parsed?.hash, hash)
        XCTAssertEqual(parsed?.filename, "report.xlsx")
    }

    func testParseSHA256LogLineRejectsShortHash() {
        let text = "[ok] sha256: deadbeef report.xlsx"
        XCTAssertNil(GenerateSheetState.parseSHA256LogLine(text))
    }

    func testParseSHA256LogLineRejectsNonMatchingPrefix() {
        XCTAssertNil(GenerateSheetState.parseSHA256LogLine("[ok] report written"))
    }
}
