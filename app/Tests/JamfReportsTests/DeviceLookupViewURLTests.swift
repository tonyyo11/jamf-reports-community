import XCTest
@testable import JamfReports

/// Tests for `WorkspaceStore.computerListURL()` added in Unit 6.
@MainActor
final class DeviceLookupViewURLTests: XCTestCase {

    private func makeProfile(url: String) -> JamfCLIProfile {
        JamfCLIProfile(name: "test", url: url, schedules: 0, status: .ok)
    }

    func test_computerListURL_returnsComputersHtml_noID() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "https://jamf.example.com")]
        store.profile = "test"

        let url = store.computerListURL()

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.path, "/computers.html")
        XCTAssertNil(url?.query)
    }

    func test_computerListURL_withTrailingSlash_noDoubleSlash() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "https://jamf.example.com/")]
        store.profile = "test"

        let url = store.computerListURL()

        XCTAssertNotNil(url)
        XCTAssertFalse(url?.absoluteString.contains("//computers") == true)
    }

    func test_computerListURL_bareHost_prefixesHttps() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "acme.jamfcloud.com")]
        store.profile = "test"

        let url = store.computerListURL()

        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "https")
    }

    func test_computerListURL_noProfile_returnsNil() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = []
        store.profile = "nonexistent"

        let url = store.computerListURL()

        XCTAssertNil(url)
    }

    func test_computerListURL_emptyURL_returnsNil() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "")]
        store.profile = "test"

        let url = store.computerListURL()

        XCTAssertNil(url)
    }
}
