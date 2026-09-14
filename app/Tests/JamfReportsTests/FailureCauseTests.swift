import XCTest
@testable import JamfReports

/// Spec 2026-09-12 §9.2, first matching rule wins. Message strings marked "tester log" are
/// captures with IDs zeroed; the rest are jamf-cli 1.29.0 source strings (spec §6.1) until
/// the tester's captures replace them.
final class FailureCauseTests: XCTestCase {

    private func envelope(_ message: String, hint: String? = nil, exit: Int32) -> Data {
        var object: [String: Any] = [
            "error": "request failed", "message": message,
            "exitCode": Int(exit), "exitCodeName": "error",
        ]
        if let hint { object["hint"] = hint }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func classify(_ message: String, hint: String? = nil, exit: Int32) -> FailureCause {
        FailureCause.classify(exitCode: exit, stdout: envelope(message, hint: hint, exit: exit))
    }

    private let gatewayHint = "grant the Jamf Platform API integration these permissions in "
        + "Jamf Account: Compliance > Compliance Benchmarks: Read (compliance-benchmarks:read); "
        + "Inventory > Devices: Read (devices:read). Names are as the permission picker shows "
        + "them: <map URL>"

    // Rule 1

    func testOwnershipForbiddenIsAScopeRejectionEvenWithAPermissionHint() {
        let cause = classify("permission denied (HTTP 403): {\"code\":\"OWNERSHIP_FORBIDDEN\"}",
                             hint: gatewayHint, exit: 5)
        XCTAssertEqual(cause.kind, .scopeRejected, "rule 1 must win over rule 5")
    }

    func testScopeMismatchHintIsAScopeRejection() {
        let hint = "The credential's scope level does not match the scope header sent."
        XCTAssertEqual(classify("forbidden", hint: hint, exit: 5).kind, .scopeRejected)
    }

    // Rule 2 (tester log)

    func testEnvironmentNotFoundIsAnUnknownEnvironment() {
        let message = "API request failed with status 404 Not Found, traceId 0000000000000000 "
            + "(method=GET, url=https://us.api.jamfcloud.com/compliance-benchmarks/v1/benchmarks)"
            + ": [ENVIRONMENT_NOT_FOUND] Environment '00000000-0000-0000-0000-000000000000' "
            + "not found."
        XCTAssertEqual(classify(message, exit: 4).kind, .unknownEnvironment)
    }

    // Rule 3

    func testGatewayEdgeBlockIsRetryable() {
        let cause = classify("request blocked at the Jamf gateway edge (HTTP 403)", exit: 5)
        XCTAssertEqual(cause.kind, .edgeBlocked)
        XCTAssertFalse(cause.isPermanent)
    }

    // Rule 4

    func testUnservedEndpointNoteBeatsThePermissionHint() {
        let hint = gatewayHint + " The Jamf Platform gateway does not serve this endpoint"
        XCTAssertEqual(classify("permission denied (HTTP 403)", hint: hint, exit: 5).kind,
                       .notServed)
    }

    func testExitEightIsNotServed() {
        XCTAssertEqual(classify("refused by policy", exit: 8).kind, .notServed)
    }

    // Rules 5–7

    func testGatewayHintNamesThePermissions() {
        let cause = classify("permission denied (HTTP 403)", hint: gatewayHint, exit: 5)
        XCTAssertEqual(cause.kind, .missingPermission)
        XCTAssertEqual(cause.names, [
            "Compliance > Compliance Benchmarks: Read (compliance-benchmarks:read)",
            "Inventory > Devices: Read (devices:read)",
        ])
    }

    func testGatewayFallbackHintNamesNothing() {
        let hint = "the Jamf Platform API integration lacks a permission this endpoint requires; "
            + "check the integration's permissions in Jamf Account — <map URL>"
        let cause = classify("permission denied (HTTP 403)", hint: hint, exit: 5)
        XCTAssertEqual(cause.kind, .missingPermission)
        XCTAssertEqual(cause.names, [])
    }

    func testJamfProHintNamesThePrivileges() {
        let hint = "Required privilege(s): Read Computers, Read Smart Computer Groups"
        let cause = classify("permission denied (HTTP 403)", hint: hint, exit: 5)
        XCTAssertEqual(cause.names, ["Read Computers", "Read Smart Computer Groups"])
    }

    func testExitFiveWithoutARecognisedHintIsStillAMissingPermission() {
        let hint = "the authenticated account lacks the required API privileges; check its API role"
        XCTAssertEqual(classify("permission denied (HTTP 403)", hint: hint, exit: 5).kind,
                       .missingPermission)
        XCTAssertEqual(FailureCause.classify(exitCode: 5, stdout: Data("oops".utf8)).kind,
                       .missingPermission)
    }

    /// `pro report update-status` exits 0 after both its fetches fail; the 403 is on stderr.
    func testASwallowed403IsAMissingPermission() {
        let cause = FailureCause.classify(exitCode: 0, stdout: Data(), sawForbiddenOnStderr: true)
        XCTAssertEqual(cause.kind, .missingPermission)
    }

    // Rule 8 (tester log)

    func testABare404OnAJamfProCommandIsOther() {
        let cause = classify(
            "resource not found (HTTP 404): GET /pro/v1/buildings?page=0&page-size=100", exit: 4)
        XCTAssertEqual(cause.kind, .other)
        XCTAssertFalse(cause.isPermanent)
    }

    // Storage shape

    func testTheHintIsCappedAtFourKilobytes() throws {
        let cause = classify("x", hint: String(repeating: "a", count: 5_000), exit: 5)
        XCTAssertEqual(try XCTUnwrap(cause.hint).utf8.count, FailureCause.hintByteLimit)
    }

    func testPermanenceFollowsSpecSection95() {
        let permanent: [FailureCause.Kind] =
            [.scopeRejected, .unknownEnvironment, .notServed, .missingPermission]
        for kind in [FailureCause.Kind.scopeRejected, .unknownEnvironment, .edgeBlocked,
                     .notServed, .missingPermission, .other] {
            let cause = FailureCause(kind: kind, names: [], hint: nil, exitCode: 5)
            XCTAssertEqual(cause.isPermanent, permanent.contains(kind), kind.rawValue)
        }
    }

    func testRoundTripsThroughJSON() throws {
        let cause = FailureCause(kind: .missingPermission, names: ["Read Computers"],
                                 hint: "Required privilege(s): Read Computers", exitCode: 5,
                                 recordedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder().encode(cause)
        XCTAssertEqual(try JSONDecoder().decode(FailureCause.self, from: data), cause)
    }
}
