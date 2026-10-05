import XCTest
@testable import JamfReports

/// The Limited / Full Admin chip on Data Sources is a local label that nothing reads yet;
/// its caption, tooltip and elevate dialog must not promise a gate.
@MainActor
final class SourcesScopeExplanationTests: XCTestCase {

    func testExplanationNamesTheScopeAndPromisesNoGate() {
        for scope in APIScope.allCases {
            let text = SourcesView.scopeExplanation(scope)
            XCTAssertTrue(text.hasPrefix(scope.displayName), text)
            XCTAssertTrue(
                text.contains("does not change what the jamf-cli credentials can do"), text)
            XCTAssertTrue(text.contains("nothing in the app is gated on it yet"), text)
            XCTAssertFalse(text.contains("unlocks"), text)
        }
    }
}
