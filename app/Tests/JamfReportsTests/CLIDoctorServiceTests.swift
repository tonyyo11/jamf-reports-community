import Foundation
import XCTest
@testable import JamfReports

/// Tests for `CLIDoctorService.parse`, `DoctorReport.health` derivation, and the
/// executor-backed `run()` outcome mapping. No live binary required.
@MainActor
final class CLIDoctorServiceTests: XCTestCase {

    // MARK: - parse (pure)

    func testParseFullReportDecodesProfileCredentialsAndConnectivity() throws {
        let report = try XCTUnwrap(CLIDoctorService.parse(Data(Self.healthyJSON.utf8)))
        XCTAssertEqual(report.version, "1.18.0")
        XCTAssertEqual(report.configPresent, true)
        XCTAssertEqual(report.profile?.name, "prod")
        XCTAssertEqual(report.profile?.url, "https://jamf.example.com:8443")
        XCTAssertEqual(report.profile?.authMethod, "oauth2")
        XCTAssertEqual(report.profile?.credentials?.count, 2)
        XCTAssertEqual(report.profile?.credentials?.first?.field, "client-id")
        XCTAssertEqual(report.profile?.credentials?.first?.resolved, true)
        XCTAssertEqual(report.connectivity?.statusCode, 302)
        XCTAssertEqual(report.connectivity?.latencyMs, 222)
    }

    func testParseToleratesMissingBlocks() throws {
        // doctor omits `profile` and `connectivity` entirely when none resolve.
        let json = #"{"version":"1.18.0","configPresent":false}"#
        let report = try XCTUnwrap(CLIDoctorService.parse(Data(json.utf8)))
        XCTAssertEqual(report.configPresent, false)
        XCTAssertNil(report.profile)
        XCTAssertNil(report.connectivity)
    }

    func testParseReturnsNilForMalformedJSON() {
        XCTAssertNil(CLIDoctorService.parse(Data("not json at all".utf8)))
        XCTAssertNil(CLIDoctorService.parse(Data("[]".utf8)), "doctor is an object, not an array")
    }

    // MARK: - health derivation

    func testHealthHealthyWhenReachableAndCredentialsResolved() throws {
        let report = try XCTUnwrap(CLIDoctorService.parse(Data(Self.healthyJSON.utf8)))
        XCTAssertEqual(report.health, .healthy)
        XCTAssertTrue(report.credentialsAllResolved)
    }

    func testHealthUnauthorizedOn401() throws {
        let report = try XCTUnwrap(CLIDoctorService.parse(Data(Self.unauthorizedJSON.utf8)))
        XCTAssertEqual(report.health, .unauthorized)
    }

    func testHealthUnreachableWhenNoStatus() throws {
        // Connectivity block present but no statusCode (probe never completed).
        let json = """
        {"version":"1.18.0","profile":{"name":"prod","credentials":[
        {"field":"client-id","resolved":true}]},"connectivity":{"url":"https://x"}}
        """
        let report = try XCTUnwrap(CLIDoctorService.parse(Data(json.utf8)))
        XCTAssertEqual(report.health, .unreachable)
    }

    func testHealthNoProfileWhenProfileAbsent() throws {
        let report = try XCTUnwrap(CLIDoctorService.parse(Data(#"{"configPresent":true}"#.utf8)))
        XCTAssertEqual(report.health, .noProfile)
    }

    func testHealthCredentialsUnresolvedWhenReachableButAKeyMissing() throws {
        let json = """
        {"profile":{"name":"prod","credentials":[
        {"field":"client-id","resolved":true},
        {"field":"client-secret","resolved":false}]},
        "connectivity":{"statusCode":200,"latencyMs":50}}
        """
        let report = try XCTUnwrap(CLIDoctorService.parse(Data(json.utf8)))
        XCTAssertEqual(report.health, .credentialsUnresolved)
        XCTAssertFalse(report.credentialsAllResolved)
    }

    func testCredentialsAllResolvedFalseForEmptyList() throws {
        let json = #"{"profile":{"name":"prod","credentials":[]},"connectivity":{"statusCode":200}}"#
        let report = try XCTUnwrap(CLIDoctorService.parse(Data(json.utf8)))
        XCTAssertFalse(report.credentialsAllResolved, "no resolvable credentials cannot authenticate")
        XCTAssertEqual(report.health, .credentialsUnresolved)
    }

    // MARK: - run() outcome mapping

    func testRunReturnsReportOnSuccess() async {
        let service = CLIDoctorService(executor: CannedDoctorExecutor(
            result: .success(Data(Self.healthyJSON.utf8))))
        let outcome = await service.run(profile: "prod")
        guard case .report(let report) = outcome else {
            return XCTFail("expected .report, got \(outcome)")
        }
        XCTAssertEqual(report.health, .healthy)
    }

    func testRunMapsBinaryNotFoundToNotInstalled() async {
        let service = CLIDoctorService(executor: CannedDoctorExecutor(
            result: .failure(.binaryNotFound("jamf-cli"))))
        let outcome = await service.run(profile: "prod")
        XCTAssertEqual(outcome, .notInstalled)
    }

    func testRunSurfacesStderrOnNonZeroExit() async {
        let service = CLIDoctorService(executor: CannedDoctorExecutor(
            result: .failure(.nonZeroExit(code: 1, stderr: "boom"))))
        let outcome = await service.run(profile: "prod")
        XCTAssertEqual(outcome, .failed(reason: "boom"))
    }

    func testRunReportsParseFailureOnGarbageOutput() async {
        let service = CLIDoctorService(executor: CannedDoctorExecutor(
            result: .success(Data("garbage".utf8))))
        let outcome = await service.run(profile: "prod")
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
    }

    // MARK: - Fixtures

    /// Shape verified against `jamf-cli 1.18.0 doctor --output json` (hostname
    /// genericised; real run returned an internal FQDN). 302 = reachable.
    private static let healthyJSON = """
    {
      "version": "1.18.0",
      "configPath": "/Users/admin/.config/jamf-cli/config.yaml",
      "configPresent": true,
      "profile": {
        "name": "prod",
        "source": "config default-profile",
        "url": "https://jamf.example.com:8443",
        "effectiveUrl": "https://jamf.example.com:8443",
        "urlSource": "profile",
        "authMethod": "oauth2",
        "credentials": [
          {"field": "client-id", "reference": "keychain:jamf-cli/prod/client-id",
           "resolved": true, "fingerprint": "98f2••••"},
          {"field": "client-secret", "reference": "keychain:jamf-cli/prod/client-secret",
           "resolved": true, "fingerprint": "G1q_••••"}
        ]
      },
      "connectivity": {"url": "https://jamf.example.com:8443", "statusCode": 302, "latencyMs": 222}
    }
    """

    /// Verified against the dummy tenant — credentials resolve but the HEAD
    /// probe returns 401. doctor exits 0, so the JSON is still emitted.
    private static let unauthorizedJSON = """
    {
      "version": "1.18.0",
      "configPresent": true,
      "profile": {
        "name": "dummy",
        "url": "https://dummy.jamfcloud.com",
        "authMethod": "oauth2",
        "credentials": [
          {"field": "client-id", "resolved": true, "fingerprint": "2b7e••••"},
          {"field": "client-secret", "resolved": true, "fingerprint": "o0dw••••"}
        ]
      },
      "connectivity": {"url": "https://dummy.jamfcloud.com", "statusCode": 401, "latencyMs": 226}
    }
    """
}

/// Minimal `CLIExecutor` returning canned data or a canned error — keeps these
/// tests CI-safe (no jamf-cli binary required).
private final class CannedDoctorExecutor: CLIExecutor, @unchecked Sendable {
    enum Result {
        case success(Data)
        case failure(CLIExecutorError)
    }
    private let canned: Result
    init(result: Result) { canned = result }

    func execute(_ command: CLICommand) async throws -> Data {
        switch canned {
        case .success(let data): return data
        case .failure(let err): throw err
        }
    }
}
