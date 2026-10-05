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

    // MARK: - The other report writers: PDF, inventory CSV, Trends' archive

    /// Reports > Export PDF and Export Inventory CSV ask before opening the save panel.
    func testAWriterIsRefusedDuringACollectWithTheOverviewsToast() throws {
        let (store, _) = try makeStore()
        store.beginCollect(for: "beta")
        defer { store.endCollect(for: "beta") }
        XCTAssertTrue(store.reportMustWait())
        XCTAssertEqual(store.toast?.message,
                       WorkspaceStore.generateRefusalMessage(.collectInProgress))
        XCTAssertEqual(store.toast?.style, .info)
        XCTAssertFalse(store.beginReportRun(for: "alpha"))
        XCTAssertFalse(store.isRunInProgress(for: "alpha"), "a refused run leaves no mark")
    }

    func testAWriterIsRefusedWhileAScheduledRunHoldsTheLock() async throws {
        let (store, lock) = try makeStore()
        try await whileAnotherProcessHolds(lock) {
            XCTAssertFalse(store.beginReportRun(for: "alpha"))
            XCTAssertEqual(store.toast?.message,
                           WorkspaceStore.generateRefusalMessage(.tickLockHeld))
        }
        store.toast = nil
        XCTAssertFalse(store.reportMustWait())
        XCTAssertNil(store.toast)
    }

    func testAWriterMarksTheProfileUntilItEnds() throws {
        let (store, _) = try makeStore()
        XCTAssertTrue(store.beginReportRun(for: "alpha"))
        XCTAssertTrue(store.isRunInProgress(for: "alpha"))
        XCTAssertFalse(store.beginReportRun(for: "alpha"))
        XCTAssertEqual(store.toast?.message,
                       "Another run is already in progress for profile 'alpha' — skipped")
        XCTAssertEqual(store.toast?.style, .danger)
        store.clearRunInProgress(for: "alpha")
        XCTAssertTrue(store.beginReportRun(for: "alpha"))
    }

    /// The writer takes the lock itself, and a collect that starts after the save panel
    /// closed is a refusal shown as information, not a failed PDF.
    func testAWriterHoldsTheLockAndAFailureToastTellsARefusalFromAFailure() async throws {
        let (_, lock) = try makeStore()
        let code = try await CLIBridge.holdingGenerate { () -> Int32 in
            XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), String(getpid()))
            return 0
        }
        XCTAssertEqual(code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.url.path))

        let refused = WorkspaceStore.exportFailureToast(
            CLIBridgeError.collectInProgress, operation: "PDF generation")
        XCTAssertEqual(refused.style, .info)
        XCTAssertEqual(refused.message,
                       "A refresh is already running — try again when it finishes")
        let failed = WorkspaceStore.exportFailureToast(
            CLIBridgeError.executableNotFound, operation: "CSV export")
        XCTAssertEqual(failed.style, .danger)
        XCTAssertTrue(failed.message.hasPrefix("CSV export failed · "), failed.message)
    }

    func testTheMessageSaysWhyTheReportWaits() {
        let message = WorkspaceStore.generateRefusalMessage(.collectInProgress)
        XCTAssertTrue(message.hasPrefix("A refresh is already running"), message)
        XCTAssertTrue(message.hasSuffix("would mix old and new figures."), message)
    }
}
