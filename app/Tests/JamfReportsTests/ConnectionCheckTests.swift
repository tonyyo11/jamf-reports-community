import XCTest
@testable import JamfReports

/// One test per row of spec 2026-09-12 §10.4's result table, plus when step 2 runs. The bare
/// 404 and ENVIRONMENT_NOT_FOUND strings follow the tester's log; the 403 strings are jamf-cli
/// 1.29.0 source strings (spec §6.1).
final class ConnectionCheckTests: XCTestCase {

    private func failure(
        _ exit: Int32, _ message: String, hint: String? = nil
    ) -> ConnectionCheck.Attempt {
        var object: [String: Any] = [
            "error": "request failed", "message": message,
            "exitCode": Int(exit), "exitCodeName": "error",
        ]
        if let hint { object["hint"] = hint }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return (exitCode: exit, stdout: data)
    }

    private func success(_ stdout: String) -> ConnectionCheck.Attempt {
        (exitCode: 0, stdout: Data(stdout.utf8))
    }

    private var bare404: ConnectionCheck.Attempt {
        failure(4, "resource not found (HTTP 404): GET /pro/v1/jamf-pro-version")
    }

    private var unknownEnvironment: ConnectionCheck.Attempt {
        failure(4, "API request failed with status 404 Not Found, traceId 0000000000000000 "
            + "(method=GET, url=https://us.api.jamfcloud.com/devices/v1/devices): "
            + "[ENVIRONMENT_NOT_FOUND] Environment '00000000-0000-0000-0000-000000000000' "
            + "not found.")
    }

    func testAJamfProVersionAcceptsTheID() {
        let verdict = ConnectionCheck.verdict(version: success(#"{"version":"11.25.0"}"#),
                                              probe: nil)
        XCTAssertEqual(verdict, .accepted(jamfProVersion: "11.25.0"))
        XCTAssertFalse(verdict.blocksContinue)
    }

    func testOwnershipForbiddenOnStepOneBlocks() {
        let version = failure(5, "permission denied (HTTP 403): {\"code\":\"OWNERSHIP_FORBIDDEN\"}")
        let verdict = ConnectionCheck.verdict(version: version, probe: nil)
        XCTAssertEqual(verdict, .rejectedID(.scopeRejected))
        XCTAssertTrue(verdict.blocksContinue)
    }

    func testUnknownEnvironmentOnStepTwoBlocks() {
        XCTAssertEqual(ConnectionCheck.verdict(version: bare404, probe: unknownEnvironment),
                       .rejectedID(.unknownEnvironment))
    }

    func testAnEmptyPageOnStepTwoMeansNoJamfProInThisEnvironment() {
        XCTAssertEqual(ConnectionCheck.verdict(version: bare404, probe: success("[]")),
                       .noJamfPro)
    }

    /// The gateway resolves scope before capability, so a permission error proves the ID.
    func testAPermissionErrorOnStepTwoStillProvesTheID() {
        let hint = "the Jamf Platform API integration lacks a permission this endpoint "
            + "requires; check the integration's permissions in Jamf Account — <map URL>"
        let probe = failure(5, "permission denied (HTTP 403)", hint: hint)
        XCTAssertEqual(ConnectionCheck.verdict(version: bare404, probe: probe), .noJamfPro)
    }

    /// Organization level sends no scope header; every scoped call answers 400.
    func testAMissingScopeHeaderOnStepOneBlocks() {
        let version = failure(1, "request failed (HTTP 400): {\"httpStatus\":400,\"traceId\":"
            + "\"00000000000000000000000000000000\",\"errors\":[{\"code\":"
            + "\"REQUEST_CONTEXT_NOT_PROVIDED\",\"field\":\"\",\"description\":"
            + "\"The request context could not be detected.\",\"id\":\"\"}]}")
        let verdict = ConnectionCheck.verdict(version: version, probe: nil)
        XCTAssertEqual(verdict, .rejectedID(.scopeRejected))
        XCTAssertTrue(verdict.blocksContinue)
    }

    /// `404 TENANT_NOT_FOUND` (jamfplatform-go-sdk WIRE-FACTS, 2026-09-01): the environment exists
    /// but holds no tenant. Its description is not captured yet; the check reads only the code.
    func testNoTenantOnStepTwoMeansNoJamfProInThisEnvironment() {
        let probe = failure(4, "API request failed with status 404 Not Found, traceId "
            + "0000000000000000 (method=GET, "
            + "url=https://us.api.jamfcloud.com/devices/v1/devices): [TENANT_NOT_FOUND]")
        XCTAssertEqual(ConnectionCheck.verdict(version: bare404, probe: probe), .noJamfPro)
    }

    /// `devices` answers TENANT_NOT_FOUND even for an environment the integration does not own.
    func testTheNoJamfProWarningDoesNotSayTheIDWasAccepted() {
        XCTAssertFalse(ConnectionCheck.Verdict.noJamfPro.message.contains("accepted"))
    }

    func testAnythingElseIsUndecided() {
        XCTAssertEqual(ConnectionCheck.verdict(version: nil, probe: nil),
                       .undecided(exitCode: nil))
        XCTAssertEqual(ConnectionCheck.verdict(version: failure(1, "timeout"), probe: nil),
                       .undecided(exitCode: 1))
        XCTAssertEqual(ConnectionCheck.verdict(version: bare404, probe: failure(1, "timeout")),
                       .undecided(exitCode: 1))
        XCTAssertFalse(ConnectionCheck.Verdict.undecided(exitCode: 1).blocksContinue)
    }

    func testOnlyABare404RunsStepTwo() {
        XCTAssertTrue(ConnectionCheck.needsProbe(bare404))
        XCTAssertFalse(ConnectionCheck.needsProbe(unknownEnvironment))
        XCTAssertFalse(ConnectionCheck.needsProbe(success("{}")))
        XCTAssertFalse(ConnectionCheck.needsProbe(failure(1, "timeout")))
        XCTAssertFalse(ConnectionCheck.needsProbe(nil))
    }

    func testRunAsksTheSecondQuestionOnlyAfterABare404() async {
        let twoStep = RecordingRunner(version: bare404, probe: success("[]"))
        let verdict = await ConnectionCheck.run(profile: "p", specNames: true,
                                                runner: twoStep.runner)
        XCTAssertEqual(verdict, .noJamfPro)
        XCTAssertEqual(twoStep.calls.count, 2)
        XCTAssertTrue(twoStep.calls.last?.contains("platform-devices") ?? false)

        let oneStep = RecordingRunner(version: success(#"{"version":"11.25.0"}"#), probe: nil)
        _ = await ConnectionCheck.run(profile: "p", specNames: true, runner: oneStep.runner)
        XCTAssertEqual(oneStep.calls.count, 1)
    }

    func testArgumentsFollowTheInstalledJamfCLI() {
        XCTAssertEqual(ConnectionCheck.versionArguments(profile: "p", specNames: true),
                       ["-p", "p", "pro", "jamf-pro-version", "list", "--output", "json"])
        XCTAssertEqual(ConnectionCheck.versionArguments(profile: "p", specNames: false)[3],
                       "jamf-pro-versions")
        XCTAssertTrue(ConnectionCheck.probeArguments(profile: "p")
            .contains(#"serialNumber=="jrc-connection-check""#),
            "the filter is one argv element; no shell ever parses it")
    }

    func testTheVersionIsReadFromAnObjectOrAnArray() {
        XCTAssertEqual(ConnectionCheck.jamfProVersion(in: Data(#"{"version":"11.2"}"#.utf8)),
                       "11.2")
        XCTAssertEqual(ConnectionCheck.jamfProVersion(in: Data(#"[{"version":"11.3"}]"#.utf8)),
                       "11.3")
        XCTAssertNil(ConnectionCheck.jamfProVersion(in: Data("not json".utf8)))
    }
}

private final class RecordingRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let version: ConnectionCheck.Attempt?
    private let probe: ConnectionCheck.Attempt?

    init(version: ConnectionCheck.Attempt?, probe: ConnectionCheck.Attempt?) {
        self.version = version
        self.probe = probe
    }

    var calls: [[String]] { lock.withLock { recorded } }

    var runner: ConnectionCheck.Runner {
        { arguments in
            self.lock.withLock { self.recorded.append(arguments) }
            return arguments.contains("platform-devices") ? self.probe : self.version
        }
    }
}
