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
