import XCTest
@testable import JamfReports

/// A report generated while a collect ran read the day's summary beside snapshots the collect
/// had already replaced, so its tiles and its text disagreed. Generate now waits: both the
/// Generate Reports sheet and the Overview's Generate Report ask `generateRefusal` first.
@MainActor
final class GenerateDuringCollectTests: XCTestCase {

    private func makeStore() throws -> (store: WorkspaceStore, lock: TickLock) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-generate-wait-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("alpha", isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let lock = useTemporaryTickLock()
        let store = WorkspaceStore(
            demoMode: false, tickerRegistrar: StubTickerRegistrar(),
            jamfCLIProfileNames: { [] }, discoverProfiles: { [] }, jamfCLIInstallation: { nil })
        store.profile = "alpha"
        return (store, lock)
    }

    func testGenerateStartsWhenNothingCollects() throws {
        let (store, _) = try makeStore()
        XCTAssertNil(store.generateRefusal())
    }

    /// Any profile's collect counts: the bridge runs one collect at a time for the whole app.
    func testACollectOnAnyProfileRefusesGenerate() throws {
        let (store, _) = try makeStore()
        store.beginCollect(for: "beta")
        defer { store.endCollect(for: "beta") }
        XCTAssertEqual(store.generateRefusal(), .collectInProgress)
    }

    func testAScheduledRunHoldingTheLockRefusesGenerate() async throws {
        let (store, lock) = try makeStore()
        try await whileAnotherProcessHolds(lock) {
            XCTAssertEqual(store.generateRefusal(), .tickLockHeld)
        }
        XCTAssertNil(store.generateRefusal())
    }

    func testTheMessageSaysWhyTheReportWaits() {
        let message = WorkspaceStore.generateRefusalMessage(.collectInProgress)
        XCTAssertTrue(message.hasPrefix("A refresh is already running"), message)
        XCTAssertTrue(message.hasSuffix("would mix old and new figures."), message)
    }
}
