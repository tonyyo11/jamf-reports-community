import XCTest
@testable import JamfReports

/// Secondary onboarding for existing jamf-cli users (#181 follow-on):
/// trigger predicate, per-profile run loop, and the automation policy the
/// completion step writes.
@MainActor
final class ExistingCLISetupFlowTests: XCTestCase {

    // MARK: - shouldOffer

    func testShouldOfferOnlyForUninitializedRealProfiles() {
        XCTAssertTrue(ExistingCLISetupFlow.shouldOffer(
            profileCount: 2, initializedProfileCount: 0, demoMode: false, outcome: nil
        ))
        XCTAssertFalse(ExistingCLISetupFlow.shouldOffer(
            profileCount: 0, initializedProfileCount: 0, demoMode: false, outcome: nil
        ), "no profiles → the connection onboarding owns first launch")
        XCTAssertFalse(ExistingCLISetupFlow.shouldOffer(
            profileCount: 2, initializedProfileCount: 1, demoMode: false, outcome: nil
        ), "any initialized workspace means the app is already set up")
        XCTAssertFalse(ExistingCLISetupFlow.shouldOffer(
            profileCount: 2, initializedProfileCount: 0, demoMode: true, outcome: nil
        ), "demo mode never shows real setup")
    }

    /// State derives from real artifacts, not progress flags: a COMPLETED
    /// setup re-offers when every workspace is wiped (the disk is first-launch
    /// again), while an explicit SKIP stays respected forever.
    func testShouldOfferDistinguishesCompletedFromSkipped() {
        XCTAssertTrue(ExistingCLISetupFlow.shouldOffer(
            profileCount: 2, initializedProfileCount: 0, demoMode: false, outcome: .completed
        ), "wipe after a completed setup → re-offer")
        XCTAssertFalse(ExistingCLISetupFlow.shouldOffer(
            profileCount: 2, initializedProfileCount: 1, demoMode: false, outcome: .completed
        ), "completed and workspaces intact → shell")
        XCTAssertFalse(ExistingCLISetupFlow.shouldOffer(
            profileCount: 2, initializedProfileCount: 0, demoMode: false, outcome: .skipped
        ), "skip is a permanent choice — never nag")
    }

    /// Pre-2.2.1 field builds stored a Bool under the legacy key; it maps to
    /// `.completed` so those installs gain the re-offer-on-wipe behavior.
    func testStoredOutcomeHonorsLegacyBoolKey() {
        let suite = "ExistingCLISetupFlowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(ExistingCLISetupFlow.storedOutcome(defaults: defaults))

        defaults.set(true, forKey: ExistingCLISetupFlow.legacyDismissedKey)
        XCTAssertEqual(ExistingCLISetupFlow.storedOutcome(defaults: defaults), .completed)

        defaults.set(ExistingCLISetupFlow.SetupOutcome.skipped.rawValue,
                     forKey: ExistingCLISetupFlow.outcomeKey)
        XCTAssertEqual(ExistingCLISetupFlow.storedOutcome(defaults: defaults), .skipped,
                       "the new key wins over the legacy Bool")
    }

    // MARK: - run loop

    func testRunInitializesAndCollectsEverySelectedProfile() async {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha", "beta"])
        var initialized: [String] = []
        var collected: [String] = []

        await flow.run(
            initialize: { initialized.append($0); return 0 },
            collect: { name, _ in collected.append(name); return 0 }
        )

        XCTAssertEqual(initialized, ["alpha", "beta"], "sequential, discovery order")
        XCTAssertEqual(collected, ["alpha", "beta"])
        XCTAssertEqual(flow.statuses["alpha"], .done)
        XCTAssertEqual(flow.statuses["beta"], .done)
        XCTAssertTrue(flow.didComplete)
        XCTAssertEqual(flow.selectionSummary.succeeded, 2)
        XCTAssertEqual(flow.selectionSummary.failed, 0)
    }

    func testRunSkipsUnselectedProfiles() async {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha", "beta"])
        flow.selected = ["beta"]
        var initialized: [String] = []

        await flow.run(
            initialize: { initialized.append($0); return 0 },
            collect: { _, _ in 0 }
        )

        XCTAssertEqual(initialized, ["beta"])
        XCTAssertEqual(flow.statuses["alpha"], .pending, "unselected profile stays untouched")
        XCTAssertEqual(flow.statuses["beta"], .done)
    }

    func testInitFailureSkipsCollectButContinuesToNextProfile() async {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha", "beta"])
        var collected: [String] = []

        await flow.run(
            initialize: { $0 == "alpha" ? 1 : 0 },
            collect: { name, _ in collected.append(name); return 0 }
        )

        XCTAssertEqual(collected, ["beta"], "failed init must not attempt a collect")
        XCTAssertEqual(flow.statuses["alpha"], .failed("workspace init exited 1"))
        XCTAssertEqual(flow.statuses["beta"], .done)
        XCTAssertTrue(flow.didComplete, "one failure never blocks completion")
    }

    func testCollectFailureCarriesActionableMessage() async {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])

        await flow.run(initialize: { _ in 0 }, collect: { _, _ in 3 })

        guard case .failed(let reason)? = flow.statuses["alpha"] else {
            return XCTFail("expected .failed, got \(String(describing: flow.statuses["alpha"]))")
        }
        XCTAssertTrue(reason.contains("auth"),
                      "exit-3 guidance must point at jamf-cli auth; got: \(reason)")
        XCTAssertEqual(flow.selectionSummary.failed, 1)
    }

    func testThrownErrorBecomesFailedStatus() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])

        await flow.run(initialize: { _ in throw Boom() }, collect: { _, _ in 0 })

        XCTAssertEqual(flow.statuses["alpha"], .failed("boom"))
        XCTAssertTrue(flow.didComplete)
    }

    // MARK: - Collect progress parsing

    func testIngestTracksKindLifecycle() {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])

        flow.ingest("[info] collecting computers for alpha")
        XCTAssertEqual(flow.progress.currentKind, "computers")

        flow.ingest("[ok] computers: 18342 bytes")
        XCTAssertEqual(flow.progress.collected, 1)
        XCTAssertNil(flow.progress.currentKind, "completed kind clears the live label")

        flow.ingest("[info] collecting update-device-failures for alpha")
        flow.ingest("[warn] update-device-failures: exit 1 — skipped (using cached)")
        XCTAssertEqual(flow.progress.failed, 1)

        flow.ingest("[skip] profile-status: tier scan not selected")
        XCTAssertEqual(flow.progress.skipped, 1)

        XCTAssertEqual(flow.progress.summary, "1 collected, 1 failed, 1 skipped")
    }

    func testIngestIgnoresNonKindLines() {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])
        flow.ingest("some raw subprocess output")
        flow.ingest("{\"totalCount\": 3}")
        XCTAssertEqual(flow.progress, ExistingCLISetupFlow.CollectProgress())
    }

    func testRunRecordsPerProfileKindSummary() async {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])

        await flow.run(
            initialize: { _ in 0 },
            collect: { _, onLine in
                onLine(CLIBridge.LogLine(timestamp: Date(), level: .info,
                               text: "[info] collecting computers for alpha"))
                onLine(CLIBridge.LogLine(timestamp: Date(), level: .ok,
                               text: "[ok] computers: 100 bytes"))
                // The onLine sink hops to the MainActor; yield so the ingest
                // tasks land before the collect closure returns.
                await Task.yield()
                return 0
            }
        )

        XCTAssertEqual(flow.kindSummaries["alpha"]?.collected, 1)
    }

    // MARK: - configuredPolicy

    func testConfiguredPolicyEnablesManagedAutomationWithChoices() {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])
        flow.enableAutomation = true
        flow.scanWeekday = 3
        flow.reportsCadence = .monthly
        flow.runTime = "07:30"

        let policy = flow.configuredPolicy(basedOn: AutomationPolicy())

        XCTAssertTrue(policy.isManaged)
        XCTAssertEqual(policy.scanWeekday, 3)
        XCTAssertEqual(policy.reportsWeekday, 3, "report day follows the chosen scan day")
        XCTAssertEqual(policy.reportsCadence, .monthly)
        XCTAssertEqual(policy.runTime, "07:30")
        XCTAssertTrue(policy.freshnessEnabled, "daily freshness stays on by default")
    }

    func testConfiguredPolicyLeavesBaseUntouchedWhenAutomationDeclined() {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])
        flow.enableAutomation = false
        flow.scanWeekday = 5

        let policy = flow.configuredPolicy(basedOn: AutomationPolicy())

        XCTAssertEqual(policy, AutomationPolicy(),
                       "declining automation must not flip isManaged or alter fields")
    }

    func testCollectFailureReasonExitOneDoesNotBlameAuth() {
        // The #181 misattribution class: only exit 3 means dead credentials.
        let partial = ExistingCLISetupFlow.collectFailureReason(exit: 1)
        XCTAssertFalse(partial.contains("credentials"))
        XCTAssertTrue(partial.contains("Run History"))

        let auth = ExistingCLISetupFlow.collectFailureReason(exit: CLIBridge.exitCodeUnauthorized)
        XCTAssertTrue(auth.contains("re-authenticate"))
    }
}
