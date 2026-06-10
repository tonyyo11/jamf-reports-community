import Foundation
import XCTest
@testable import JamfReports

/// Failure-branch coverage for `CLIBridge.generatePDF`.
///
/// The happy path uses `ReportEngine.generatePDF` → `PDFExporter` (WKWebView),
/// which is exercised end-to-end by `PDFExporterTests`. This file covers the
/// CLIBridge wrapper's pre-render guards (invalid profile, missing workspace)
/// because those branches do not require a live WKWebView and stay fast.
@MainActor
final class CLIBridgePDFTests: XCTestCase {

    private nonisolated(unsafe) var bridge: CLIBridge!

    override func setUpWithError() throws {
        bridge = CLIBridge()
    }

    override func tearDownWithError() throws {
        bridge = nil
    }

    func testGeneratePDFRejectsInvalidProfile() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIBridgePDFTests_\(UUID().uuidString).pdf")
        do {
            _ = try await bridge.generatePDF(
                profile: "INVALID/SLUG",
                outFile: tmp.path,
                onLine: { _ in }
            )
            XCTFail("generatePDF should reject an invalid profile slug")
        } catch let error as CLIBridgeError {
            switch error {
            case .invalidProfile, .workspaceMissing:
                break
            default:
                XCTFail("Unexpected CLIBridgeError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    /// `generatePDF` auto-initializes a missing workspace via `ensureWorkspace`
    /// (seeding config.yaml from the bundled example) — the same contract as
    /// every other CLI path. The pre-2.2.1 version of this test asserted a
    /// failure here, which only "passed" because YAMLCodec could not parse the
    /// seeded example config (#181) — and it leaked the created workspace into
    /// the real ~/Jamf-Reports. The seeded config must now parse; whether the
    /// subsequent empty-data render succeeds is PDFExporterTests' concern.
    func testGeneratePDFSeedsParseableConfigForMissingWorkspace() async throws {
        let slug = "pdf-test-missing-\(UUID().uuidString.prefix(8))".lowercased()
        guard let root = ProfileService.workspaceURL(for: slug) else {
            throw XCTSkip("workspace root unavailable for test profile")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIBridgePDFTests_\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tmpDir) }

        _ = try? await bridge.generatePDF(
            profile: slug,
            outFile: tmpDir.appendingPathComponent("report.pdf").path,
            onLine: { _ in }
        )

        let config = root.appendingPathComponent("config.yaml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path),
                      "ensureWorkspace must seed config.yaml for a missing workspace")
        XCTAssertNoThrow(try ConfigLoader.load(from: config),
                         "the seeded config must parse with the app's own loader (#181)")
    }
}
