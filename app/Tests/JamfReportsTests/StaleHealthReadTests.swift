import XCTest
@testable import JamfReports

/// `refreshDataFreshness` and `refreshAutomationHealth` read off the main actor and publish what
/// they find. A read for profile A that lands after a switch to B, or after a newer request,
/// described something else: the banner's "Collect now" then drove the wrong profile's tiers.
@MainActor
final class StaleHealthReadTests: XCTestCase {

    private func useTemporaryRoot(creating profiles: [String]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-stale-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for profile in profiles {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(profile, isDirectory: true),
                withIntermediateDirectories: true)
        }
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeStore(registrar: any TickerRegistrar = StubTickerRegistrar())
        -> WorkspaceStore
    {
        _ = useTemporaryTickLock()
        let store = WorkspaceStore(
            demoMode: false, tickerRegistrar: registrar,
            jamfCLIProfileNames: { [] }, discoverProfiles: { [] }, jamfCLIInstallation: { nil })
        store.resolveAuthMethod = { _ in nil }
        AutomationHealthModel.shared.freshnessIssues = []
        AutomationHealthModel.shared.issues = []
        addTeardownBlock { @MainActor in
            AutomationHealthModel.shared.freshnessIssues = []
            AutomationHealthModel.shared.issues = []
        }
        return store
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out waiting") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Data freshness

    /// Alpha has collected once, so its other kinds read as never landed; beta has never
    /// collected and reads clean.
    func testAFreshnessReadForAnotherProfileIsDropped() async throws {
        try useTemporaryRoot(creating: ["alpha", "beta"])
        try StateFileStore(directory: WorkspacePaths.stateDir(for: "alpha"))
            .record(.landed, report: "overview", at: Date())
        let alpha = WorkspaceStore.evaluateFreshness(profile: "alpha", resolveAuth: { _ in nil })
        XCTAssertFalse(alpha.isEmpty, "precondition: alpha has issues to publish")

        let store = makeStore()
        let gate = Gate()
        store.resolveAuthMethod = { profile in
            if profile == "alpha" { gate.holdHere() }
            return nil
        }
        store.profile = "alpha"
        let slow = Task { @MainActor in await store.refreshDataFreshness() }
        try await waitUntil { gate.hasStarted }

        store.profile = "beta"
        await store.refreshDataFreshness()
        XCTAssertTrue(AutomationHealthModel.shared.freshnessIssues.isEmpty)

        gate.release()
        await slow.value
        XCTAssertTrue(AutomationHealthModel.shared.freshnessIssues.isEmpty,
                      "alpha's late answer must not replace beta's")
    }

    func testAFreshnessReadStillPublishesWhenNothingOvertookIt() async throws {
        try useTemporaryRoot(creating: ["alpha"])
        try StateFileStore(directory: WorkspacePaths.stateDir(for: "alpha"))
            .record(.landed, report: "overview", at: Date())
        let store = makeStore()
        store.profile = "alpha"
        await store.refreshDataFreshness()
        XCTAssertFalse(AutomationHealthModel.shared.freshnessIssues.isEmpty)
    }

    // MARK: - Automation health

    /// A schedule that fired two hours ago and never ran, as `ManualCollectTickLockTests` has it.
    private func overdueSchedule(profile: String) -> Schedule {
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

    /// Past any window an earlier test's hold left behind: the release time is per process.
    private var afterTheWindow: Date { Date().addingTimeInterval(TickLock.wakeInterval + 61) }

    func testAHealthReadForAnotherProfileIsDropped() async throws {
        try useTemporaryRoot(creating: [])
        let gate = Gate()
        let registrar = BlockingRegistrar(gate: gate)
        let store = makeStore(registrar: registrar)
        store.schedules = [overdueSchedule(profile: "alpha")]
        store.profile = "alpha"
        let now = afterTheWindow
        let slow = Task { @MainActor in await store.refreshAutomationHealth(now: now) }
        try await waitUntil { gate.hasStarted }

        store.profile = "beta"
        await store.refreshAutomationHealth(now: now)
        XCTAssertEqual(AutomationHealthModel.shared.issues.map(\.kind), [])

        gate.release()
        await slow.value
        XCTAssertEqual(AutomationHealthModel.shared.issues.map(\.kind), [],
                       "alpha's late answer must not replace beta's")
    }

    func testAnOlderHealthReadFinishingLastIsDropped() async throws {
        try useTemporaryRoot(creating: [])
        let gate = Gate()
        let store = makeStore(registrar: BlockingRegistrar(gate: gate))
        store.schedules = [overdueSchedule(profile: "alpha")]
        store.profile = "alpha"
        let now = afterTheWindow
        let slow = Task { @MainActor in await store.refreshAutomationHealth(now: now) }
        try await waitUntil { gate.hasStarted }

        // The schedule is gone by the time the newer request reads, and it publishes first.
        store.schedules = []
        await store.refreshAutomationHealth(now: now)
        XCTAssertEqual(AutomationHealthModel.shared.issues.map(\.kind), [])

        gate.release()
        await slow.value
        XCTAssertEqual(AutomationHealthModel.shared.issues.map(\.kind), [],
                       "the older request's answer must not replace the newer one's")
    }

    func testAHealthReadStillPublishesWhenNothingOvertookIt() async throws {
        try useTemporaryRoot(creating: [])
        let store = makeStore()
        store.schedules = [overdueSchedule(profile: "alpha")]
        store.profile = "alpha"
        await store.refreshAutomationHealth(now: afterTheWindow)
        XCTAssertEqual(AutomationHealthModel.shared.issues.map(\.kind), [.overdue])
    }
}

/// Holds a detached read at a known point until the test lets it go. The first caller blocks;
/// later ones pass, so a second request can run while the first is held.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var open = false

    var hasStarted: Bool { lock.withLock { started } }

    func release() { lock.withLock { open = true } }

    func holdHere() {
        let first = lock.withLock { () -> Bool in
            defer { started = true }
            return !started
        }
        guard first else { return }
        while !lock.withLock({ open }) { usleep(5_000) }
    }
}

/// `status` is read off the main actor by the health pass; the first read waits at the gate.
private final class BlockingRegistrar: TickerRegistrar, @unchecked Sendable {
    private let gate: Gate
    init(gate: Gate) { self.gate = gate }
    func register() throws {}
    func unregister() throws {}
    var status: TickerStatus {
        gate.holdHere()
        return .enabled
    }
    func openLoginItems() {}
}
