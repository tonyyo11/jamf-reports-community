import XCTest
@testable import JamfReports

/// The Config screen writes every key it models from memory, so a save over a config.yaml
/// that changed on disk since the screen read it would put the old values back.
@MainActor
final class WorkspaceStoreConfigSaveTests: XCTestCase {
    private let profile = "typed-acme"
    private let typed = "thresholds:\n  stale_device_days: 30\noutput:\n  output_dir: Reports\n"

    private func makeStore() async throws -> (store: WorkspaceStore, config: URL) {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("jrc-config-save-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let config = workspace.appendingPathComponent("config.yaml")
        try typed.write(to: config, atomically: true, encoding: .utf8)
        let previousRoot = ProcessInfo.processInfo.environment["JRC_TEST_WORKSPACES_ROOT"]
        let sentinel = UserDefaults.standard.string(forKey: WorkspaceMigration.sentinelKey)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            if let previousRoot {
                setenv("JRC_TEST_WORKSPACES_ROOT", previousRoot, 1)
            } else {
                unsetenv("JRC_TEST_WORKSPACES_ROOT")
            }
            UserDefaults.standard.set(sentinel, forKey: WorkspaceMigration.sentinelKey)
            try? FileManager.default.removeItem(at: root)
        }
        let store = WorkspaceStore(
            demoMode: false, tickerRegistrar: StubTickerRegistrar(),
            jamfCLIProfileNames: { [] }, discoverProfiles: { [] }, jamfCLIInstallation: { nil })
        store.profile = profile
        try await store.loadConfig()
        return (store, config)
    }

    private func assertRefused(_ store: WorkspaceStore, _ message: String) async {
        do {
            try await store.saveConfig()
            XCTFail(message)
        } catch ConfigService.ConfigError.changedOnDisk {
        } catch {
            XCTFail("expected changedOnDisk, got \(error)")
        }
    }

    func testASaveOverAFileEditedSinceLoadWritesNothing() async throws {
        let (store, config) = try await makeStore()
        let edited = typed.replacingOccurrences(of: "30", with: "45")
            + "# typed after the screen loaded\n"
        try edited.write(to: config, atomically: true, encoding: .utf8)
        store.configState.outputDir = "Edited in the app"

        await assertRefused(store, "a save over a hand edit must not write")
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), edited)
    }

    func testAModificationDateAloneCountsAsAChange() async throws {
        let (store, config) = try await makeStore()
        let later = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: config.path)

        await assertRefused(store, "same size, newer date: still changed")
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), typed)
    }

    /// The app's own writes move the baseline: a second save, and the Save a re-scaffold
    /// asks for, still write.
    func testTheAppsOwnWritesDoNotCountAsChanges() async throws {
        let (store, config) = try await makeStore()
        store.configState.staleDeviceDays = "40"
        try await store.saveConfig()
        store.configState.staleDeviceDays = "41"
        try await store.saveConfig()

        var merged = try ConfigService.load(profile: profile).state
        merged.columns["serial_number"] = "Serial"
        _ = try ConfigService.save(profile: profile, state: merged, existingDocument: nil)
        store.adoptScaffoldedColumns(from: merged)
        store.configState.staleDeviceDays = "42"
        try await store.saveConfig()

        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("stale_device_days: 42"), text)
        XCTAssertTrue(text.contains("serial_number: Serial"), text)
    }

    func testAReloadAfterARefusalLetsTheNextSaveWrite() async throws {
        let (store, config) = try await makeStore()
        try typed.replacingOccurrences(of: "Reports", with: "Typed Reports")
            .write(to: config, atomically: true, encoding: .utf8)
        store.configState.staleDeviceDays = "45"
        await assertRefused(store, "changed on disk")

        try await store.loadConfig()
        XCTAssertEqual(store.configState.outputDir, "Typed Reports")
        XCTAssertEqual(store.configState.staleDeviceDays, "30", "a reload drops unsaved edits")
        store.configState.staleDeviceDays = "45"
        try await store.saveConfig()

        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("stale_device_days: 45"), text)
        XCTAssertTrue(text.contains("output_dir: Typed Reports"), text)
    }
}
