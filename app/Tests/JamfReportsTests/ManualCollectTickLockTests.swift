import XCTest
@testable import JamfReports

/// #226 5c: every GUI collect holds the tick lock through `CLIBridge.collect`, so a `--tick`
/// wake during one exits queued instead of starting a second jamf-cli fan-out against the
/// profile, and a GUI collect asked for while a tick runs does not start.
@MainActor
final class ManualCollectTickLockTests: XCTestCase {

    private let profile = "alpha"
    private let busy = "A scheduled run is in progress — try again when it finishes"

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

    /// A store on a temporary root and tick lock. Neither init nor the re-probes after a
    /// collect run jamf-cli.
    private func makeStore() throws -> (store: WorkspaceStore, lock: TickLock) {
        _ = try useTemporaryRoot()
        let lock = useTemporaryTickLock()
        let store = WorkspaceStore(
            demoMode: false, tickerRegistrar: StubTickerRegistrar(),
            jamfCLIProfileNames: { [] }, discoverProfiles: { [] }, jamfCLIInstallation: { nil })
        store.profile = profile
        store.resolveAuthMethod = { _ in nil }
        return (store, lock)
    }

    private func lockExists(_ lock: TickLock) -> Bool {
        FileManager.default.fileExists(atPath: lock.url.path)
    }

    private func modificationDate(_ lock: TickLock) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: lock.url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// After a hold ended, a tick takes the lock: no beat left running may touch its file.
    private func assertNoBeatOutlivesTheHold(_ lock: TickLock) async throws {
        XCTAssertTrue(lock.acquire(pid: 4242, isAlive: { _ in true }))
        let old = Date().addingTimeInterval(-10 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: lock.url.path)
        try await Task.sleep(for: .milliseconds(150))
        let modified = try modificationDate(lock)
        XCTAssertLessThan(abs(modified.timeIntervalSince(old)), 1, "a beat outlived its hold")
    }

    /// The re-probes after a collect ask the store for the profile's auth method, so a test
    /// answers it instead of `ProfileAuthMethod.resolve` running `jamf-cli config list`.
    func testTheReprobesResolveTheAuthMethodThroughTheStore() async throws {
        let (store, _) = try makeStore()
        let asked = Recorder()
        store.resolveAuthMethod = { profile in
            asked.record(profile)
            return nil
        }
        await store.checkHeavyTierStaleness()
        await store.refreshDataFreshness()
        XCTAssertEqual(asked.values, [profile, profile])
    }

    // MARK: - The bridge's hold

    func testAHoldNamesThisProcessBeatsAndReleases() async throws {
        let (_, lock) = try makeStore()
        let seen = try await CLIBridge.holdingTickLock(beatEvery: .milliseconds(20)) {
            () -> String in
            let pid = (try? String(contentsOf: lock.url, encoding: .utf8)) ?? "no lock"
            try? FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-10 * 60)],
                ofItemAtPath: lock.url.path)
            try await Task.sleep(for: .milliseconds(150))
            let modified = (try? FileManager.default.attributesOfItem(atPath: lock.url.path))?[
                .modificationDate] as? Date
            let beat = abs(modified?.timeIntervalSinceNow ?? -600) < 5
            return "\(pid) beat=\(beat)"
        }
        XCTAssertEqual(seen, "\(getpid()) beat=true")
        XCTAssertFalse(lockExists(lock))
        XCTAssertEqual(CLIBridge.tickLockHolds, 0)
        try await assertNoBeatOutlivesTheHold(lock)
    }

    func testTheLockIsReleasedWhenTheCollectThrows() async throws {
        let (_, lock) = try makeStore()
        do {
            _ = try await CLIBridge.holdingTickLock { () -> Int32 in
                throw CLIBridgeError.executableNotFound
            }
            XCTFail("the body's error must propagate")
        } catch {
            XCTAssertEqual(error as? CLIBridgeError, .executableNotFound)
        }
        XCTAssertFalse(lockExists(lock))
        XCTAssertEqual(CLIBridge.tickLockHolds, 0)
    }

    func testTheLockAndItsBeatEndWhenTheCollectIsCancelled() async throws {
        let (_, lock) = try makeStore()
        let started = Flag()
        let collect = Task { @MainActor in
            try await CLIBridge.holdingTickLock(beatEvery: .milliseconds(20)) { () -> Int32 in
                started.set()
                try await Task.sleep(for: .seconds(60))
                return 0
            }
        }
        try await waitUntil { started.isSet }
        XCTAssertTrue(lockExists(lock), "held while the collect runs")
        collect.cancel()
        _ = await collect.result
        XCTAssertFalse(lockExists(lock))
        XCTAssertEqual(CLIBridge.tickLockHolds, 0)
        try await assertNoBeatOutlivesTheHold(lock)
    }

    /// Collect now during a running Refresh all: the first to finish must not remove the
    /// file under the other, or a tick could start beside the one still running.
    func testOverlappingHoldsShareTheLockUntilTheLastEnds() async throws {
        let (_, lock) = try makeStore()
        let started = Flag()
        let finish = Flag()
        defer { finish.set() }
        let first = Task { @MainActor in
            try await CLIBridge.holdingTickLock { () -> Int32 in
                started.set()
                while !finish.isSet { try await Task.sleep(for: .milliseconds(10)) }
                return 0
            }
        }
        try await waitUntil { started.isSet }
        _ = try await CLIBridge.holdingTickLock { () -> Int32 in 0 }
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), String(getpid()),
                       "the collect still running keeps the lock")
        finish.set()
        _ = await first.result
        XCTAssertFalse(lockExists(lock))
        XCTAssertEqual(CLIBridge.tickLockHolds, 0)
    }

    /// The tick needs the same file, so when it cannot be written no tick can start beside
    /// the collect; refusing would turn a broken Application Support into a dead button.
    func testAnUnwritableLockLetsTheCollectRunWithoutIt() async throws {
        let (_, lock) = try makeStore()
        let unwritable = TickLock(url: lock.url.deletingLastPathComponent()
            .appendingPathComponent("missing-\(UUID().uuidString)/tick.lock"))
        CLIBridge.tickLock = { unwritable }
        let ran = try await CLIBridge.holdingTickLock { () -> Bool in true }
        XCTAssertTrue(ran)
        XCTAssertEqual(CLIBridge.tickLockHolds, 0)
    }

    /// While a GUI collect holds the lock, the app's own automatic collects must not read it
    /// as another process: only `isCollectInFlight` stands them down.
    func testThisProcesssHoldIsNotAnotherProcesss() async throws {
        let (store, _) = try makeStore()
        let seen = Recorder()
        await store.runTierRefresh([.refresh]) { profile, _, _ in
            try await CLIBridge.holdingTickLock { () -> Int32 in
                let elsewhere = await CLIBridge.tickLockHeldElsewhere()
                let otherWaits = await store.automaticCollectMustWait(for: ["beta"])
                let ownWaits = await store.automaticCollectMustWait(for: [profile])
                seen.record("elsewhere=\(elsewhere)")
                seen.record("other profile waits=\(otherWaits)")
                seen.record("own profile waits=\(ownWaits)")
                return 0
            }
        }
        XCTAssertEqual(seen.values, [
            "elsewhere=false", "other profile waits=false", "own profile waits=true",
        ])
    }

    // MARK: - The store's paths refuse before touching state

    func testNoManualCollectStartsWhileAnotherLiveProcessHoldsTheLock() async throws {
        let (store, lock) = try makeStore()
        let collected = Recorder()
        try await whileAnotherProcessHolds(lock) {
            await store.runTierRefresh([.refresh]) { _, _, _ in
                collected.record("tier")
                return 0
            }
            XCTAssertEqual(store.toast?.message, busy)
            XCTAssertEqual(store.toast?.style, .info)
            store.toast = nil

            store.staleHeavyTiers = [.inventory]
            await store.runHeavyTierRefresh { _, _, _ in
                collected.record("heavy")
                return 0
            }
            XCTAssertEqual(store.toast?.message, busy)
            XCTAssertEqual(store.staleHeavyTiers, [.inventory],
                           "a refused refresh re-probes nothing")
            store.toast = nil

            await store.runFirstCollect { _, _ in
                collected.record("first")
                return 0
            }
            XCTAssertEqual(store.toast?.message, busy)
        }
        XCTAssertEqual(collected.values, [])
        XCTAssertNil(store.globalStatus)
        XCTAssertFalse(store.isCollectInFlight(for: profile))
        XCTAssertEqual(TickRunner.pendingRunNowLabels(), [], "nothing is queued")
    }

    /// A tick can take the lock between the store's check and the bridge's claim; the
    /// bridge's refusal then reads the same as the store's.
    func testARefusalFromTheBridgeShowsTheSameToast() async throws {
        let (store, _) = try makeStore()
        await store.runTierRefresh([.refresh]) { _, _, _ in
            throw CLIBridgeError.tickLockHeld
        }
        XCTAssertEqual(store.toast?.message, busy)
        XCTAssertEqual(store.toast?.style, .info)
        XCTAssertEqual(CLIBridge.explainOperationError(CLIBridgeError.tickLockHeld,
                                                       operation: "Generate"), busy)
    }

    // MARK: - Every GUI path refuses through the bridge

    /// The bridge refuses before the auth probe, so a refused collect runs no jamf-cli.
    /// Device Lookup's index refresh and both onboarding defaults call exactly this.
    func testTheBridgeCollectRefusesBeforeRunningAnything() async throws {
        let (_, lock) = try makeStore()
        let lines = Recorder()
        try await whileAnotherProcessHolds(lock) {
            do {
                _ = try await CLIBridge().collect(profile: profile, force: true) { line in
                    lines.record(line.text)
                }
                XCTFail("the collect must be refused")
            } catch {
                XCTAssertEqual(error as? CLIBridgeError, .tickLockHeld)
                XCTAssertEqual(error.localizedDescription, busy)
            }
        }
        XCTAssertEqual(lines.values, [])
        XCTAssertEqual(CLIBridge.tickLockHolds, 0)
    }

    /// The Generate sheet with Collect fresh: every type fails with the refusal in its log.
    func testGenerateWithCollectFreshReportsTheRefusal() async throws {
        let (_, lock) = try makeStore()
        let lines = Recorder()
        try await whileAnotherProcessHolds(lock) {
            let result = await CLIBridge().generateAll(
                types: [.xlsx], collectFresh: true, outputDir: nil, profile: profile
            ) { line in lines.record(line.text) }
            XCTAssertEqual(result.failed.map { $0.type }, [.xlsx])
            XCTAssertEqual(result.succeeded, [])
        }
        XCTAssertEqual(lines.values, ["[fatal] collect failed: \(busy)"])
    }

    /// Overview's Generate and Trends' Archive now: the error they toast is the refusal.
    func testCollectThenGenerateThrowsTheRefusal() async throws {
        let (_, lock) = try makeStore()
        try await whileAnotherProcessHolds(lock) {
            do {
                _ = try await CLIBridge().collectThenGenerate(
                    profile: profile, csvPath: nil, onLine: CLIBridge.noOpOnLine)
                XCTFail("the collect must be refused")
            } catch {
                XCTAssertEqual(error as? CLIBridgeError, .tickLockHeld)
            }
        }
    }

    /// The profile-switch and foreground refresh: a refusal is no failure, so it cannot
    /// push the coordinator into backoff.
    func testTheBackgroundRefreshDoesNotCountARefusalAsAFailure() async throws {
        let (_, lock) = try makeStore()
        let coordinator = RefreshCoordinator(bridge: CLIBridge())
        try await whileAnotherProcessHolds(lock) {
            coordinator.refreshIfStale(profile: profile, tier: .refresh)
            XCTAssertTrue(coordinator.isRefreshing(profile: profile, tier: .refresh))
            try await waitUntil { !coordinator.isRefreshing(profile: profile, tier: .refresh) }
        }
        XCTAssertEqual(coordinator.failureCount(profile: profile, tier: .refresh), 0)
        XCTAssertNil(coordinator.lastSuccessfulRefresh[profile])
    }

    func testOnboardingsFirstReportShowsTheRefusal() async throws {
        let (store, lock) = try makeStore()
        let flow = OnboardingFlow()
        flow.productPath = .pro
        flow.profileName = profile
        try await whileAnotherProcessHolds(lock) {
            await flow.runFirstReport(workspaceStore: store)
        }
        XCTAssertEqual(flow.lastError, busy)
        XCTAssertEqual(flow.firstReportExitCode, -1)
    }

    func testExistingSetupMarksTheProfileWithTheRefusal() async throws {
        let (_, lock) = try makeStore()
        let flow = ExistingCLISetupFlow(profileNames: [profile])
        try await whileAnotherProcessHolds(lock) {
            await flow.run(initialize: { _ in 0 })
        }
        XCTAssertEqual(flow.statuses[profile], .failed(busy))
    }

    func testDeviceLookupSaysWhyItsRefreshWasRefused() {
        let toast = DeviceLookupView.refreshRefusalToast(for: CLIBridgeError.tickLockHeld)
        XCTAssertEqual(toast?.message, busy)
        XCTAssertNil(DeviceLookupView.refreshRefusalToast(for: CLIBridgeError.executableNotFound),
                     "other failures stay in the log, as before")
    }

    // MARK: - Automatic collects hold it too

    /// Self-remediation and catch-up claim the lock before routing, so a tick cannot start
    /// beside them. The config makes routing stop at once (a case-variant profile, which
    /// runs no jamf-cli): without the hold that error comes back, not the refusal.
    func testTheAutomaticCollectorsClaimTheLockBeforeRouting() async throws {
        let (_, lock) = try makeStore()
        let config = try ConfigLoader.loadFromString("jamf_cli:\n  profile: ALPHA\n")
        try await whileAnotherProcessHolds(lock) {
            do {
                try await WorkspaceStore.defaultRemediationCollector(profile, [.refresh], config)
                XCTFail("remediation must be refused")
            } catch {
                XCTAssertEqual(error as? CLIBridgeError, .tickLockHeld)
            }
            do {
                try await WorkspaceStore.defaultCatchUpCollector(profile, config)
                XCTFail("catch-up must be refused")
            } catch {
                XCTAssertEqual(error as? CLIBridgeError, .tickLockHeld)
            }
        }
    }

    // MARK: - The dead-man switch

    /// A tick that finds the lock held waits for the next wake, so during a long GUI collect
    /// a schedule that comes due is queued, not missed: it must not read as overdue.
    func testNoScheduleReadsOverdueWhileThisProcessHoldsTheLock() async throws {
        let (store, _) = try makeStore()
        defer { AutomationHealthModel.shared.issues = [] }
        let twoHoursAgo = Calendar.current.dateComponents(
            [.hour, .minute], from: Date().addingTimeInterval(-2 * 3600))
        store.schedules = [Schedule(
            name: "Daily", profile: profile,
            schedule: String(format: "Daily %02d:%02d",
                             twoHoursAgo.hour ?? 0, twoHoursAgo.minute ?? 0),
            cadence: "custom", mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok,
            artifacts: [], enabled: true,
            launchAgentLabel: "\(LaunchAgentWriter.labelPrefix).\(profile).daily")]

        await store.refreshAutomationHealth()
        XCTAssertEqual(AutomationHealthModel.shared.issues.map(\.kind), [.overdue],
                       "precondition: a fire two hours ago that never ran is overdue")

        _ = try await CLIBridge.holdingTickLock { () -> Bool in
            await store.refreshAutomationHealth()
            return true
        }
        XCTAssertEqual(AutomationHealthModel.shared.issues.map(\.kind), [])
    }

    // MARK: - The tick's side

    /// A wake that finds a GUI collect holding the lock queues exactly as it does behind
    /// another tick: exit 75, the run-now marker kept, the refusal stamped. The GUI is a
    /// spawned process here, since a tick in this process would read the lock as its own.
    func testATickDuringAManualCollectExitsQueuedAndKeepsItsMarker() async throws {
        _ = try useTemporaryRoot()
        let lock = TickLock(url: TickLock.defaultURL)
        let label = "\(LaunchAgentWriter.labelPrefix).\(profile).daily"
        try await whileAnotherProcessHolds(lock) {
            let exit = await runTick(arguments: ["--tick", "--now", label])
            XCTAssertEqual(exit, TickRunner.queuedExitCode)
        }
        XCTAssertEqual(TickRunner.pendingRunNowLabels(), [label])
        XCTAssertNotNil(TickLock.takeBlockedSince())
    }
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
