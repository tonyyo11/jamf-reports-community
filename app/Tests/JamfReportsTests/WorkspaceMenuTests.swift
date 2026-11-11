import XCTest
@testable import JamfReports

@MainActor
final class WorkspaceMenuTests: XCTestCase {
    private nonisolated(unsafe) var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", tempRoot.path, 1)
    }

    override func tearDown() {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func store(active: String) throws -> WorkspaceStore {
        for name in ["a", "c"] {
            let dir = tempRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("jamf_cli:\n  profile: \(name)\n".utf8)
                .write(to: dir.appendingPathComponent("config.yaml"))
        }
        let store = WorkspaceStore(
            demoMode: false, tickerRegistrar: StubTickerRegistrar(), jamfCLIProfileNames: { [] })
        store.profiles = ["a", "b", "c"].map {
            JamfCLIProfile(name: $0, url: "", schedules: 0, status: .ok)
        }
        store.profile = active
        return store
    }

    func testTheMenuListsWorkspacesOnly() throws {
        XCTAssertEqual(try store(active: "a").workspaceMenuProfiles.map(\.name), ["a", "c"])
    }

    func testTheMenuKeepsTheActiveProfileWithNoFolder() throws {
        XCTAssertEqual(try store(active: "b").workspaceMenuProfiles.map(\.name), ["a", "b", "c"])
    }

    func testDemoModeListsEveryProfile() {
        let store = WorkspaceStore(demoMode: true)
        XCTAssertEqual(store.workspaceMenuProfiles.count, store.profiles.count)
    }

    func testInitialProfilePrefersAWorkspace() {
        let list = ["a", "b"].map {
            JamfCLIProfile(name: $0, url: "", schedules: 0, status: .ok)
        }
        XCTAssertEqual(
            WorkspaceStore.initialProfile(in: list, hasWorkspace: { $0 == "b" })?.name, "b")
        XCTAssertEqual(
            WorkspaceStore.initialProfile(in: list, hasWorkspace: { _ in false })?.name, "a")
    }
}
