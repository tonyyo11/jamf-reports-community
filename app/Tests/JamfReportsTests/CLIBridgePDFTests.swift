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

    func testGeneratePDFFailsWhenWorkspaceMissing() async {
        let missingSlug = "pdf-test-missing-\(UUID().uuidString.prefix(8))".lowercased()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIBridgePDFTests_\(UUID().uuidString).pdf")
        do {
            _ = try await bridge.generatePDF(
                profile: missingSlug,
                outFile: tmp.path,
                onLine: { _ in }
            )
            XCTFail("generatePDF should fail when the workspace does not exist")
        } catch let error as CLIBridgeError {
            switch error {
            case .workspaceMissing, .configLoadFailed:
                break
            default:
                XCTFail("Unexpected CLIBridgeError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
