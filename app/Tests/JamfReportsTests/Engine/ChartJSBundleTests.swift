import Foundation
import XCTest
@testable import JamfReports

// MARK: - ChartJSBundleTests

final class ChartJSBundleTests: XCTestCase {

    func testInlineScriptIsNonEmpty() {
        XCTAssertFalse(
            ChartJSBundle.inlineScript.isEmpty,
            "Vendored Chart.js must not be empty"
        )
    }

    func testInlineScriptExceedsMinimumSize() {
        // Chart.js 4.4.0 minified is ~205 KB. Require at least 100 KB to detect
        // truncation, encoding failures, or accidental replacement with a stub.
        let byteCount = ChartJSBundle.inlineScript.utf8.count
        XCTAssertGreaterThan(byteCount, 100_000,
            "Vendored Chart.js is \(byteCount) bytes — expected > 100 KB")
    }

    func testInlineScriptRegistersChartGlobal() {
        // The UMD build assigns the Chart constructor to window.Chart.
        // Verify the expected global registration is present.
        XCTAssertTrue(
            ChartJSBundle.inlineScript.contains("window.Chart"),
            "Vendored Chart.js must contain 'window.Chart' UMD export"
        )
    }

    func testSHA256ConstantIsPresent() {
        // The SHA-256 constant documents the hash of the vendored file.
        XCTAssertFalse(
            ChartJSBundle.sha256.isEmpty,
            "SHA-256 constant must be populated"
        )
        XCTAssertEqual(
            ChartJSBundle.sha256.count,
            64,
            "SHA-256 hex digest must be 64 characters"
        )
    }

    func testInlineScriptDoesNotContainCDNReference() {
        // The whole point of vendoring is to remove the CDN call. Guard against
        // accidental re-introduction.
        XCTAssertFalse(
            ChartJSBundle.inlineScript.contains("cdn.jsdelivr.net"),
            "Vendored script must not contain a CDN reference"
        )
    }
}
