import Foundation
import XCTest
@testable import JamfReports

/// Verifies the auth-guard layer added to `collect` and `collectThenGenerate`.
///
/// The guard calls `pro auth token` before launching any API commands so that
/// a profile with bogus credentials fails fast with exit 3 (HTTP 401 per
/// jamf-cli architecture) instead of brute-forcing through every subcommand.
///
/// The apikey bypass (Jamf School profiles with `auth-method = apikey`) is not
/// covered here in integration form because `authGuard` resolves the auth method
/// via `ProfileService.discoverLocal()`, which shells out to `jamf-cli config list`
/// and requires a real registered profile. School profiles are tested functionally
/// by the school-generate integration path. The bypass logic itself is unit-tested
/// below via `CLIBridge.shouldSkipAuthProbe`.
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

    // MARK: - collect

    /// A syntactically valid but unconfigured profile slug produces no valid
    /// token, so the guard must block collect and emit an actionable error line.
    func test_collect_blocksAndEmitsAuthError_forUnknownProfile() async throws {
        guard ExecutableLocator.locate("jamf-cli") != nil else {
            throw XCTSkip("jamf-cli not installed — auth probe not exercisable")
        }
        let bridge = CLIBridge()
        let collector = LineCollector()

        let code = await bridge.collect(profile: "jrc-test-no-such-profile-xyzzy") { line in
            collector.append(line)
        }

        XCTAssertEqual(code, CLIBridge.exitCodeUnauthorized,
                       "collect must return exitCodeUnauthorized when auth probe fails")
        XCTAssertTrue(
            collector.lines.contains(where: { $0.text.contains("auth check failed") }),
            "expected an [error] auth check failed line; got: \(collector.lines.map(\.text))"
        )
        // Guard must fire before any API subcommand is launched.
        XCTAssertFalse(
            collector.lines.contains(where: { $0.text.contains("collecting jamf-cli") }),
            "collect must not start after auth guard failure"
        )
    }

    /// collectThenGenerate must apply the same guard (via collect) and not proceed to generate.
    func test_collectThenGenerate_blocksOnAuthFailure() async throws {
        guard ExecutableLocator.locate("jamf-cli") != nil else {
            throw XCTSkip("jamf-cli not installed — auth probe not exercisable")
        }
        let bridge = CLIBridge()
        let collector = LineCollector()

        let code = await bridge.collectThenGenerate(
            profile: "jrc-test-no-such-profile-xyzzy",
            csvPath: nil
        ) { line in
            collector.append(line)
        }

        XCTAssertEqual(code, CLIBridge.exitCodeUnauthorized)
        XCTAssertFalse(
            collector.lines.contains(where: { $0.text.contains("generating report") }),
            "generate step must not run after auth guard failure"
        )
    }
}

// MARK: - LineCollector (same pattern as FailureModeTests)

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [CLIBridge.LogLine] = []

    func append(_ line: CLIBridge.LogLine) {
        lock.lock(); defer { lock.unlock() }
        _lines.append(line)
    }

    var lines: [CLIBridge.LogLine] {
        lock.lock(); defer { lock.unlock() }
        return _lines
    }
}
