import XCTest
@testable import JamfReports

/// Build 1478 ran three collects at once (a scan prompt, a toolbar Refresh and the health
/// strip's Collect now), because manual collects asked only about the tick lock. Now one
/// collect runs at a time in the app, whatever the profile: a second manual start is refused
/// with an information toast before it touches any state, an automatic one stands down, and
/// the bridge backs both up for the paths that go straight to it.
@MainActor
final class OneCollectAtATimeTests: XCTestCase {

    private let profile = "alpha"
    private let running = "A refresh is already running — try again when it finishes"
    private let busy = "A scheduled run is in progress — try again when it finishes"

    private func makeStore() throws -> (store: WorkspaceStore, lock: TickLock) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-one-collect-\(UUID().uuidString)", isDirectory: true)
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

    /// Runs `body` while a collect holds the bridge's lock, as any GUI or automatic collect
    /// does, then lets that collect finish.
    private func whileACollectRuns(_ body: () async throws -> Void) async throws {
        let started = Flag()
        let finish = Flag()
        defer { finish.set() }
        let hold = Task { @MainActor in
            try await CLIBridge.holdingTickLock { () -> Int32 in
                started.set()
                while !finish.isSet { try await Task.sleep(for: .milliseconds(10)) }
                return 0
            }
        }
        try await waitUntil { started.isSet }
        try await body()
        finish.set()
        _ = try await hold.value
    }

    private func recordedRuns() throws -> Int {
        let logs = try WorkspacePaths.runHistoryDir(for: profile)
        return ((try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []).count
    }

    // MARK: - Manual starts

    /// Two manual collects back to back: the second is refused with the information toast,
    /// never reaches its collect, and leaves the status line, the in-flight mark and Run
    /// History as the first left them. Once the first ends, the second can run.
    func testASecondManualCollectIsRefusedWithoutTouchingState() async throws {
        let (store, _) = try makeStore()
        let started = Flag()
        let finish = Flag()
        defer { finish.set() }
        let seen = Recorder()
        let first = Task { @MainActor in
            await store.runTierRefresh([.refresh]) { _, _, _ in
                seen.record("first")
                started.set()
                while !finish.isSet { try await Task.sleep(for: .milliseconds(10)) }
                return 0
            }
        }
        try await waitUntil { started.isSet }
        let status = store.statusLine
        let runsBefore = try recordedRuns()
        store.toast = nil

        await store.runTierRefresh([.inventory]) { _, _, _ in
            seen.record("second")
            return 0
        }

        XCTAssertEqual(store.toast?.message, running)
        XCTAssertEqual(store.toast?.style, .info)
        XCTAssertEqual(seen.values, ["first"], "the second collect never ran")
        XCTAssertEqual(store.statusLine, status)
        XCTAssertNotNil(status, "precondition: the first collect owns the status line")
        XCTAssertTrue(store.isCollectInFlight(for: profile), "the first collect keeps its mark")
        XCTAssertEqual(try recordedRuns(), runsBefore, "a refusal leaves no Run History entry")

        finish.set()
        await first.value
        XCTAssertFalse(store.isCollectInFlight(for: profile))
        XCTAssertNil(store.statusLine)
        store.toast = nil
        await store.runTierRefresh([.inventory]) { _, _, _ in
            seen.record("second, after")
            return 0
        }
        XCTAssertEqual(seen.values, ["first", "second, after"])
    }

    /// Every button that starts a collect through the store asks the same question.
    func testEveryStoreCollectRefusesWhileAnotherRuns() async throws {
        let (store, _) = try makeStore()
        let seen = Recorder()
        try await whileACollectRuns {
            await store.runTierRefresh([.refresh]) { _, _, _ in
                seen.record("tier")
                return 0
            }
            XCTAssertEqual(store.toast?.message, running)
            store.toast = nil

            store.staleHeavyTiers = [.inventory]
            await store.runHeavyTierRefresh { _, _, _ in
                seen.record("heavy")
                return 0
            }
            XCTAssertEqual(store.toast?.message, running)
            XCTAssertEqual(store.staleHeavyTiers, [.inventory], "a refusal re-probes nothing")
            store.toast = nil

            await store.runFirstCollect { _, _ in
                seen.record("first")
                return 0
            }
            XCTAssertEqual(store.toast?.message, running)
            store.toast = nil

            AutomationHealthModel.shared.freshnessIssues = []
            await store.collectFailingNow()
            XCTAssertEqual(store.toast?.message, running)
            XCTAssertFalse(AutomationHealthModel.shared.isRemediating)
        }
        XCTAssertEqual(seen.values, [])
        XCTAssertNil(store.statusLine)
        XCTAssertFalse(store.isCollectInFlight(for: profile))
    }

    /// The store's own marks count too: the collect may be on another profile, or one whose
    /// closure never reaches the bridge.
    func testAnotherProfilesCollectRefusesAManualOne() async throws {
        let (store, _) = try makeStore()
        store.beginCollect(for: "beta")
        defer { store.endCollect(for: "beta") }
        XCTAssertTrue(store.isAnyCollectInFlight)
        let ran = Flag()
        await store.runTierRefresh([.refresh]) { _, _, _ in
            ran.set()
            return 0
        }
        XCTAssertFalse(ran.isSet)
        XCTAssertEqual(store.toast?.message, running)
        XCTAssertFalse(store.isCollectInFlight(for: profile))
    }

    func testTheTickLockRefusalIsUnchanged() async throws {
        let (store, lock) = try makeStore()
        let ran = Flag()
        try await whileAnotherProcessHolds(lock) {
            await store.runTierRefresh([.refresh]) { _, _, _ in
                ran.set()
                return 0
            }
            XCTAssertEqual(store.toast?.message, busy)
            XCTAssertEqual(store.toast?.style, .info)
            XCTAssertEqual(CLIBridge.collectRefusal(), .tickLockHeld)
        }
        XCTAssertFalse(ran.isSet)
        XCTAssertNil(CLIBridge.collectRefusal())
    }

    // MARK: - Automatic starts

    private func staleIssue() -> DataFreshnessIssue {
        DataFreshnessIssue(
            snapshotKind: "security", tier: .refresh, kind: .stale,
            lastSuccess: Date(timeIntervalSince1970: 1_700_000_000),
            consecutiveFailures: 0, lastFailure: nil
        )
    }

    /// Self-remediation and catch-up stand down while a manual collect runs, leave their hour
    /// and day unclaimed, and run once it is over.
    func testAnAutomaticCollectStandsDownWhileAManualOneRuns() async throws {
        let (store, _) = try makeStore()
        AutomationHealthModel.shared.freshnessIssues = [staleIssue()]
        defer { AutomationHealthModel.shared.freshnessIssues = [] }
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try "".write(to: workspace.appendingPathComponent("config.yaml"),
                     atomically: true, encoding: .utf8)
        let remediated = Recorder()
        let caughtUp = Recorder()
        var policy = AutomationPolicy()
        policy.isManaged = true
        policy.freshnessEnabled = true
        let day = try XCTUnwrap(Calendar.current.date(from: DateComponents(
            year: 2100, month: 2, day: 3, hour: 12)))

        try await whileACollectRuns {
            let remediation = await store.remediateStaleDataIfNeeded { profile, _, _ in
                remediated.record(profile)
            }
            XCTAssertFalse(remediation)
            let catchUp = await store.catchUpCollectIfNeeded(
                policy: policy, now: day
            ) { profile, _ in caughtUp.record(profile) }
            XCTAssertFalse(catchUp)
        }
        XCTAssertEqual(remediated.values + caughtUp.values, [])
        XCTAssertNil(DayMarker(name: "freshness-remediation").lastStampedDay(in: workspace),
                     "standing down does not claim the hour")

        let attempted = await store.remediateStaleDataIfNeeded { profile, _, _ in
            remediated.record(profile)
        }
        XCTAssertTrue(attempted)
        XCTAssertEqual(remediated.values, [profile])
    }

    // MARK: - The bridge's backstop

    /// Nothing nests a hold today. A hold started inside another is an overlap like any other:
    /// refused, with the outer collect and its lock untouched.
    func testAHoldInsideAHoldIsRefused() async throws {
        let (_, lock) = try makeStore()
        let outer = try await CLIBridge.holdingTickLock { () -> String in
            do {
                _ = try await CLIBridge.holdingTickLock { () -> Int32 in 0 }
                return "inner ran"
            } catch {
                let pid = (try? String(contentsOf: lock.url, encoding: .utf8)) ?? "no lock"
                return "\((error as? CLIBridgeError).map(String.init(describing:)) ?? "?") \(pid)"
            }
        }
        XCTAssertEqual(outer, "collectInProgress \(getpid())")
        XCTAssertFalse(CLIBridge.collectRunning)
        XCTAssertTrue(lock.namesNoHolder)
    }

    func testTheBridgeRefusesBeforeRunningAnything() async throws {
        _ = try makeStore()
        let lines = Recorder()
        try await whileACollectRuns {
            do {
                _ = try await CLIBridge().collect(profile: profile, force: true) { line in
                    lines.record(line.text)
                }
                XCTFail("the collect must be refused")
            } catch {
                XCTAssertEqual(error as? CLIBridgeError, .collectInProgress)
                XCTAssertEqual(error.localizedDescription, running)
            }
            do {
                _ = try await CLIBridge().collectThenGenerate(
                    profile: profile, csvPath: nil, onLine: CLIBridge.noOpOnLine)
                XCTFail("the collect must be refused")
            } catch {
                XCTAssertEqual(error as? CLIBridgeError, .collectInProgress)
            }
            XCTAssertEqual(CLIBridge.collectRefusal(), .collectInProgress)
        }
        XCTAssertEqual(lines.values, [])
    }

    /// The screens that call the bridge directly show the refusal as information and name it.
    func testScreensShowTheRefusalAsInformation() async {
        let refusal = CLIBridgeError.collectInProgress
        for toast in [OverviewView.generateFailureToast(refusal),
                      TrendsView.archiveFailureToast(refusal),
                      DeviceLookupView.refreshRefusalToast(for: refusal)] {
            XCTAssertEqual(toast?.message, running)
            XCTAssertEqual(toast?.style, .info)
        }
        let outcome = await GenerateSheetState.perform(
            GenerateSheetState().request(), profile: profile, onLine: CLIBridge.noOpOnLine,
            collect: { throw refusal }, narrative: { nil },
            generateAll: { _, _, _, _, _, _, _ in GenerateAllResult() })
        XCTAssertEqual(outcome.count, 0)
        XCTAssertEqual(outcome.message, running)
    }

    /// The profile-switch refresh is automatic: a refusal there is nothing attempted, so it
    /// cannot push the coordinator into backoff.
    func testTheBackgroundRefreshDoesNotCountAnAppRefusalAsAFailure() async throws {
        _ = try makeStore()
        let coordinator = RefreshCoordinator(bridge: CLIBridge())
        try await whileACollectRuns {
            coordinator.refreshIfStale(profile: profile, tier: .refresh)
            try await waitUntil { !coordinator.isRefreshing(profile: profile, tier: .refresh) }
        }
        XCTAssertEqual(coordinator.failureCount(profile: profile, tier: .refresh), 0)
        XCTAssertNil(coordinator.lastSuccessfulRefresh[profile])
    }

    /// A refusal is not a run: no failed first collect lands in Run History for it.
    func testSetupAndOnboardingRefuseWithoutRecordingARun() async throws {
        let (store, _) = try makeStore()
        let setup = ExistingCLISetupFlow(profileNames: [profile])
        let onboarding = OnboardingFlow()
        onboarding.productPath = .pro
        onboarding.profileName = profile
        let runsBefore = try recordedRuns()
        try await whileACollectRuns {
            await setup.run(initialize: { _ in 0 })
            await onboarding.runFirstReport(workspaceStore: store)
        }
        XCTAssertEqual(setup.statuses[profile], .failed(running))
        XCTAssertEqual(onboarding.lastError, running)
        XCTAssertEqual(try recordedRuns(), runsBefore)
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
