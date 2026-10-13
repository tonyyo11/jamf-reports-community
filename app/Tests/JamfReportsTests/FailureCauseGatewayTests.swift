import XCTest
@testable import JamfReports

/// Two jamf-cli v1.33.0 gateway errors that fell to `.other`: the refusal of the retired
/// `apigw.jamf.com` host (`refuseRetiredGatewayURL`, exit 2) and the gateway's 400
/// `INVALID_REQUEST_CONTEXT_TYPE`. Strings are jamf-cli's own, from its source and tests.
final class FailureCauseGatewayTests: XCTestCase {

    private func classify(_ message: String, hint: String? = nil, exit: Int32) -> FailureCause {
        var object: [String: Any] = [
            "error": "USAGE", "message": message, "exitCode": Int(exit), "exitCodeName": "USAGE",
        ]
        if let hint { object["hint"] = hint }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return FailureCause.classify(exitCode: exit, stdout: data)
    }

    private let retired = "https://eu.apigw.jamf.com is the retired Jamf Platform gateway and "
        + "does not serve the GA API paths.\nSet url: https://eu.api.jamfcloud.com in this "
        + "profile (jamf-cli config path prints the file), or re-run `jamf-cli platform setup`."

    func testTheRetiredGatewayHostIsAPermanentCauseWithTheFix() {
        let cause = classify(retired, exit: 2)
        XCTAssertEqual(cause.kind, .retiredGateway)
        XCTAssertTrue(cause.isPermanent, "an hourly retry cannot change the profile's URL")
        XCTAssertTrue(cause.hint?.contains("us, eu or apac api.jamfcloud.com host") == true)
        XCTAssertTrue(cause.label.contains("apigw.jamf.com"))
    }

    func testAnotherExitTwoIsStillOther() {
        XCTAssertEqual(classify("required flag(s) \"url\" not set", exit: 2).kind, .other)
    }

    func testTheContextTypeMismatchIsAScopeRejectionWithAHint() {
        let message = "sources: API request failed with status 400: [INVALID_REQUEST_CONTEXT_TYPE] "
            + "Request context type 'tenant' is invalid. Expected any of 'environment'."
        let cause = classify(message, exit: 1)
        XCTAssertEqual(cause.kind, .scopeRejected)
        XCTAssertTrue(cause.isPermanent)
        XCTAssertTrue(cause.hint?.contains("different scope level") == true)
    }

    func testJamfCLIsOwnHintWinsOverTheDefault() {
        let cause = classify(
            "[INVALID_REQUEST_CONTEXT_TYPE] bad", hint: "use environment scope", exit: 1)
        XCTAssertEqual(cause.hint, "use environment scope")
    }

    func testTheNewKindSurvivesTheStateFile() throws {
        let cause = classify(retired, exit: 2)
        let data = try JSONEncoder().encode(cause)
        XCTAssertEqual(try JSONDecoder().decode(FailureCause.self, from: data), cause)
    }
}
