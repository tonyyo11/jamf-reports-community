import Foundation
import XCTest
@testable import JamfReports

/// The exit-code constants the auth guard and its callers branch on, and the apikey bypass
/// (`CLIBridge.shouldSkipAuthProbe`). The guard itself calls `pro auth token`, which needs a real
/// jamf-cli and takes no injected binary, so no test runs it.
@MainActor
final class CLIBridgeAuthGuardTests: XCTestCase {

    // MARK: - Constants

    func test_exitCodeUnauthorized_isThree() {
        // jamf-cli maps HTTP 401 → exit 3. The constant must not drift.
        XCTAssertEqual(CLIBridge.exitCodeUnauthorized, 3)
    }

    func test_exitCodePermissionDenied_isFive() {
        // jamf-cli maps HTTP 403 → exit 5.
        XCTAssertEqual(CLIBridge.exitCodePermissionDenied, 5)
    }

    func test_exitCodeRateLimited_isSix() {
        // jamf-cli maps HTTP 429 → exit 6.
        XCTAssertEqual(CLIBridge.exitCodeRateLimited, 6)
    }

    func test_exitCodeUsage_isTwo() {
        // jamf-cli maps bad flags / missing args → exit 2. The constant must not drift.
        XCTAssertEqual(CLIBridge.exitCodeUsage, 2)
    }

    func test_exitCodeNotFound_isFour() {
        // jamf-cli maps HTTP 404 → exit 4. The constant must not drift.
        XCTAssertEqual(CLIBridge.exitCodeNotFound, 4)
    }

    // MARK: - shouldSkipAuthProbe unit tests

    func test_shouldSkipAuthProbe_trueForAPIKey() {
        XCTAssertTrue(CLIBridge.shouldSkipAuthProbe(for: "apikey"))
    }

    func test_shouldSkipAuthProbe_falseForBearer() {
        XCTAssertFalse(CLIBridge.shouldSkipAuthProbe(for: "bearer"))
        XCTAssertFalse(CLIBridge.shouldSkipAuthProbe(for: ""))
        XCTAssertFalse(CLIBridge.shouldSkipAuthProbe(for: "APIKEY")) // case-sensitive
    }
}
