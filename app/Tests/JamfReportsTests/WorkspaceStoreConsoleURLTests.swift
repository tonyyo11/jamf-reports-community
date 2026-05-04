import XCTest
@testable import JamfReports

/// Tests for WorkspaceStore console deep-link helpers.
///
/// WorkspaceStore is @MainActor, so all assertions run on the main actor.
@MainActor
final class WorkspaceStoreConsoleURLTests: XCTestCase {

    // MARK: - Helpers

    private func makeProfile(url: String) -> JamfCLIProfile {
        JamfCLIProfile(name: "test", url: url, schedules: 0, status: .ok)
    }

    // MARK: - Computer URLs

    func test_consoleURL_computer_validServer_returnsExpectedURL() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "https://jamf.example.com")]
        store.profile = "test"

        let url = store.consoleURL(forComputerID: 42)

        XCTAssertEqual(url?.absoluteString, "https://jamf.example.com/computers.html?id=42&o=r")
    }

    func test_consoleURL_computer_trailingSlash_noDoubleSlash() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "https://jamf.example.com/")]
        store.profile = "test"

        let url = store.consoleURL(forComputerID: 7)

        XCTAssertEqual(url?.absoluteString, "https://jamf.example.com/computers.html?id=7&o=r")
    }

    func test_consoleURL_computer_emptyServerURL_returnsNil() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "")]
        store.profile = "test"

        XCTAssertNil(store.consoleURL(forComputerID: 1))
    }

    func test_consoleURL_computer_malformedServerURL_returnsNil() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "not a url")]
        store.profile = "test"

        XCTAssertNil(store.consoleURL(forComputerID: 1))
    }

    func test_consoleURL_computer_noMatchingProfile_returnsNil() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "https://jamf.example.com")]
        store.profile = "other"

        XCTAssertNil(store.consoleURL(forComputerID: 1))
    }

    // MARK: - Mobile device URLs

    func test_consoleURL_mobileDevice_validServer_returnsExpectedURL() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "https://jamf.example.com")]
        store.profile = "test"

        let url = store.consoleURL(forMobileDeviceID: 99)

        XCTAssertEqual(url?.absoluteString, "https://jamf.example.com/mobileDevices.html?id=99&o=r")
    }

    func test_consoleURL_mobileDevice_trailingSlash_noDoubleSlash() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "https://jamf.example.com/")]
        store.profile = "test"

        let url = store.consoleURL(forMobileDeviceID: 5)

        XCTAssertEqual(url?.absoluteString, "https://jamf.example.com/mobileDevices.html?id=5&o=r")
    }

    func test_consoleURL_mobileDevice_emptyServerURL_returnsNil() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "")]
        store.profile = "test"

        XCTAssertNil(store.consoleURL(forMobileDeviceID: 1))
    }

    func test_consoleURL_mobileDevice_malformedServerURL_returnsNil() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "not a url")]
        store.profile = "test"

        XCTAssertNil(store.consoleURL(forMobileDeviceID: 1))
    }
}
