import Foundation
import XCTest
@testable import JamfReports

// Regression coverage for the "set up a schedule" getting-started rule
// (epic #207 E4). A blanket `isManaged` OR previously ticked EVERY profile
// under managed automation with no exclusion awareness; the fix scopes the
// disjunct to non-excluded profiles only.
final class OverviewScheduleCoverageTests: XCTestCase {

    func testPerProfileAgentCoversRegardlessOfPolicy() {
        XCTAssertTrue(scheduleCovered(hasAgent: true, policyIsManaged: false, excluded: false))
        XCTAssertTrue(scheduleCovered(hasAgent: true, policyIsManaged: false, excluded: true))
    }

    func testManagedAndNotExcludedCoversWithNoAgent() {
        XCTAssertTrue(scheduleCovered(hasAgent: false, policyIsManaged: true, excluded: false))
    }

    func testManagedButExcludedDoesNotCoverWithNoAgent() {
        XCTAssertFalse(scheduleCovered(hasAgent: false, policyIsManaged: true, excluded: true))
    }

    func testUnmanagedWithNoAgentDoesNotCover() {
        XCTAssertFalse(scheduleCovered(hasAgent: false, policyIsManaged: false, excluded: false))
    }
}
