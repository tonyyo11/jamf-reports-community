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

    // MARK: - Computer group URLs

    func test_consoleURL_smartComputerGroup_returnsExpectedURL() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "https://jamf.example.com")]
        store.profile = "test"

        let url = store.consoleURL(forComputerGroupID: 11, isStatic: false)

        XCTAssertEqual(url?.absoluteString,
                       "https://jamf.example.com/smartComputerGroups.html?id=11&o=r")
    }

    func test_consoleURL_staticComputerGroup_returnsExpectedURL() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "https://jamf.example.com")]
        store.profile = "test"

        let url = store.consoleURL(forComputerGroupID: 12, isStatic: true)

        XCTAssertEqual(url?.absoluteString,
                       "https://jamf.example.com/staticComputerGroups.html?id=12&o=r")
    }

    // MARK: - Policy + profile URLs

    func test_consoleURL_policy_returnsExpectedURL() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "https://jamf.example.com")]
        store.profile = "test"

        let url = store.consoleURL(forPolicyID: 88)

        XCTAssertEqual(url?.absoluteString,
                       "https://jamf.example.com/policies.html?id=88&o=r")
    }

    func test_consoleURL_computerConfigProfile_returnsExpectedURL() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "https://jamf.example.com")]
        store.profile = "test"

        let url = store.consoleURL(forComputerConfigProfileID: 14)

        XCTAssertEqual(url?.absoluteString,
                       "https://jamf.example.com/OSXConfigurationProfiles.html?id=14&o=r")
    }

    func test_consoleURL_mobileConfigProfile_returnsExpectedURL() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "https://jamf.example.com")]
        store.profile = "test"

        let url = store.consoleURL(forMobileConfigProfileID: 27)

        XCTAssertEqual(url?.absoluteString,
                       "https://jamf.example.com/mobileDeviceConfigurationProfiles.html?id=27&o=r")
    }

    // MARK: - String-id overloads

    func test_consoleURL_computer_stringID_validDigits_returnsURL() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "https://jamf.example.com")]
        store.profile = "test"

        XCTAssertEqual(store.consoleURL(forComputerID: "42")?.absoluteString,
                       "https://jamf.example.com/computers.html?id=42&o=r")
    }

    func test_consoleURL_computer_stringID_nonNumeric_returnsNil() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "https://jamf.example.com")]
        store.profile = "test"

        XCTAssertNil(store.consoleURL(forComputerID: "abc"))
    }

    func test_consoleURL_mobileDevice_stringID_validDigits_returnsURL() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "https://jamf.example.com")]
        store.profile = "test"

        XCTAssertEqual(store.consoleURL(forMobileDeviceID: "9")?.absoluteString,
                       "https://jamf.example.com/mobileDevices.html?id=9&o=r")
    }

    // MARK: - Bare-hostname handling

    func test_consoleURL_computer_bareHostname_prependsHTTPS() {
        // ProfileService.displayURL stores bare hostnames (no scheme) for sidebar display.
        // The consoleURL helper must prepend https:// rather than returning nil.
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [makeProfile(url: "jamf.example.com")]
        store.profile = "test"

        let url = store.consoleURL(forComputerID: 42)

        XCTAssertNotNil(url, "bare hostname must resolve to a URL, not nil")
        XCTAssertEqual(url?.absoluteString, "https://jamf.example.com/computers.html?id=42&o=r")
    }
}
