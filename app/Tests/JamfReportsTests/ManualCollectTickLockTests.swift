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

    /// Neither the collect nor the lock file is held by this process.
    private func assertNoHold(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(CLIBridge.collectRunning, file: file, line: line)
        XCTAssertFalse(CLIBridge.holdsTickLock, file: file, line: line)
    }

    /// A lock file that names a holder; a released one is left in place, empty.
    private func lockExists(_ lock: TickLock) -> Bool {
        !lock.namesNoHolder
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
        let tick = try XCTUnwrap(lock.claimedHold(pid: 4242), "the hold's lock was freed")
        defer { tick.release() }
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

    /// Polls for the beat rather than sleeping a fixed time: the beats run on a detached
    /// utility task, which a loaded CI runner can start later than any fixed window.
    func testAHoldNamesThisProcessBeatsAndReleases() async throws {
        let (_, lock) = try makeStore()
        let seen = try await CLIBridge.holdingTickLock(beatEvery: .milliseconds(20)) {
            () -> String in
            let pid = (try? String(contentsOf: lock.url, encoding: .utf8)) ?? "no lock"
            try? FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-10 * 60)],
                ofItemAtPath: lock.url.path)
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            var beat = false
            while !beat, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
                let modified = (try? FileManager.default.attributesOfItem(
                    atPath: lock.url.path))?[.modificationDate] as? Date
                beat = abs(modified?.timeIntervalSinceNow ?? -600) < 5
            }
            return "\(pid) beat=\(beat)"
        }
        XCTAssertEqual(seen, "\(getpid()) beat=true")
        XCTAssertFalse(lockExists(lock))
        assertNoHold()
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
        assertNoHold()
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
        assertNoHold()
        try await assertNoBeatOutlivesTheHold(lock)
    }

    /// Collect now during a running Refresh all used to share the lock; two fan-outs against
    /// one server are what the owner reported, so the second is refused and the first keeps
    /// its lock and its beat.
    func testASecondHoldWhileOneRunsIsRefusedAndLeavesTheFirstAlone() async throws {
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
        let secondRan = Flag()
        do {
            _ = try await CLIBridge.holdingTickLock { () -> Int32 in
                secondRan.set()
                return 0
            }
            XCTFail("the second hold must be refused")
        } catch {
            XCTAssertEqual(error as? CLIBridgeError, .collectInProgress)
        }
        XCTAssertFalse(secondRan.isSet)
        XCTAssertEqual(try String(contentsOf: lock.url, encoding: .utf8), String(getpid()),
                       "the collect still running keeps the lock")
        XCTAssertTrue(CLIBridge.collectRunning)
        finish.set()
        _ = await first.result
        XCTAssertFalse(lockExists(lock))
        assertNoHold()
    }

    /// The tick needs the same file, so when it cannot be written no tick can start beside
    /// the collect; refusing would turn a broken Application Support into a dead button.
    func testAnUnwritableLockLetsTheCollectRunWithoutIt() async throws {
        let (_, lock) = try makeStore()
        let unwritable = TickLock(url: lock.url.deletingLastPathComponent()
            .appendingPathComponent("missing-\(UUID().uuidString)/tick.lock"))
        CLIBridge.tickLock = { unwritable }
        let ran = try await CLIBridge.holdingTickLock { () -> Bool in
            let ranInside = await CLIBridge.collectRunning
            let lockHeld = await CLIBridge.holdsTickLock
            XCTAssertFalse(lockHeld, "there is no lock file to hold")
            do {
                _ = try await CLIBridge.holdingTickLock { () -> Bool in true }
                XCTFail("a second collect must be refused without the file too")
            } catch {
                XCTAssertEqual(error as? CLIBridgeError, .collectInProgress)
            }
            return ranInside
        }
        XCTAssertTrue(ran)
        assertNoHold()
    }

    /// While a GUI collect holds the lock, the app's own automatic collects must not read it
    /// as another process: `isCollectInFlight` and `isAnyCollectInFlight` stand them down, and
    /// the bridge runs one collect at a time, so a profile that is not collecting waits too.
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
            "elsewhere=false", "other profile waits=true", "own profile waits=true",
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
        XCTAssertNil(store.statusLine)
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

    /// Overview's Generate and Trends' Archive collect first, through the bridge; a refusal
    /// there reads the same, as information rather than a red failure.
    func testOverviewAndTrendsShowARefusalAsInformation() {
        for toast in [OverviewView.generateFailureToast(CLIBridgeError.tickLockHeld),
                      TrendsView.archiveFailureToast(CLIBridgeError.tickLockHeld)] {
            XCTAssertEqual(toast.message, busy)
            XCTAssertEqual(toast.style, .info)
        }
        let failed = TrendsView.archiveFailureToast(CLIBridgeError.executableNotFound)
        XCTAssertEqual(failed.style, .danger)
        XCTAssertTrue(failed.message.hasPrefix("Archive failed — "), failed.message)
        XCTAssertEqual(OverviewView.generateFailureToast(CLIBridgeError.executableNotFound).style,
                       .danger)
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
        assertNoHold()
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

    /// A refusal is not a run, so it must not leave a failed first collect in Run History.
    func testExistingSetupMarksTheProfileWithTheRefusal() async throws {
        let (_, lock) = try makeStore()
        let flow = ExistingCLISetupFlow(profileNames: [profile])
        try await whileAnotherProcessHolds(lock) {
            await flow.run(initialize: { _ in 0 })
        }
        XCTAssertEqual(flow.statuses[profile], .failed(busy))
        let logs = try WorkspacePaths.runHistoryDir(for: profile)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []
        XCTAssertEqual(written, [], "no Run History record for a refused collect")
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

    /// A tick that finds the lock held waits for the next wake, so during a long GUI collect,
    /// and until one wake after it, a schedule that came due is queued, not missed: it must
    /// not read as overdue. Past that window it is reported as before.
    func testNoScheduleReadsOverdueWhileThisProcessHoldsTheLock() async throws {
        let (store, _) = try makeStore()
        defer { AutomationHealthModel.shared.issues = [] }
        store.schedules = [dailyScheduleThatFiredTwoHoursAgo()]

        // Past any window an earlier test's hold left behind: the release time is per process.
        let afterTheWindow = Date().addingTimeInterval(TickLock.wakeInterval + 61)
        await store.refreshAutomationHealth(now: afterTheWindow)
        XCTAssertEqual(AutomationHealthModel.shared.issues.map(\.kind), [.overdue],
                       "precondition: a fire two hours ago that never ran is overdue")

        _ = try await CLIBridge.holdingTickLock { () -> Bool in
            await store.refreshAutomationHealth()
            return true
        }
        XCTAssertEqual(AutomationHealthModel.shared.issues.map(\.kind), [])

        await store.refreshAutomationHealth()
        XCTAssertEqual(AutomationHealthModel.shared.issues.map(\.kind), [],
                       "just after the hold ends, the wake it turned away has not run yet")

        await store.refreshAutomationHealth(
            now: Date().addingTimeInterval(TickLock.wakeInterval + 61))
        XCTAssertEqual(AutomationHealthModel.shared.issues.map(\.kind), [.overdue],
                       "still overdue one wake after the hold ends is reported")
    }

    /// A tick that holds the lock now is running what came due, so that is not overdue
    /// either; once the tick is gone it is.
    func testNoScheduleReadsOverdueWhileATickHoldsTheLock() async throws {
        let (store, lock) = try makeStore()
        defer { AutomationHealthModel.shared.issues = [] }
        store.schedules = [dailyScheduleThatFiredTwoHoursAgo()]
        let afterTheWindow = Date().addingTimeInterval(TickLock.wakeInterval + 61)

        try await whileAnotherProcessHolds(lock) {
            await store.refreshAutomationHealth(now: afterTheWindow)
            XCTAssertEqual(AutomationHealthModel.shared.issues.map(\.kind), [])
        }
        await store.refreshAutomationHealth(now: afterTheWindow)
        XCTAssertEqual(AutomationHealthModel.shared.issues.map(\.kind), [.overdue])
    }

    private func dailyScheduleThatFiredTwoHoursAgo() -> Schedule {
        let twoHoursAgo = Calendar.current.dateComponents(
            [.hour, .minute], from: Date().addingTimeInterval(-2 * 3600))
        return Schedule(
            name: "Daily", profile: profile,
            schedule: String(format: "Daily %02d:%02d",
                             twoHoursAgo.hour ?? 0, twoHoursAgo.minute ?? 0),
            cadence: "custom", mode: .snapshotOnly, next: "—", last: "—", lastStatus: .ok,
            artifacts: [], enabled: true,
            launchAgentLabel: "\(LaunchAgentWriter.labelPrefix).\(profile).daily")
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
