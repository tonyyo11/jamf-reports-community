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
        XCTAssertFalse(school.isVisible(.devices), "a core tab, but School has no device data")
        XCTAssertFalse(school.isVisible(.patch))
        XCTAssertFalse(school.isVisible(.backups), "pro backup is Jamf Pro's")
        XCTAssertFalse(school.isVisible(.protectDashboard))

        let pro = TabVisibility().limited(toSchool: false)
        XCTAssertTrue(Tab.allCases.allSatisfy { pro.isVisible($0) })
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

    func testASchoolWorkspaceExpectsNoJamfProKinds() throws {
        let workspace = tempRoot.appendingPathComponent("campus", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("school_cli:\n  enabled: true\n  profile: \"campus\"\n".utf8)
            .write(to: workspace.appendingPathComponent("config.yaml"))
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

    // MARK: - Generate

    func testTheGenerateSheetOffersTheSchoolWorkbookOnly() {
        let state = GenerateSheetState()
        state.schoolWorkspace = true
        XCTAssertTrue(state.schoolMode)
        XCTAssertEqual(state.selectedTypes, [.xlsx])
        XCTAssertEqual(state.offeredTypes, [.xlsx])
        XCTAssertEqual(state.offeredTemplates.map(\.identifier), [SchoolTemplate().identifier])

        let pro = GenerateSheetState()
        XCTAssertFalse(pro.schoolMode)
        XCTAssertEqual(pro.offeredTypes, Array(GenerateOutputType.allCases))
    }
}
