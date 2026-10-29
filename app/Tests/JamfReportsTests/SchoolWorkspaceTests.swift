import Foundation
import XCTest
@testable import JamfReports

/// A Jamf School workspace in the GUI (2.10): it collects only School data, which no Jamf Pro
/// screen reads, so the Jamf Pro tabs, health expectations, report templates and exports are
/// left out instead of showing states that can never fill.
@MainActor
final class SchoolWorkspaceTests: XCTestCase {

    private nonisolated(unsafe) var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-school-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", tempRoot.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func profile(_ name: String, product: JamfCLIProduct) -> JamfCLIProfile {
        JamfCLIProfile(name: name, url: "", schedules: 0, status: .ok, product: product)
    }

    // MARK: - Sidebar

    func testASchoolWorkspaceKeepsOnlyTheTabsItCanFill() {
        let school = TabVisibility().limited(toSchool: true)
        XCTAssertTrue(school.isVisible(.overview))
        XCTAssertTrue(school.isVisible(.sources))
        XCTAssertTrue(school.isVisible(.reports))
        XCTAssertFalse(school.isVisible(.devices), "a core tab, but School has its own Devices")
        XCTAssertTrue(school.isVisible(.schoolDevices))
        XCTAssertFalse(school.isVisible(.patch))
        XCTAssertFalse(school.isVisible(.backups), "pro backup is Jamf Pro's")
        XCTAssertFalse(school.isVisible(.protectDashboard))

        let pro = TabVisibility().limited(toSchool: false)
        let proTabs = Tab.allCases.filter { $0 != .schoolDevices }
        XCTAssertTrue(proTabs.allSatisfy { pro.isVisible($0) })
        XCTAssertFalse(pro.isVisible(.schoolDevices))
    }

    /// Protect works with Jamf School (2.11): its tab shows on a School workspace only while
    /// Protect is connected, and a Jamf Pro workspace is unchanged.
    func testASchoolWorkspaceShowsProtectOnlyWhenConnected() {
        let connected = TabVisibility().limited(toSchool: true, protectConnected: true)
        XCTAssertTrue(connected.isVisible(.protectDashboard))
        XCTAssertFalse(connected.isVisible(.patch))
        XCTAssertFalse(TabVisibility().limited(toSchool: true).isVisible(.protectDashboard))
        XCTAssertFalse(TabVisibility.parse("protectDashboard")
            .limited(toSchool: true, protectConnected: true)
            .isVisible(.protectDashboard), "the user's hidden choice still applies")
        XCTAssertFalse(TabVisibility().limited(toSchool: false, protectConnected: true)
            .isVisible(.schoolDevices))
    }

    func testTheStoreReadsWhetherTheActiveWorkspaceHasProtect() throws {
        let workspace = tempRoot.appendingPathComponent("campus", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config = workspace.appendingPathComponent("config.yaml")
        try Data("school_cli:\n  enabled: true\n".utf8).write(to: config)
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [profile("campus", product: .school)]
        store.profile = "campus"
        store.refreshProtectConnection()
        XCTAssertFalse(store.tabVisibility(hiddenRaw: "").isVisible(.protectDashboard))
        try Data("school_cli:\n  enabled: true\nprotect:\n  enabled: true\n  profile: p\n".utf8)
            .write(to: config)
        store.refreshProtectConnection()
        XCTAssertTrue(store.protectConnected)
        XCTAssertTrue(store.tabVisibility(hiddenRaw: "").isVisible(.protectDashboard))
    }

    func testTheProductFilterIsNeverStoredAsTheUsersChoice() {
        var visibility = TabVisibility.parse("patch")
        let raw = visibility.serialize()
        visibility = visibility.limited(toSchool: true)
        XCTAssertEqual(visibility.serialize(), raw)
        XCTAssertFalse(TabVisibility.parse(raw).limited(toSchool: false).isVisible(.patch))
    }

    func testTheStoreKnowsTheActiveWorkspaceIsSchool() {
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [profile("campus", product: .school), profile("prod", product: .pro)]
        store.profile = "campus"
        XCTAssertTrue(store.isSchoolWorkspace)
        XCTAssertFalse(store.tabVisibility(hiddenRaw: "").isVisible(.devices))
        store.profile = "prod"
        XCTAssertFalse(store.isSchoolWorkspace)
        XCTAssertTrue(store.tabVisibility(hiddenRaw: "").isVisible(.devices))
    }

    // MARK: - Health expectations

    func testASchoolWorkspaceExpectsOnlySOFAFromTheJamfProKinds() throws {
        let workspace = tempRoot.appendingPathComponent("campus", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("school_cli:\n  enabled: true\n  profile: \"campus\"\n".utf8)
            .write(to: workspace.appendingPathComponent("config.yaml"))
        XCTAssertEqual(
            WorkspaceStore.expectedKinds(profile: "campus", jamfCLIVersion: "1.33.0", auth: nil),
            ["sofa"])
        try Data("school_cli:\n  enabled: true\n  profile: \"campus\"\njamf_cli:\n  collect_skip: [sofa]\n"
            .utf8).write(to: workspace.appendingPathComponent("config.yaml"))
        XCTAssertEqual(
            WorkspaceStore.expectedKinds(profile: "campus", jamfCLIVersion: "1.33.0", auth: nil),
            [])

        let pro = tempRoot.appendingPathComponent("prod", isDirectory: true)
        try FileManager.default.createDirectory(at: pro, withIntermediateDirectories: true)
        try Data("jamf_cli:\n  profile: \"prod\"\n".utf8)
            .write(to: pro.appendingPathComponent("config.yaml"))
        XCTAssertTrue(
            WorkspaceStore.expectedKinds(profile: "prod", jamfCLIVersion: "1.33.0", auth: nil)
                .contains("computers"))
    }

    /// Protect follows a School collect (2.11), so a connected Protect's kinds are owed there.
    func testASchoolWorkspaceWithProtectConnectedExpectsTheProtectKinds() throws {
        let workspace = tempRoot.appendingPathComponent("campus", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("""
        school_cli:
          enabled: true
          profile: "campus"
        protect:
          enabled: true
          profile: "campus-protect"
        """.utf8).write(to: workspace.appendingPathComponent("config.yaml"))
        func expected(_ product: JamfCLIProduct, pinAllows: Bool = true) -> [String] {
            WorkspaceStore.expectedKinds(
                profile: "campus", jamfCLIVersion: "1.33.0", auth: nil,
                protectResolved: { _ in .init(authMethod: "oauth2", isTenantLevel: false,
                                               product: product) },
                protectPinAllows: { _ in pinAllows })
        }
        XCTAssertEqual(expected(.protect), ["sofa"] + DataFreshnessHealth.protectKinds)
        XCTAssertEqual(expected(.school), ["sofa"], "a protect.profile of another product is skipped")
        XCTAssertEqual(expected(.protect, pinAllows: false), ["sofa"])
    }

    // MARK: - Generate

    func testTheGenerateSheetOffersTheSchoolWorkbookAndItsCSVFolderOnly() {
        let state = GenerateSheetState()
        state.schoolWorkspace = true
        XCTAssertTrue(state.schoolMode)
        XCTAssertEqual(state.selectedTypes, [.xlsx])
        XCTAssertEqual(state.offeredTypes, [.xlsx, .csvFolder])
        XCTAssertEqual(state.offeredTemplates.map(\.identifier), [SchoolTemplate().identifier])

        let pro = GenerateSheetState()
        XCTAssertFalse(pro.schoolMode)
        XCTAssertEqual(pro.offeredTypes, Array(GenerateOutputType.allCases))
    }
}
