import XCTest
@testable import JamfReports

/// In build 1478 jamf-cli went from 1.29.0 to 1.32.0 while a collect was still running. An
/// install or update now holds the tick lock the collects hold, so each refuses to start under
/// the other, and a scheduled run's lock refuses an update too.
@MainActor
final class JamfCLIUpdateGuardTests: XCTestCase {

    private let profile = "alpha"
    private let updating = "jamf-cli is being updated — try again when it finishes"

    private func makeStore() throws -> (store: WorkspaceStore, lock: TickLock) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-update-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(profile, isDirectory: true),
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
        store.profile = profile
        store.resolveAuthMethod = { _ in nil }
        return (store, lock)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private let installed = JamfCLIInstaller.UpdateResult(succeeded: true, message: "updated")

    // MARK: - An update does not start under a collect or a tick

    func testAnUpdateIsRefusedWhileACollectRuns() async throws {
        _ = try makeStore()
        let started = Flag()
        let finish = Flag()
        defer { finish.set() }
        let collect = Task { @MainActor in
            try await CLIBridge.holdingTickLock { () -> Int32 in
                started.set()
                while !finish.isSet { try await Task.sleep(for: .milliseconds(10)) }
                return 0
            }
        }
        try await waitUntil { started.isSet }

        let ran = Flag()
        let installed = installed
        let result = await JamfCLIInstaller.refusingWhileBusy {
            ran.set()
            return installed
        }
        XCTAssertFalse(ran.isSet, "nothing is installed under a running collect")
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.refused)
        XCTAssertTrue(result.message.contains("a refresh is running"), result.message)
        XCTAssertTrue(CLIBridge.collectRunning, "the collect is untouched")

        finish.set()
        _ = try await collect.value
    }

    func testAnUpdateIsRefusedWhileAScheduledRunHoldsTheLock() async throws {
        let (_, lock) = try makeStore()
        let ran = Flag()
        let installed = installed
        try await whileAnotherProcessHolds(lock) {
            let result = await JamfCLIInstaller.refusingWhileBusy {
                ran.set()
                return installed
            }
            XCTAssertTrue(result.refused)
            XCTAssertTrue(result.message.contains("a scheduled run is in progress"), result.message)
        }
        XCTAssertFalse(ran.isSet)
    }

    func testAnUpdateRunsWhenNothingElseDoesAndFreesTheLock() async throws {
        let (_, lock) = try makeStore()
        let result = await JamfCLIInstaller.refusingWhileBusy {
            let pid = (try? String(contentsOf: lock.url, encoding: .utf8)) ?? "no lock"
            return JamfCLIInstaller.UpdateResult(succeeded: true, message: pid)
        }
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(result.refused)
        XCTAssertEqual(result.message, String(getpid()), "a tick queues behind the update")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.url.path))
        XCTAssertNil(CLIBridge.holdPurpose)
    }

    // MARK: - A collect does not start under an update

    func testNoCollectStartsWhileAnUpdateRuns() async throws {
        let (store, lock) = try makeStore()
        let started = Flag()
        let finish = Flag()
        defer { finish.set() }
        let installed = installed
        let update = Task { @MainActor in
            await JamfCLIInstaller.refusingWhileBusy {
                started.set()
                while !finish.isSet { try? await Task.sleep(for: .milliseconds(10)) }
                return installed
            }
        }
        try await waitUntil { started.isSet }
        XCTAssertTrue(CLIBridge.toolUpdateRunning)
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), String(getpid()))

        // Manual: refused before any state changes.
        let collected = Flag()
        await store.runTierRefresh([.refresh]) { _, _, _ in
            collected.set()
            return 0
        }
        XCTAssertFalse(collected.isSet)
        XCTAssertEqual(store.toast?.message, updating)
        XCTAssertEqual(store.toast?.style, .info)
        XCTAssertNil(store.globalStatus)
        XCTAssertFalse(store.isCollectInFlight(for: profile))

        // The bridge: every GUI collect passes here.
        do {
            _ = try await CLIBridge().collect(profile: profile, force: true) { _ in }
            XCTFail("the collect must be refused")
        } catch {
            XCTAssertEqual(error as? CLIBridgeError, .toolUpdateInProgress)
            XCTAssertEqual(error.localizedDescription, updating)
        }

        // Automatic: stands down.
        XCTAssertTrue(store.automaticCollectMustWait(for: [profile]))
        XCTAssertTrue(store.automaticCollectMustWait(for: ["beta"]))

        // A second update says so rather than installing twice.
        let second = await JamfCLIInstaller.refusingWhileBusy { installed }
        XCTAssertEqual(second.message, "jamf-cli is already being updated.")

        finish.set()
        let result = await update.value
        XCTAssertTrue(result.succeeded)

        // Once it is over the same collect starts.
        store.toast = nil
        await store.runTierRefresh([.refresh]) { _, _, _ in
            collected.set()
            return 0
        }
        XCTAssertTrue(collected.isSet)
    }

    func testTheRefusalIsInformationAndLeavesNoRunRecord() {
        XCTAssertTrue(CLIBridgeError.toolUpdateInProgress.isCollectRefusal)
        XCTAssertEqual(
            WorkspaceStore.collectFailureToast(CLIBridgeError.toolUpdateInProgress,
                                               operation: "Refresh").style, .info)
        XCTAssertEqual(
            DeviceLookupView.refreshRefusalToast(for: CLIBridgeError.toolUpdateInProgress)?.message,
            updating)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isSet: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
