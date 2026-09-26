import XCTest
@testable import JamfReports

final class OperationErrorRoutingTests: XCTestCase {
    func test_collectFailed_routesThroughExplainExitForItsCode() {
        let msg = CLIBridge.explainOperationError(
            ReportEngineError.collectFailed(kind: "security", exitCode: 3), operation: "Refresh")
        XCTAssertEqual(msg, CLIBridge.explainExit(3, operation: "Refresh"))
    }

    func test_authExpired_routesAsUnauthorized() {
        let msg = CLIBridge.explainOperationError(
            ReportEngineError.authExpired(profile: "p", failedCount: 4), operation: "Collect")
        XCTAssertEqual(msg, CLIBridge.explainExit(CLIBridge.exitCodeUnauthorized, operation: "Collect"))
    }

    func test_collectDead_routesAsGeneralFailure() {
        let msg = CLIBridge.explainOperationError(
            ReportEngineError.collectDead(profile: "p", failedCount: 9), operation: "Collect")
        XCTAssertEqual(msg, CLIBridge.explainExit(1, operation: "Collect"))
    }

    func test_unknownError_fallsBackToLocalizedDescription() {
        struct E: LocalizedError { var errorDescription: String? { "boom" } }
        XCTAssertEqual(CLIBridge.explainOperationError(E(), operation: "Refresh"),
                       "Refresh failed — boom")
    }

    func test_collectDeadWithNoReadableSource_routesAsPermissionDenied() {
        let msg = CLIBridge.explainOperationError(
            ReportEngineError.collectDead(profile: "p", failedCount: 9, cause: .noPermission),
            operation: "Collect")
        XCTAssertEqual(msg, CLIBridge.explainExit(CLIBridge.exitCodePermissionDenied,
                                                  operation: "Collect"))
    }

    func test_collectDeadWithARejectedID_namesTheID() {
        let error = ReportEngineError.collectDead(profile: "p", failedCount: 9, cause: .rejectedID)
        XCTAssertTrue(CLIBridge.explainOperationError(error, operation: "Collect")
            .contains("environment or tenant ID"))
        XCTAssertTrue(error.errorDescription?.contains("environment or tenant ID") ?? false)
    }
}
