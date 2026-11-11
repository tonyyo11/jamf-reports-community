import XCTest
@testable import JamfReports

/// P5 final review: automatic collects, menus and lists stay on workspaces (D24).
@MainActor
final class P5ReviewFixTests: XCTestCase {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("p5-fix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func makeWorkspace(_ name: String, in root: URL) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("jamf_cli:\n  profile: \(name)\n".utf8)
            .write(to: dir.appendingPathComponent("config.yaml"))
    }

    private func profile(_ name: String) -> JamfCLIProfile {
        JamfCLIProfile(name: name, url: "", schedules: 0, status: .ok)
    }

    func testAutomaticRefreshNeedsAWorkspaceFolder() throws {
        let root = try tempRoot()
        let store = WorkspaceStore(demoMode: false)
        XCTAssertFalse(store.canRefreshAutomatically(profileSlug: "acme"))
        XCTAssertTrue(store.canRefresh(profileSlug: "acme"), "a person's collect may initialize")
        try makeWorkspace("acme", in: root)
        XCTAssertTrue(store.canRefreshAutomatically(profileSlug: "acme"))
    }

    func testConnectionGroupingLeavesOutAFolderlessInactiveProfile() throws {
        let root = try tempRoot()
        try makeWorkspace("a", in: root)
        let connections = root.appendingPathComponent("connections.json")
        let store = WorkspaceStore(
            demoMode: false, tickerRegistrar: StubTickerRegistrar(), jamfCLIProfileNames: { [] },
            connectionStore: ConnectionStore(url: connections))
        try ConnectionStore(url: connections).upsert(Connection(
            name: "Acme", region: .eu, level: .environment,
            members: [.init(profile: "a", scopeID: "x", product: .pro),
                      .init(profile: "nofolder", scopeID: "y", product: .pro)],
            createdAt: Date(timeIntervalSince1970: 1)))
        store.reloadConnections()
        store.profiles = [profile("a"), profile("nofolder")]
        store.profile = "a"
        let grouping = store.connectionGrouping
        XCTAssertEqual(grouping.sections.flatMap { $0.entries.map(\.profile.name) }, ["a"])
        XCTAssertTrue(grouping.ungrouped.isEmpty)
    }

    func testActiveProfileFallbackPrefersAWorkspace() {
        let result = WorkspaceStore.activeProfile(
            keeping: "gone", in: [profile("a"), profile("b")],
            hasWorkspace: { $0 == "b" }, connectedProfiles: { _ in [] })
        XCTAssertEqual(result, "b")
    }

    func testListableWorkspaceNamesKeepsPolicyNamedFolderlessProfiles() {
        var policy = AutomationPolicy()
        policy.excludedWorkspaces = ["old"]
        policy.reportGroups = [ReportGroup(name: "g", workspaces: ["grouped"])]
        let names = ProfileService.listableWorkspaceNames(
            ["has", "old", "grouped", "bare"].map(profile), policy: policy,
            hasWorkspace: { $0 == "has" })
        XCTAssertEqual(names, ["has", "old", "grouped"])
    }

    func testLongReasonIsShownWhole() {
        let reason = String(repeating: "r", count: 200)
        let row = AddSheetPlan.UnassignedProfile(
            name: "x", product: .pro, url: "", use: .unavailable(reason), authMethod: "")
        XCTAssertEqual(UnassignedProfilesCardText.reason(for: row), reason)
        let ok = AddSheetPlan.UnassignedProfile(
            name: "x", product: .pro, url: "", use: .newWorkspace, authMethod: "")
        XCTAssertNil(UnassignedProfilesCardText.reason(for: ok))
    }
}
