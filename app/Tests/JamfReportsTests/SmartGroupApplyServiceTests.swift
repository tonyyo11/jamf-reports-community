import Foundation
import XCTest
@testable import JamfReports

/// Tests for the Stage-2 destructive apply service and the view-model that
/// drives `SmartGroupApplySheet`.
///
/// Same mock-executor pattern as Stage 1 tests — argv-keyed dictionary that
/// avoids retroactive Hashable conformance on `CLICommand`.
@MainActor
final class SmartGroupApplyServiceTests: XCTestCase {

    // MARK: - Argv shape (smoke check — full coverage in CLICommandTests)

    func testApplyConstructsExpectedCommand() async throws {
        // Capture the argv the service passes to the executor.
        let recording = RecordingExecutor()
        let service = SmartGroupApplyService(executor: recording)

        recording.next = .success(Data(#"{"id": 1, "name": "X", "member_count": 0, "created": true}"#.utf8))
        _ = try await service.apply(
            profile: "harbor",
            templateSlug: "stale-checkin",
            smartGroupName: "Stale 90d",
            params: [:],
            recalculate: false,
            dryRun: false
        )
        XCTAssertEqual(
            recording.invocations.last,
            ["-p", "harbor", "pro", "sg", "apply",
             "--template", "stale-checkin",
             "--name", "Stale 90d",
             "--yes",
             "--output", "json"]
        )
    }

    // MARK: - Result decoding

    func testDecodeResultSnakeCaseShape() throws {
        let json = Data(#"""
        {"id": 42, "name": "Stale 90d", "member_count": 17, "created": true}
        """#.utf8)
        let result = try SmartGroupApplyService.decodeResult(json)
        XCTAssertEqual(result.smartGroupID, 42)
        XCTAssertEqual(result.name, "Stale 90d")
        XCTAssertEqual(result.memberCount, 17)
        XCTAssertTrue(result.created)
    }

    func testDecodeResultCamelCaseShape() throws {
        // PR contract isn't fully locked — tolerate camelCase too.
        let json = Data(#"""
        {"id": 9, "name": "X", "memberCount": 3, "created": false}
        """#.utf8)
        let result = try SmartGroupApplyService.decodeResult(json)
        XCTAssertEqual(result.smartGroupID, 9)
        XCTAssertEqual(result.memberCount, 3)
        XCTAssertFalse(result.created)
    }

    func testDecodeResultMissingMemberCountIsNil() throws {
        let json = Data(#"{"id": 1, "name": "X", "created": true}"#.utf8)
        let result = try SmartGroupApplyService.decodeResult(json)
        XCTAssertNil(result.memberCount)
    }

    /// S-09 (PR-4): when the upstream `created` flag is absent the
    /// decoder previously defaulted to `true`, causing the UI to render
    /// "Smart group created" for what might be an update. In audited
    /// admin environments a false "created" is actively misleading; a
    /// false "updated" is the safer wrong answer. Flip the default to
    /// `false` so the absent-field case at least doesn't claim a state
    /// that may not have happened.
    ///
    /// jamf-cli PR #205's contract is unstable (commit f80753b in this
    /// repo documents drift discovered live); the default reaches
    /// production only if a future schema change drops the field.
    func testDecodeResultAbsentCreatedDefaultsFalse() throws {
        let json = Data(#"{"id": 7, "name": "X", "member_count": 3}"#.utf8)
        let result = try SmartGroupApplyService.decodeResult(json)
        XCTAssertFalse(result.created,
                       "Absent `created` field must default to false (safer wrong answer per S-09)")
    }

    func testDecodeResultExplicitFalseStillFalse() throws {
        // Regression guard: don't conflate "absent" and "false".
        let json = Data(#"{"id": 8, "name": "X", "member_count": 3, "created": false}"#.utf8)
        let result = try SmartGroupApplyService.decodeResult(json)
        XCTAssertFalse(result.created)
    }

    func testDecodeResultExplicitTrueStillTrue() throws {
        // Regression guard: the default flip must not change behavior
        // when the producer emits `created: true` (the common case).
        let json = Data(#"{"id": 9, "name": "X", "member_count": 3, "created": true}"#.utf8)
        let result = try SmartGroupApplyService.decodeResult(json)
        XCTAssertTrue(result.created)
    }

    func testDecodeResultStringCreatedDefaultsFalse() throws {
        // silent-failure-hunter PR-4 review: the warning fires for both
        // "key absent" and "wrong type". Lock in the wrong-type
        // behavior so a future change can't accidentally accept a
        // string `"true"` as truthy and silently revert the S-09
        // guarantee.
        //
        // Note: Foundation's `as? Bool` accepts numeric 0/1 via
        // NSNumber bridging — that's an acceptable type coercion (1 is
        // truthy in JSON), so this test pins only the genuinely
        // non-coercible cases.
        for badValue in [#""true""#, #""false""#, "null"] {
            let json = Data(#"{"id": 10, "name": "X", "member_count": 3, "created": \#(badValue)}"#.utf8)
            let result = try SmartGroupApplyService.decodeResult(json)
            XCTAssertFalse(result.created,
                           "Non-coercible `created` value \(badValue) must default to false (warning fires; behavior matches S-09)")
        }
    }

    func testDecodeResultMissingIDThrows() {
        XCTAssertThrowsError(
            try SmartGroupApplyService.decodeResult(Data(#"{"name": "X"}"#.utf8))
        )
    }

    func testDecodeResultMalformedJSONThrows() {
        XCTAssertThrowsError(
            try SmartGroupApplyService.decodeResult(Data("not-json".utf8))
        )
    }

    // MARK: - Error classification

    func testClassifyExtractsHTTP401() {
        let result = SmartGroupApplyService.classifyError(
            code: 3,
            stderr: "Error: HTTP 401: Unauthorized\n"
        )
        guard case .apiError(let status, let message) = result else {
            return XCTFail("expected apiError, got \(result)")
        }
        XCTAssertEqual(status, 401)
        XCTAssertTrue(message.contains("Unauthorized"))
    }

    func testClassifyExtractsHTTP429() {
        let result = SmartGroupApplyService.classifyError(
            code: 6,
            stderr: "Error: HTTP 429 Too Many Requests"
        )
        guard case .apiError(let status, _) = result else {
            return XCTFail("expected apiError, got \(result)")
        }
        XCTAssertEqual(status, 429)
    }

    func testClassifyExtractsHTTP403() {
        let result = SmartGroupApplyService.classifyError(
            code: 5,
            stderr: "Error: HTTP 403: Forbidden\n"
        )
        guard case .apiError(let status, _) = result else {
            return XCTFail("expected apiError, got \(result)")
        }
        XCTAssertEqual(status, 403)
    }

    func testClassifyUnknownCommandIsFeatureNotAvailable() {
        let result = SmartGroupApplyService.classifyError(
            code: 2,
            stderr: "Error: unknown command \"sg\" for \"jamf-cli pro\""
        )
        XCTAssertEqual(result, .featureNotAvailable)
    }

    func testClassifyNetworkErrorsFlaggedAsNetworkFailure() {
        let cases: [String] = [
            "Get \"https://jamf.example/api\": connection refused",
            "Post \"https://jamf.example/api\": dial tcp: i/o timeout",
            "Get https://jamf.example/api: no such host",
            "TLS handshake error",
            "context deadline exceeded",
        ]
        for stderr in cases {
            let result = SmartGroupApplyService.classifyError(code: 1, stderr: stderr)
            guard case .networkFailure = result else {
                XCTFail("expected networkFailure for '\(stderr)', got \(result)")
                continue
            }
        }
    }

    func testClassifyUnmatchedFallsThroughToExecutionFailed() {
        let result = SmartGroupApplyService.classifyError(code: 99, stderr: "something else")
        guard case .executionFailed(let code, _) = result else {
            return XCTFail("expected executionFailed, got \(result)")
        }
        XCTAssertEqual(code, 99)
    }

    // MARK: - extractHTTPError

    func testExtractHTTPMatchesEmbeddedPattern() {
        let info = SmartGroupApplyService.extractHTTPError(from: "blah HTTP 401: Unauthorized blah")
        XCTAssertEqual(info?.code, 401)
        XCTAssertEqual(info?.message, "Unauthorized blah")
    }

    func testExtractHTTPHandlesSpaceSeparator() {
        let info = SmartGroupApplyService.extractHTTPError(from: "HTTP 500 Internal Server Error")
        XCTAssertEqual(info?.code, 500)
    }

    func testExtractHTTPReturnsNilWhenAbsent() {
        XCTAssertNil(SmartGroupApplyService.extractHTTPError(from: "no http here"))
        XCTAssertNil(SmartGroupApplyService.extractHTTPError(from: ""))
    }
}

// MARK: - Recording executor (for argv-shape assertion)

/// Captures argv passed in and returns a configurable next outcome. Distinct
/// from the MockCLIExecutor used in Stage-1 tests because here we care about
/// the argv recording, not key-based lookup.
private final class RecordingExecutor: CLIExecutor, @unchecked Sendable {
    enum Outcome { case success(Data); case failure(CLIExecutorError) }
    var invocations: [[String]] = []
    var next: Outcome = .failure(.nonZeroExit(code: -1, stderr: "no outcome configured"))

    func execute(_ command: CLICommand) async throws -> Data {
        invocations.append(command.argv)
        switch next {
        case .success(let data): return data
        case .failure(let error): throw error
        }
    }
}
