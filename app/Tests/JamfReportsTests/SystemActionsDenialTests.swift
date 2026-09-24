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

    /// A folder the app creates on first use — run logs before the first run —
    /// is inside the allow-list; the toast used to say it was outside.
    func testOpenMissingFolderInsideAllowListSaysItDoesNotExistYet() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let missing = home.appendingPathComponent(
            "Jamf-Reports/jrc-missing-\(UUID().uuidString)/automation/logs", isDirectory: true)
        let expectation = expectation(forNotification: .systemActionDenied, object: nil) { note in
            let message = note.userInfo?["message"] as? String ?? ""
            return message.contains("does not exist yet") && !message.contains("outside")
        }
        SystemActions.openFolder(missing)
        wait(for: [expectation], timeout: 2.0)
    }

    func testOpenFolderOutsideAllowListStillSaysOutside() {
        let outside = URL(fileURLWithPath: "/etc", isDirectory: true)
        let expectation = expectation(forNotification: .systemActionDenied, object: nil) { note in
            (note.userInfo?["message"] as? String)?.contains("outside the app's allowed") == true
        }
        SystemActions.openFolder(outside)
        wait(for: [expectation], timeout: 2.0)
    }

    func testRefusalMessagesNameTheirCause() {
        let logs = URL(fileURLWithPath: "/Users/admin/Jamf-Reports/acme/automation/logs")
        XCTAssertEqual(
            SystemActions.refusalMessage(.missingFolder, url: logs, verb: "open"),
            "Can't open \"logs\" — the folder does not exist yet.")
        XCTAssertTrue(
            SystemActions.refusalMessage(.outsideAllowedFolders, url: logs, verb: "reveal")
                .hasPrefix("Can't reveal \"logs\" — it's outside the app's allowed folders"))
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
