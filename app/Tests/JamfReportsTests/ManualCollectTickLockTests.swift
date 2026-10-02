import XCTest
@testable import JamfReports

/// #226 5c: a manual GUI collect takes the tick lock, so a `--tick` wake during it exits
/// queued instead of starting a second jamf-cli fan-out against the profile, and a manual
/// collect asked for while a tick runs does not start.
@MainActor
final class ManualCollectTickLockTests: XCTestCase {

    private let profile = "alpha"

    /// A throwaway workspaces root, which in DEBUG also moves Application Support (the
    /// default lock, the run-now markers) under it.
    private func useTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-manual-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    /// A store whose tick lock is a temporary file. Init runs no jamf-cli.
    private func makeStore() throws -> (store: WorkspaceStore, lock: TickLock) {
        let root = try useTemporaryRoot()
        let lock = TickLock(url: root.appendingPathComponent("test-tick.lock"))
        let store = WorkspaceStore(
            demoMode: false, tickerRegistrar: StubTickerRegistrar(),
            jamfCLIProfileNames: { [] }, discoverProfiles: { [] }, jamfCLIInstallation: { nil })
        store.profile = profile
        store.tickLock = { lock }
        return (store, lock)
    }

    private func lockExists(_ lock: TickLock) -> Bool {
        FileManager.default.fileExists(atPath: lock.url.path)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Held for the collect

    /// While the collect runs the lock names this process, which the app's own automatic
    /// collects must not read as another process: only `isCollectInFlight` stands them down.
    func testAManualCollectHoldsTheLockAsThisProcessAndReleasesIt() async throws {
        let (store, lock) = try makeStore()
        let seen = Recorder()
        await store.runTierRefresh([.refresh]) { profile, _, _ in
            seen.record((try? String(contentsOf: lock.url, encoding: .utf8)) ?? "no lock")
            let elsewhere = await store.tickLockHeldElsewhere()
            let otherWaits = await store.automaticCollectMustWait(for: ["beta"])
            let ownWaits = await store.automaticCollectMustWait(for: [profile])
            seen.record("elsewhere=\(elsewhere)")
            seen.record("other profile waits=\(otherWaits)")
            seen.record("own profile waits=\(ownWaits)")
            return 0
        }
        XCTAssertEqual(seen.values, [
            String(getpid()), "elsewhere=false",
            "other profile waits=false", "own profile waits=true",
        ])
        XCTAssertFalse(lockExists(lock), "the lock is released when the collect ends")
        XCTAssertEqual(store.manualCollectLockHolds, 0)
        XCTAssertEqual(store.toast?.message, "Data refreshed")
    }

    func testTheLockIsReleasedWhenTheCollectThrows() async throws {
        let (store, lock) = try makeStore()
        await store.runTierRefresh([.refresh]) { _, _, _ in
            XCTAssertTrue(FileManager.default.fileExists(atPath: lock.url.path))
            throw CLIBridgeError.executableNotFound
        }
        XCTAssertFalse(lockExists(lock))
        XCTAssertEqual(store.manualCollectLockHolds, 0)
        XCTAssertTrue(lock.acquire(pid: 4242, isAlive: { _ in true }), "a tick can take it now")
    }

    func testTheLockIsReleasedWhenTheCollectIsCancelled() async throws {
        let (store, lock) = try makeStore()
        let started = Flag()
        let refresh = Task { @MainActor in
            await store.runTierRefresh([.refresh]) { _, _, _ in
                started.set()
                try await Task.sleep(for: .seconds(60))
                return 0
            }
        }
        try await waitUntil { started.isSet }
        XCTAssertTrue(lockExists(lock), "held while the collect runs")
        refresh.cancel()
        await refresh.value
        XCTAssertFalse(lockExists(lock))
        XCTAssertEqual(store.manualCollectLockHolds, 0)
    }

    /// Collect now during a running Refresh all: the first to finish must not remove the
    /// file under the other, or a tick could start beside the one still running.
    func testOverlappingManualCollectsShareTheLockUntilTheLastEnds() async throws {
        let (store, lock) = try makeStore()
        let started = Flag()
        let finish = Flag()
        defer { finish.set() }
        let refresh = Task { @MainActor in
            await store.runTierRefresh([.refresh]) { _, _, _ in
                started.set()
                while !finish.isSet { try await Task.sleep(for: .milliseconds(10)) }
                return 0
            }
        }
        try await waitUntil { started.isSet }
        await store.runFirstCollect { _, _ in 0 }
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), String(getpid()),
                       "the refresh still running keeps the lock")
        finish.set()
        await refresh.value
        XCTAssertFalse(lockExists(lock))
        XCTAssertEqual(store.manualCollectLockHolds, 0)
    }

    /// Release stops the hold's keep-alive, so it cannot go on refreshing a lock file a
    /// tick writes later.
    func testReleasingAHoldStopsItsHeartbeat() throws {
        let (store, lock) = try makeStore()
        let hold = try XCTUnwrap(store.takeTickLockForManualCollect())
        let heartbeat = try XCTUnwrap(hold.heartbeat)
        XCTAssertFalse(heartbeat.isCancelled)
        XCTAssertTrue(lockExists(lock))
        store.releaseTickLock(hold)
        XCTAssertTrue(heartbeat.isCancelled)
        XCTAssertFalse(lockExists(lock))
    }

    /// The tick needs the same file, so when it cannot be written no tick can start beside
    /// the collect; refusing would turn a broken Application Support into a dead button.
    func testAnUnwritableLockLetsTheCollectRunWithoutIt() async throws {
        let (store, lock) = try makeStore()
        let unwritable = TickLock(url: lock.url.deletingLastPathComponent()
            .appendingPathComponent("missing/tick.lock"))
        store.tickLock = { unwritable }
        let collected = Recorder()
        await store.runTierRefresh([.refresh]) { profile, _, _ in
            collected.record(profile)
            return 0
        }
        XCTAssertEqual(collected.values, [profile])
        XCTAssertEqual(store.manualCollectLockHolds, 0)
    }

    // MARK: - Refused while a tick runs

    func testNoManualCollectStartsWhileAnotherLiveProcessHoldsTheLock() async throws {
        let (store, lock) = try makeStore()
        let tick = try spawnLiveForeignProcess()
        defer {
            tick.terminate()
            tick.waitUntilExit()
        }
        XCTAssertTrue(lock.acquire(pid: tick.processIdentifier))
        let collected = Recorder()
        let busy = "A scheduled run is in progress — try again when it finishes"

        await store.runTierRefresh([.refresh]) { _, _, _ in
            collected.record("tier")
            return 0
        }
        XCTAssertEqual(store.toast?.message, busy)
        store.toast = nil

        store.staleHeavyTiers = [.inventory]
        await store.runHeavyTierRefresh { _, _, _ in
            collected.record("heavy")
            return 0
        }
        XCTAssertEqual(store.toast?.message, busy)
        XCTAssertEqual(store.staleHeavyTiers, [.inventory], "a refused refresh re-probes nothing")
        store.toast = nil

        await store.runFirstCollect { _, _ in
            collected.record("first")
            return 0
        }
        XCTAssertEqual(store.toast?.message, busy)

        XCTAssertEqual(collected.values, [])
        XCTAssertNil(store.globalStatus)
        XCTAssertFalse(store.isCollectInFlight(for: profile))
        XCTAssertEqual(store.manualCollectLockHolds, 0)
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8),
                       String(tick.processIdentifier), "the tick's lock is left alone")
        XCTAssertEqual(TickRunner.pendingRunNowLabels(), [], "nothing is queued")
    }

    // MARK: - The tick's side

    /// A wake that finds a manual collect holding the lock queues exactly as it does behind
    /// another tick: exit 75, the run-now marker kept, the refusal stamped. The GUI is a
    /// spawned process here, since a tick in this process would read the lock as its own.
    func testATickDuringAManualCollectExitsQueuedAndKeepsItsMarker() async throws {
        _ = try useTemporaryRoot()
        let gui = try spawnLiveForeignProcess()
        defer {
            gui.terminate()
            gui.waitUntilExit()
        }
        let lock = TickLock(url: TickLock.defaultURL)
        XCTAssertTrue(lock.acquire(pid: gui.processIdentifier))
        let label = "\(LaunchAgentWriter.labelPrefix).\(profile).daily"

        let exit = await runTick(arguments: ["--tick", "--now", label])

        XCTAssertEqual(exit, TickRunner.queuedExitCode)
        XCTAssertEqual(TickRunner.pendingRunNowLabels(), [label])
        XCTAssertNotNil(TickLock.takeBlockedSince())
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8),
                       String(gui.processIdentifier))
    }
}

/// A live process that is not this one, for "held by another live process". The caller
/// terminates it and waits for it.
func spawnLiveForeignProcess() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["60"]
    try process.run()
    return process
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var values: [String] { lock.withLock { recorded } }
    func record(_ value: String) { lock.withLock { recorded.append(value) } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isSet: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
