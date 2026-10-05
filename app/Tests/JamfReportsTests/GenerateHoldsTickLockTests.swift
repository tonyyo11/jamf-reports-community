import XCTest
@testable import JamfReports

/// A report run holds the tick lock from its collect to its last format, so no collect, tick
/// or second report starts while its snapshots and summary.json are being read. The check
/// `generateRefusal` makes is a point in time; the hold is what keeps it true afterwards.
@MainActor
final class GenerateHoldsTickLockTests: XCTestCase {

    private let profile = "alpha"
    private let generating = "A report is being generated — try again when it finishes"
    private let running = "A refresh is already running — try again when it finishes"

    private func makeStore() throws -> (store: WorkspaceStore, lock: TickLock) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-generate-hold-\(UUID().uuidString)", isDirectory: true)
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

    /// Runs `body` as a report run whose collect is a no-op, the way a generate from cached
    /// snapshots is.
    private func duringAReport(_ body: () async throws -> Void) async throws {
        let exit = try await CLIBridge.runCollectThenGenerate(
            collect: { 0 }, narrative: nil,
            generate: { _ in
                try await body()
                return 0
            })
        XCTAssertEqual(exit, 0)
    }

    /// A caller that is not part of the run, as a button's is: its own task, which does not
    /// inherit the run's hold.
    private func fromElsewhere<T: Sendable>(
        _ body: @escaping @Sendable @MainActor () async -> T
    ) async -> T {
        await Task.detached { await body() }.value
    }

    // MARK: - What the hold keeps out

    /// The defect: the check before a report is a point in time, and nothing stopped a collect
    /// from replacing the snapshots after it. Every way to start one is refused now.
    func testACollectIsRefusedWhileAReportRuns() async throws {
        let (store, _) = try makeStore()
        let profile = self.profile
        let seen = Recorder()
        try await duringAReport {
            await self.fromElsewhere {
                await store.runTierRefresh([.refresh]) { _, _, _ in
                    seen.record("tier")
                    return 0
                }
            }
            XCTAssertEqual(store.toast?.message, generating)
            XCTAssertEqual(store.toast?.style, .info)
            XCTAssertNil(store.statusLine, "a refusal touches no status")
            XCTAssertFalse(store.isCollectInFlight(for: profile))

            let direct = await self.fromElsewhere { () -> String in
                do {
                    _ = try await CLIBridge().collect(profile: profile, force: true) { line in
                        seen.record(line.text)
                    }
                    return "ran"
                } catch {
                    return error.localizedDescription
                }
            }
            XCTAssertEqual(direct, generating, "the bridge refuses a collect sent to it")
            XCTAssertEqual(CLIBridge.collectRefusal(), .generateInProgress)
            XCTAssertEqual(store.generateRefusal(), .generateInProgress)
        }
        XCTAssertEqual(seen.values, [], "no collect started")
    }

    /// The tick is another process: it reads the lock file, which names this one.
    func testATickCannotTakeTheLockDuringAReport() async throws {
        let (_, lock) = try makeStore()
        try await duringAReport {
            XCTAssertEqual(holderPid(lock), String(getpid()))
            XCTAssertFalse(lock.acquire(pid: 4242, isAlive: { _ in true }),
                           "a wake finds the lock held and waits for the next one")
        }
        XCTAssertNil(holderPid(lock))
        XCTAssertTrue(lock.acquire(pid: 4242, isAlive: { _ in true }))
    }

    func testAutomaticCollectsStandDownDuringAReport() async throws {
        let (store, _) = try makeStore()
        let profile = self.profile
        let coordinator = RefreshCoordinator(bridge: CLIBridge())
        let config = try ConfigLoader.loadFromString("jamf_cli:\n  profile: ALPHA\n")
        try await duringAReport {
            XCTAssertTrue(store.automaticCollectMustWait(for: ["beta"]))
            XCTAssertTrue(CLIBridge.tickLockHeldRecently(), "no schedule reads overdue meanwhile")

            // Nothing was attempted, so nothing counts toward backoff.
            await self.fromElsewhere {
                coordinator.refreshIfStale(profile: profile, tier: .refresh)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while coordinator.isRefreshing(profile: profile, tier: .refresh),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(coordinator.isRefreshing(profile: profile, tier: .refresh))
            XCTAssertEqual(coordinator.failureCount(profile: profile, tier: .refresh), 0)
            XCTAssertNil(coordinator.lastSuccessfulRefresh[profile])

            let remediation = await self.fromElsewhere { () -> String in
                do {
                    try await WorkspaceStore.defaultRemediationCollector(
                        profile, [.refresh], config)
                    return "ran"
                } catch {
                    return String(describing: error)
                }
            }
            XCTAssertEqual(remediation, "generateInProgress")
        }
    }

    func testASecondReportIsRefusedWithoutAMixedFiguresReason() async throws {
        _ = try makeStore()
        try await duringAReport {
            do {
                _ = try await CLIBridge.holdingGenerate { () -> Int32 in 0 }
                XCTFail("a second report must be refused")
            } catch {
                XCTAssertEqual(error as? CLIBridgeError, .generateInProgress)
            }
        }
        XCTAssertEqual(WorkspaceStore.generateRefusalMessage(.generateInProgress), generating)
        XCTAssertTrue(WorkspaceStore.generateRefusalMessage(.collectInProgress)
            .hasSuffix("would mix old and new figures."))
    }

    func testAJamfCLIUpdateSaysWhyItWaited() {
        XCTAssertEqual(
            JamfCLIInstaller.refusalMessage(.generateInProgress),
            "jamf-cli was not updated: a report is being generated. "
                + "Update it again when the report finishes.")
    }

    // MARK: - One hold from collect to report

    /// The collect a report run asks for goes through `holdingTickLock` like any collect and
    /// runs under the run's hold: the lock file is never released between it and the report,
    /// which is the window a tick could otherwise take.
    func testTheCollectRunsUnderTheReportsHoldAndTheLockIsNeverReleased() async throws {
        let (_, lock) = try makeStore()
        let phases = Recorder()
        let exit = try await CLIBridge.runCollectThenGenerate(
            collect: {
                let ran = try await CLIBridge.holdingTickLock { () -> Bool in true }
                phases.record("collect ran=\(ran) holder=\(holderPid(lock) ?? "none")")
                return 0
            },
            narrative: {
                phases.record("narrative holder=\(holderPid(lock) ?? "none")")
                return nil
            },
            generate: { _ in
                phases.record("generate holder=\(holderPid(lock) ?? "none")")
                return 0
            })
        XCTAssertEqual(exit, 0)
        let pid = String(getpid())
        XCTAssertEqual(phases.values, [
            "collect ran=true holder=\(pid)", "narrative holder=\(pid)",
            "generate holder=\(pid)",
        ])
        XCTAssertNil(holderPid(lock))
        XCTAssertFalse(CLIBridge.holdsTickLock)
        XCTAssertNil(CLIBridge.holdPurpose)
    }

    /// Only the run's own task tree gets through: a collect started from elsewhere, or from a
    /// task left over from an earlier run, is refused.
    func testOnlyTheRunsOwnCollectIsLetThrough() async throws {
        _ = try makeStore()
        let release = Flag()
        var leftover: Task<String, Never>?
        try await duringAReport {
            let elsewhere = await self.fromElsewhere { () -> String in
                do {
                    _ = try await CLIBridge.holdingTickLock { () -> Bool in true }
                    return "ran"
                } catch {
                    return String(describing: error)
                }
            }
            XCTAssertEqual(elsewhere, "generateInProgress")
            // Started inside the run, so it carries the run's hold, and outlives it.
            leftover = Task { @MainActor () -> String in
                while !release.isSet { try? await Task.sleep(for: .milliseconds(5)) }
                do {
                    _ = try await CLIBridge.holdingTickLock { () -> Bool in true }
                    return "ran"
                } catch {
                    return String(describing: error)
                }
            }
        }
        let task = try XCTUnwrap(leftover)
        try await duringAReport {
            release.set()
            let outcome = await task.value
            XCTAssertEqual(outcome, "generateInProgress", "the earlier run's hold is not this one")
        }
    }

    // MARK: - Ordering with a collect

    func testAReportAfterACollectsHoldEndsStarts() async throws {
        let (_, lock) = try makeStore()
        _ = try await CLIBridge.holdingTickLock { () -> Int32 in 0 }
        XCTAssertNil(holderPid(lock))
        let ran = Flag()
        try await duringAReport { ran.set() }
        XCTAssertTrue(ran.isSet)
        XCTAssertNil(CLIBridge.collectRefusal())
    }

    func testAReportIsRefusedWhileACollectRunsAndRunsNothing() async throws {
        let (_, lock) = try makeStore()
        let steps = Recorder()
        _ = try await CLIBridge.holdingTickLock { () -> Int32 in
            do {
                _ = try await CLIBridge.runCollectThenGenerate(
                    collect: { steps.record("collect"); return 0 },
                    narrative: { steps.record("narrative"); return nil },
                    generate: { _ in steps.record("generate"); return 0 })
                XCTFail("the report must be refused")
            } catch {
                XCTAssertEqual(error as? CLIBridgeError, .collectInProgress)
            }
            return 0
        }
        XCTAssertEqual(steps.values, [])
        XCTAssertNil(holderPid(lock))
    }

    func testAScheduledRunHoldingTheLockRefusesTheReportBeforeItsCollect() async throws {
        let (_, lock) = try makeStore()
        let steps = Recorder()
        try await whileAnotherProcessHolds(lock) {
            do {
                _ = try await CLIBridge.runCollectThenGenerate(
                    collect: { steps.record("collect"); return 0 },
                    narrative: nil,
                    generate: { _ in steps.record("generate"); return 0 })
                XCTFail("the report must be refused")
            } catch {
                XCTAssertEqual(error as? CLIBridgeError, .tickLockHeld)
            }
        }
        XCTAssertEqual(steps.values, [])
    }

    func testTheHoldEndsWhenTheCollectFailsOrTheReportThrows() async throws {
        let (_, lock) = try makeStore()
        let steps = Recorder()
        let exit = try await CLIBridge.runCollectThenGenerate(
            collect: { 3 }, narrative: nil,
            generate: { _ in steps.record("generate"); return 0 })
        XCTAssertEqual(exit, 3)
        XCTAssertEqual(steps.values, [])
        XCTAssertNil(holderPid(lock))
        XCTAssertNil(CLIBridge.holdPurpose)

        do {
            _ = try await CLIBridge.runCollectThenGenerate(
                collect: { 0 }, narrative: nil,
                generate: { _ in throw CLIBridgeError.executableNotFound })
            XCTFail("the error must reach the caller")
        } catch {
            XCTAssertEqual(error as? CLIBridgeError, .executableNotFound)
        }
        XCTAssertNil(holderPid(lock))
        XCTAssertNil(CLIBridge.holdPurpose)
        XCTAssertNil(CLIBridge.collectRefusal())
    }

    /// A collect refused by a collect is still told so: the message names a refresh.
    func testACollectRefusalStillNamesARefresh() async throws {
        _ = try makeStore()
        let running = self.running
        _ = try await CLIBridge.holdingTickLock { () -> Int32 in
            let refusal = await CLIBridge.collectRefusal()
            XCTAssertEqual(refusal?.localizedDescription, running)
            return 0
        }
    }
}

/// The pid the lock file names, nil when there is no file.
private func holderPid(_ lock: TickLock) -> String? {
    try? String(contentsOf: lock.url, encoding: .utf8)
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
