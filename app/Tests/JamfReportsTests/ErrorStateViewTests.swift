import XCTest
@testable import JamfReports

@MainActor
final class ErrorStateViewTests: XCTestCase {
    func test_initWithoutRetry() {
        _ = ErrorStateView(title: "Failed", message: "corrupt file")
    }

    func test_initWithCommands() {
        _ = ErrorStateView(title: "Failed", message: "x", commands: ["jamf-cli pro auth"])
    }

    func test_retryActionIsInvoked() {
        var fired = false
        let v = ErrorStateView(title: "Failed", message: "x", retry: { fired = true })
        v.invokeRetryForTesting()
        XCTAssertTrue(fired)
    }
}
