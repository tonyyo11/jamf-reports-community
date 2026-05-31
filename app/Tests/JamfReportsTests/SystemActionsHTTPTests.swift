import Foundation
import XCTest
@testable import JamfReports

/// v2.1.1 review item #9: SystemActions.open() fast-path was https-only;
/// an http:// Jamf Pro console URL silently no-oped via the file allow-list.
/// The fix adds http to the fast-path via `isBrowserOpenable(_:)`, which
/// open() now calls. Tests assert the helper directly — no browser launched.
///
/// Falsifiability: reverting the http addition in isBrowserOpenable changes
/// test_httpURL_withValidHost_isOpenable from true to false, failing the suite
/// without touching a browser.
final class SystemActionsHTTPTests: XCTestCase {

    func test_httpsURL_withValidHost_isOpenable() {
        let url = URL(string: "https://jamf.example.com/")!
        XCTAssertTrue(SystemActions.isBrowserOpenable(url))
    }

    func test_httpURL_withValidHost_isOpenable() {
        // On-prem Jamf Pro consoles frequently run http — this was the failing case.
        let url = URL(string: "http://jamf.internal.example.com:8443/")!
        XCTAssertTrue(SystemActions.isBrowserOpenable(url))
    }

    func test_httpURL_emptyHost_schemeStillOpenable() {
        // isBrowserOpenable classifies by scheme only; it returns true.
        // open() then gates on non-empty host and returns early — no browser launched.
        // These are two separate guards; this test covers the scheme half.
        let url = URL(string: "http:///path")!
        XCTAssertTrue(SystemActions.isBrowserOpenable(url))
    }

    func test_fileURL_isNotOpenable() {
        XCTAssertFalse(SystemActions.isBrowserOpenable(URL(fileURLWithPath: "/etc/passwd")))
    }

    func test_ftpURL_isNotOpenable() {
        let url = URL(string: "ftp://files.example.com/report.xlsx")!
        XCTAssertFalse(SystemActions.isBrowserOpenable(url))
    }

    func test_mailtoURL_isNotOpenable() {
        let url = URL(string: "mailto:admin@example.com")!
        XCTAssertFalse(SystemActions.isBrowserOpenable(url))
    }

    func test_javascriptURL_isNotOpenable() {
        let url = URL(string: "javascript:alert(1)")!
        XCTAssertFalse(SystemActions.isBrowserOpenable(url))
    }

    func test_noSchemeURL_isNotOpenable() {
        // URL(string:) with no scheme returns nil or a relative URL — either way not openable.
        if let url = URL(string: "//example.com/path") {
            XCTAssertFalse(SystemActions.isBrowserOpenable(url))
        }
    }
}
