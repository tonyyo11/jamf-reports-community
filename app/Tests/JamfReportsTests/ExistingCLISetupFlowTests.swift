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
    func testMissingWorkspaceMessageNamesTheExpectedConfigPath() {
        let message = ExistingCLISetupFlow.missingWorkspaceMessage(
            root: "/Volumes/Team/Jamf-Reports", profiles: ["prod", "dev"]
        )
        XCTAssertTrue(message.contains("/Volumes/Team/Jamf-Reports/prod/config.yaml"))
        XCTAssertTrue(message.contains("prod, dev"))
        // No configured profile at all still yields a path the operator can check.
        let bare = ExistingCLISetupFlow.missingWorkspaceMessage(root: "/tmp/r", profiles: [])
        XCTAssertTrue(bare.contains("/tmp/r/<profile>/config.yaml"))
    }

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

    // MARK: - Failure causes and completion

    func testFailureStageRecordsWhereEachProfileStopped() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let flow = ExistingCLISetupFlow(profileNames: ["a", "b", "c", "d", "e"])

        await flow.run(
            initialize: { name in
                if name == "b" { throw Boom() }
                return name == "a" ? 1 : 0
            },
            collect: { name, _ in
                switch name {
                case "c": return CLIBridge.exitCodeUnauthorized
                case "d": return 1
                default: throw Boom()
                }
            }
        )

        XCTAssertEqual(flow.failureStages["a"], .workspace, "init exit != 0")
        XCTAssertEqual(flow.failureStages["b"], .workspace, "init threw")
        XCTAssertEqual(flow.failureStages["c"], .credentials, "collect exit 3")
        XCTAssertEqual(flow.failureStages["d"], .collect, "collect exit 1")
        XCTAssertEqual(flow.failureStages["e"], .collect, "collect threw")
    }

    func testSummaryBlamesSignInOnlyForCredentialFailures() {
        let workspaceOnly = ExistingCLISetupFlow.summaryText(
            succeeded: 0, failures: [.workspace, .workspace])
        XCTAssertTrue(workspaceOnly.contains("0 succeeded, 2 failed"))
        XCTAssertTrue(workspaceOnly.lowercased().contains("workspace"), workspaceOnly)
        XCTAssertFalse(workspaceOnly.contains("auth"), workspaceOnly)
        XCTAssertFalse(workspaceOnly.contains("sign-in"), workspaceOnly)
        XCTAssertFalse(workspaceOnly.contains("Overview banner"),
                       "there is no workspace to re-collect into: \(workspaceOnly)")

        let credentials = ExistingCLISetupFlow.summaryText(succeeded: 1, failures: [.credentials])
        XCTAssertTrue(credentials.contains("auth"), credentials)
        XCTAssertTrue(credentials.contains("Overview banner"), credentials)
        XCTAssertFalse(credentials.lowercased().contains("workspace could not"), credentials)

        let plain = ExistingCLISetupFlow.summaryText(succeeded: 1, failures: [.collect])
        XCTAssertTrue(plain.contains("Run History"), plain)
        // Exit 1 usually means some kinds failed in a collect that finished.
        XCTAssertTrue(plain.contains("A collect reported failures"), plain)
        XCTAssertFalse(plain.contains("did not finish"), plain)
        XCTAssertFalse(plain.contains("auth"), plain)
    }

    func testSummaryNamesEveryCauseThatOccurred() {
        let mixed = ExistingCLISetupFlow.summaryText(
            succeeded: 1, failures: [.workspace, .credentials])
        XCTAssertTrue(mixed.contains("1 succeeded, 2 failed"), mixed)
        XCTAssertTrue(mixed.lowercased().contains("workspace"), mixed)
        XCTAssertTrue(mixed.contains("auth"), mixed)
    }

    func testSummaryKeepsTheAllSucceededWording() {
        XCTAssertEqual(
            ExistingCLISetupFlow.summaryText(succeeded: 1, failures: []),
            "All 1 profile collected — dashboards are populated and the first trend point "
                + "is saved."
        )
        XCTAssertTrue(ExistingCLISetupFlow.summaryText(succeeded: 2, failures: [])
            .hasPrefix("All 2 profiles collected"))
    }

    func testCompletionTextIsWordedFromTheRunsFailures() async {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha", "beta"])

        await flow.run(initialize: { _ in 1 }, collect: { _, _ in 0 })

        XCTAssertFalse(flow.completionText.contains("auth"), flow.completionText)
        XCTAssertTrue(flow.completionText.contains("0 succeeded, 2 failed"))
        XCTAssertTrue(flow.completionText.contains("No workspace exists yet"),
                      "says why Continue is not offered: \(flow.completionText)")
    }

    func testCompletionTextOmitsTheNoWorkspaceNoteWhenOneExists() async {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])

        await flow.run(initialize: { _ in 0 }, collect: { _, _ in CLIBridge.exitCodeUnauthorized })

        XCTAssertTrue(flow.completionText.contains("auth"), flow.completionText)
        XCTAssertFalse(flow.completionText.contains("No workspace exists yet"))
    }

    /// `finish()` records completion, and ContentView re-offers setup with its state
    /// reset when no workspace exists, so a run that created none must not continue.
    func testCannotContinueWhenNoWorkspaceWasCreated() async {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha", "beta"])
        XCTAssertFalse(flow.canContinue, "before a run there is nothing to continue from")

        await flow.run(initialize: { _ in 1 }, collect: { _, _ in 0 })

        XCTAssertTrue(flow.didComplete)
        XCTAssertFalse(flow.canContinue)
    }

    func testCanContinueWhenAWorkspaceExistsEvenIfItsCollectFailed() async {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])

        await flow.run(initialize: { _ in 0 }, collect: { _, _ in CLIBridge.exitCodeUnauthorized })

        XCTAssertEqual(flow.statuses["alpha"].map { "\($0)" }?.hasPrefix("failed"), true)
        XCTAssertTrue(flow.canContinue, "the workspace exists, so ContentView will find it")
    }

    func testCanContinueWhenOneOfTwoWorkspacesWasCreated() async {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha", "beta"])

        await flow.run(initialize: { $0 == "alpha" ? 1 : 0 }, collect: { _, _ in 0 })

        XCTAssertTrue(flow.canContinue)
    }

    // MARK: - Retry after a run that created no workspace

    func testCanRetryOnlyAfterARunThatCreatedNoWorkspace() async {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])
        XCTAssertFalse(flow.canRetry, "nothing has run yet")

        await flow.run(initialize: { _ in 1 }, collect: { _, _ in 0 })
        XCTAssertTrue(flow.canRetry)
        XCTAssertFalse(flow.canContinue)

        await flow.run(initialize: { _ in 0 }, collect: { _, _ in 0 })
        XCTAssertFalse(flow.canRetry)
        XCTAssertTrue(flow.canContinue)
    }

    func testRetryRerunsInPlaceAndClearsTheEarlierFailure() async {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])
        await flow.run(initialize: { _ in 1 }, collect: { _, _ in 0 })
        XCTAssertEqual(flow.failureStages["alpha"], .workspace)

        var completeDuringRetry: Bool?
        await flow.run(
            initialize: { _ in completeDuringRetry = flow.didComplete; return 0 },
            collect: { _, _ in 0 }
        )

        XCTAssertEqual(completeDuringRetry, false,
                       "the screen must not show the last attempt's summary while retrying")
        XCTAssertEqual(flow.statuses["alpha"], .done)
        XCTAssertNil(flow.failureStages["alpha"])
        XCTAssertTrue(flow.didComplete)
    }

    func testRetryWordsTheSummaryFromTheSelectedProfilesOnly() async {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha", "beta"])
        await flow.run(initialize: { _ in 1 }, collect: { _, _ in 0 })
        flow.selected = ["alpha"]

        await flow.run(initialize: { _ in 1 }, collect: { _, _ in 0 })

        XCTAssertTrue(flow.completionText.contains("0 succeeded, 1 failed"), flow.completionText)
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

    // MARK: - Platform profiles: retired gateway and the connection check

    private func platformProfile(
        _ name: String, url: String = "us.api.jamfcloud.com",
        level: PlatformScopeLevel = .environment
    ) -> JamfCLIProfile {
        JamfCLIProfile(
            name: name, url: url, schedules: 0, status: .idle, authMethod: "platform",
            product: .pro, platformLevel: level)
    }

    private func failure(_ exit: Int32, _ message: String, hint: String? = nil) -> Data {
        var object: [String: Any] = ["error": "request failed", "message": message]
        if let hint { object["hint"] = hint }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// A runner whose version call and probe call answer as given; no jamf-cli runs.
    private func runner(
        version: ConnectionCheck.Attempt?, probe: ConnectionCheck.Attempt? = nil
    ) -> ConnectionCheck.Runner {
        { arguments in arguments.contains("jamf-pro-version") ? version : probe }
    }

    private func runAdopting(
        _ flow: ExistingCLISetupFlow, runner: ConnectionCheck.Runner?
    ) async -> [String] {
        var initialized: [String] = []
        await flow.run(
            connectionRunner: runner,
            initialize: { initialized.append($0); return 0 },
            collect: { _, _ in 0 })
        return initialized
    }

    func testAProfileOnTheRetiredGatewayIsRefusedAndNeverChecked() async {
        let flow = ExistingCLISetupFlow(profiles: [
            platformProfile("old", url: "us.apigw.jamf.com"),
            platformProfile("older", url: "https://apigw.jamf.com/"),
        ])
        XCTAssertEqual(flow.refusals["old"], GatewayRegion.retiredRefusal)
        XCTAssertEqual(flow.refusals["older"], GatewayRegion.retiredRefusal)
        XCTAssertTrue(flow.selected.isEmpty)
        let checked = Counter()
        let initialized = await runAdopting(flow, runner: { _ in checked.bump(); return nil })
        XCTAssertTrue(initialized.isEmpty)
        XCTAssertEqual(checked.count, 0, "no jamf-cli call for a refused profile")
    }

    func testAnAcceptedIDProceeds() async {
        let flow = ExistingCLISetupFlow(profiles: [platformProfile("prod")])
        let initialized = await runAdopting(flow, runner: runner(
            version: (0, Data(#"{"version":"11.25.0"}"#.utf8))))
        XCTAssertEqual(initialized, ["prod"])
        XCTAssertEqual(flow.statuses["prod"], .done)
        XCTAssertNil(flow.connectionNotes["prod"])
    }

    func testARejectedIDRefusesTheProfile() async {
        let flow = ExistingCLISetupFlow(profiles: [platformProfile("typo"), platformProfile("ok")])
        let rejected = failure(4, "[ENVIRONMENT_NOT_FOUND] Environment 'x' not found.")
        let initialized = await runAdopting(flow, runner: { args in
            args.contains("typo") ? (4, rejected) : (0, Data(#"{"version":"11.25.0"}"#.utf8))
        })
        XCTAssertEqual(initialized, ["ok"], "one refused profile does not stop the next")
        XCTAssertEqual(
            flow.statuses["typo"],
            .failed(ConnectionCheck.Verdict.rejectedID(.unknownEnvironment).message))
        XCTAssertEqual(flow.failureStages["typo"], .connection)
        XCTAssertTrue(flow.completionText.contains("connection check refused"))
    }

    func testNoJamfProRefusesAndPointsAtJamfSchool() async {
        let flow = ExistingCLISetupFlow(profiles: [platformProfile("campus")])
        let bare404 = failure(4, "resource not found (HTTP 404): GET /pro/v1/jamf-pro-version")
        let initialized = await runAdopting(flow, runner: runner(
            version: (4, bare404), probe: (0, Data("[]".utf8))))
        XCTAssertTrue(initialized.isEmpty)
        guard case .failed(let reason) = flow.statuses["campus"] else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(reason, ConnectionCheck.Verdict.noJamfPro.message)
        XCTAssertTrue(reason.contains("Jamf School"))
    }

    func testATenantLevelProfileGetsTheTenantWording() async {
        let flow = ExistingCLISetupFlow(profiles: [platformProfile("legacy", level: .tenant)])
        let bare404 = failure(4, "resource not found (HTTP 404): GET /pro/v1/jamf-pro-version")
        _ = await runAdopting(
            flow, runner: runner(version: (4, bare404), probe: (0, Data("[]".utf8))))
        XCTAssertEqual(
            flow.statuses["legacy"],
            .failed(ConnectionCheck.Verdict.noJamfPro.message(tenantLevel: true)))
    }

    func testAMissingPermissionProceedsWithANote() async {
        let flow = ExistingCLISetupFlow(profiles: [platformProfile("prod")])
        let forbidden = failure(5, "permission denied (HTTP 403)")
        let initialized = await runAdopting(flow, runner: runner(version: (5, forbidden)))
        XCTAssertEqual(initialized, ["prod"])
        XCTAssertEqual(flow.statuses["prod"], .done)
        XCTAssertEqual(
            flow.connectionNotes["prod"],
            ConnectionCheck.Verdict.missingPermission(names: []).message)
    }

    func testAnUndecidedCheckProceedsWithANote() async {
        let flow = ExistingCLISetupFlow(profiles: [platformProfile("prod")])
        let initialized = await runAdopting(flow, runner: runner(version: nil))
        XCTAssertEqual(initialized, ["prod"])
        XCTAssertEqual(
            flow.connectionNotes["prod"], ConnectionCheck.Verdict.undecided(exitCode: nil).message)
    }

    func testOnlyPlatformProfilesAreChecked() async {
        let flow = ExistingCLISetupFlow(profiles: [
            JamfCLIProfile(name: "oauth", url: "jamf.example.org", schedules: 0, status: .idle,
                           authMethod: "oauth2", product: .pro),
        ])
        let checked = Counter()
        let initialized = await runAdopting(flow, runner: { _ in checked.bump(); return nil })
        XCTAssertEqual(initialized, ["oauth"])
        XCTAssertEqual(checked.count, 0)
    }

    func testNoJamfCLIMeansNothingIsChecked() async {
        let flow = ExistingCLISetupFlow(profiles: [platformProfile("prod")])
        let initialized = await runAdopting(flow, runner: nil)
        XCTAssertEqual(initialized, ["prod"])
        XCTAssertNil(flow.connectionNotes["prod"])
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
}
