import Foundation
import XCTest
@testable import JamfReports

/// A reveal/open of a path outside the allow-list must not fail silently — it
/// posts `.systemActionDenied` so ContentView can toast it.
final class SystemActionsDenialTests: XCTestCase {

    func testRevealOutsideAllowListReturnsFalseAndPostsNotification() {
        // /etc/hosts is real but outside the Jamf-Reports allow-list.
        let outside = URL(fileURLWithPath: "/etc/hosts")
        let expectation = expectation(forNotification: .systemActionDenied, object: nil) { note in
            (note.userInfo?["message"] as? String)?.contains("hosts") == true
        }
        let allowed = SystemActions.reveal(outside)
        XCTAssertFalse(allowed, "a path outside the allow-list must be refused")
        wait(for: [expectation], timeout: 2.0)
    }

    func testOpenNonWebSchemeIsRefusedWithNotification() {
        let bogus = URL(string: "javascript:alert(1)")!
        let expectation = expectation(forNotification: .systemActionDenied, object: nil)
        SystemActions.open(bogus)
        wait(for: [expectation], timeout: 2.0)
    }

    func testAllowedPathDoesNotPostDenial() {
        // A path inside ~/Jamf-Reports canonicalizes; reveal returns true and
        // must NOT post a denial. (It may activate Finder; harmless in CI.)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let inside = home.appendingPathComponent("Jamf-Reports")
        let denial = expectation(forNotification: .systemActionDenied, object: nil)
        denial.isInverted = true
        _ = SystemActions.reveal(inside)
        wait(for: [denial], timeout: 0.5)
    }
}
