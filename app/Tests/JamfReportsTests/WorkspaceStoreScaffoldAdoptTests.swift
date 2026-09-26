import XCTest
@testable import JamfReports

/// Config → Re-scaffold merges CSV columns into config.yaml on disk. The loaded config has to
/// take the merge too: the Columns tab kept the old mappings, and the Save the re-scaffold toast
/// asks for wrote them back over it.
@MainActor
final class WorkspaceStoreScaffoldAdoptTests: XCTestCase {

    // `nonisolated(unsafe)`: the combination OnboardingDemoExitTests uses for a
    // @MainActor XCTestCase with stored properties set in setUp.
    private nonisolated(unsafe) var testRoot: URL!

    override func setUp() {
        super.setUp()
        testRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ScaffoldAdopt-\(UUID().uuidString)", isDirectory: true)
        let workspaces = testRoot.appendingPathComponent("Jamf-Reports", isDirectory: true)
        let acme = workspaces.appendingPathComponent("acme", isDirectory: true)
        try? FileManager.default.createDirectory(at: acme, withIntermediateDirectories: true)
        let yaml = "jamf_cli:\n  profile: \"acme\"\ncolumns:\n  serial_number: \"Serial Number\"\n"
        try? Data(yaml.utf8).write(to: acme.appendingPathComponent("config.yaml"))
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        UserDefaults.standard.removeObject(forKey: WorkspaceStore.forceDemoModeKey)
    }

    override func tearDown() {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
        super.tearDown()
    }

    func testAdoptingTheMergeKeepsOtherUnsavedEdits() async throws {
        let store = WorkspaceStore(demoMode: false, jamfCLIProfileNames: { [] })
        store.profile = "acme"
        try await store.loadConfig()
        XCTAssertEqual(store.configState.columns["serial_number"], "Serial Number")
        let savedDays = store.configState.staleDeviceDays
        store.configState.staleDeviceDays = savedDays + "5"

        var merged = try ConfigService.load(profile: "acme").state
        merged.columns["serial_number"] = "Serial"
        merged.columns["computer_name"] = "Computer Name"
        store.adoptScaffoldedColumns(from: merged)

        XCTAssertEqual(store.configState.columns["serial_number"], "Serial")
        XCTAssertEqual(store.columnMappings.first { $0.key == "computer_name" }?.value,
                       "Computer Name", "the Columns tab shows the merge")
        XCTAssertEqual(store.configState.staleDeviceDays, savedDays + "5",
                       "an unrelated unsaved edit stays")
        store.configState.staleDeviceDays = savedDays
        XCTAssertFalse(store.hasUnsavedChanges,
                       "the merged columns are the saved baseline, not a pending edit")
    }
}
