import XCTest
@testable import JamfReports

/// Per-kind data-freshness health: the twin of `AutomationHealthTests`.
///
/// The field defect these pin: on a production tenant, `Managed Freshness`
/// runs recorded OK on consecutive days while `security` sat 35 days stale and
/// `computers` 99 days stale. `ReportEngine.collect` warns and falls back to
/// cache when one kind fails, and that warning never reached the run's exit
/// code — so a green run and a months-broken data source were indistinguishable.
///
/// The rules pinned here are the ones that decide whether an operator is told:
/// - a repeatedly-failing kind reports the CAUSE, not the symptom,
/// - one missed cycle is not an alert (cadence boundaries and slow nights),
/// - a never-collected kind alarms only on a workspace that has collected,
/// - remediation targets only the tiers that are actually broken.
final class DataFreshnessHealthTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(
        _ kind: String,
        successAgo: TimeInterval? = nil,
        failures: Int = 0
    ) -> KindCollectionState {
        KindCollectionState(
            kind: kind,
            lastSuccess: successAgo.map { now.addingTimeInterval(-$0) },
            consecutiveFailures: failures,
            lastFailure: failures > 0 ? now.addingTimeInterval(-3600) : nil
        )
    }

    // MARK: - Stale threshold

    func testKindOneCadenceBehindIsNotStale() {
        // 13h on a 12h cadence: one boundary miss is normal operation.
        let issues = DataFreshnessHealth.evaluate(
            states: [state("security", successAgo: 13 * 3600)],
            hasCollectedBefore: true, now: now
        )
        XCTAssertTrue(issues.isEmpty)
    }

    func testKindThreeCadencesBehindIsStale() {
        // 37h on a 12h cadence crosses the 3× budget.
        let issues = DataFreshnessHealth.evaluate(
            states: [state("security", successAgo: 37 * 3600)],
            hasCollectedBefore: true, now: now
        )
        XCTAssertEqual(issues.map(\.snapshotKind), ["security"])
        XCTAssertEqual(issues.first?.kind, .stale)
    }

    func testProductionAgesAllReportStale() {
        // The exact prod state from the 2026-08-25 screenshots.
        let issues = DataFreshnessHealth.evaluate(
            states: [
                state("overview", successAgo: 600),                    // fresh
                state("patch-status", successAgo: 600),                // fresh
                state("security", successAgo: 35 * 86_400),            // 35d, 12h cadence
                state("computers", successAgo: 99 * 86_400),           // 99d, 2d cadence
                state("patch-device-failures", successAgo: 80 * 86_400) // 80d, 7d cadence
            ],
            hasCollectedBefore: true, now: now
        )
        XCTAssertEqual(
            Set(issues.map(\.snapshotKind)),
            ["security", "computers", "patch-device-failures"]
        )
    }

    // MARK: - Failing beats stale

    func testRepeatedFailuresReportAsFailingNotStale() {
        let issues = DataFreshnessHealth.evaluate(
            states: [state("computers", successAgo: 99 * 86_400, failures: 4)],
            hasCollectedBefore: true, now: now
        )
        // Both conditions hold; the operator needs the cause, not the symptom.
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.kind, .failing)
        XCTAssertEqual(issues.first?.consecutiveFailures, 4)
    }

    func testSingleFailureIsNotAnAlert() {
        // One blip is what the in-run retry exists to absorb.
        let issues = DataFreshnessHealth.evaluate(
            states: [state("overview", successAgo: 600, failures: 1)],
            hasCollectedBefore: true, now: now
        )
        XCTAssertTrue(issues.isEmpty)
    }

    func testFailingSortsAboveStale() {
        let issues = DataFreshnessHealth.evaluate(
            states: [
                state("security", successAgo: 40 * 86_400),
                state("computers", failures: 3)
            ],
            hasCollectedBefore: true, now: now
        )
        XCTAssertEqual(issues.map(\.kind), [.failing, .stale])
    }

    // MARK: - Never-collected

    func testNeverCollectedKindAlarmsOnAnEstablishedWorkspace() {
        // prod's `update-device-failures: never` — a real gap, not a new install.
        let issues = DataFreshnessHealth.evaluate(
            states: [
                state("overview", successAgo: 600),
                state("update-device-failures")
            ],
            hasCollectedBefore: true, now: now
        )
        XCTAssertEqual(issues.map(\.snapshotKind), ["update-device-failures"])
        XCTAssertNil(issues.first?.lastSuccess)
    }

    func testFreshWorkspaceDoesNotAlarmOnEveryKind() {
        let states = ReportEngine.knownCollectKinds.map { state($0) }
        let issues = DataFreshnessHealth.evaluate(
            states: states, hasCollectedBefore: false, now: now
        )
        XCTAssertTrue(
            issues.isEmpty, "A workspace that has never collected must not emit 30 alarms"
        )
    }

    // MARK: - Unmapped kinds

    func testUnmappedKindIsIgnored() {
        let issues = DataFreshnessHealth.evaluate(
            states: [state("not-a-real-kind", successAgo: 400 * 86_400)],
            hasCollectedBefore: true, now: now
        )
        XCTAssertTrue(issues.isEmpty, "A kind with no tier has no cadence policy to violate")
    }

    // MARK: - Remediation targeting

    func testRemediationCollectsOnlyAffectedTiers() {
        let issues = DataFreshnessHealth.evaluate(
            states: [
                state("security", successAgo: 40 * 86_400),   // refresh tier
                state("computers", successAgo: 99 * 86_400)   // inventory tier
            ],
            hasCollectedBefore: true, now: now
        )
        XCTAssertEqual(DataFreshnessHealth.tiersToRemediate(issues), [.refresh, .inventory])
    }

    func testRemediationOfHealthyFleetIsEmpty() {
        XCTAssertTrue(DataFreshnessHealth.tiersToRemediate([]).isEmpty)
    }

    // MARK: - Self-remediation dispatch (Task 3 / M2)
    //
    // `remediateOne` used to hand ALL affected tiers to `CollectRouter.run` in
    // one call. When every tier is affected, that set equals
    // `CollectionTier.allCases` — the exact value `ReportEngine.collect`'s
    // once-per-day FULL-collect guard checks for — so the "remediation" would
    // silently no-op on a day the full collect already ran. Dispatching one
    // call per tier makes that equality impossible to produce by accident.

    func testRemediateOneDispatchesOneCallPerTierNotTheFullSetAtOnce() async {
        let recorder = RemediationDispatchRecorder()
        let allTiers = Set(CollectionTier.allCases)
        XCTAssertEqual(allTiers.count, 3, "premise: three tiers exist")

        await WorkspaceStore.remediateOne(profile: "remediatespy", tiers: allTiers) {
            _, tiers, _ in recorder.record(tiers)
        }

        XCTAssertEqual(recorder.calls.count, 3, "one collect call per tier")
        XCTAssertEqual(Set(recorder.calls), Set(allTiers.map { Set([$0]) }),
                       "each call must carry exactly one tier")
        XCTAssertFalse(recorder.calls.contains(allTiers),
                       "the full tier set must never be dispatched as a single call")
    }

    func testRemediateOneOfASingleTierDispatchesOneCall() async {
        let recorder = RemediationDispatchRecorder()

        await WorkspaceStore.remediateOne(profile: "remediatespy", tiers: [.scan]) {
            _, tiers, _ in recorder.record(tiers)
        }

        XCTAssertEqual(recorder.calls, [[.scan]])
    }

    // MARK: - Never-retryable exit exclusion (Task 3 / S9)
    //
    // A jamf-cli exit 2 is a usage or credentials-gate failure (e.g. the
    // 1.24–1.27 Security Cloud gate on `pro report security`); an exit 8
    // (1.28+) is a policy refusal — the command is outside what the profile's
    // API publishes. Both fail identically on every retry, so remediation must
    // not spend a collect on either.
    // A permanent recorded failure cause (rejected scope ID, unknown environment ID, endpoint
    // not served, missing permission) is excluded the same way (2.8.1).
    // They stay visible: the banner reads `issues`, which is never filtered — only the
    // re-collect tiers are.

    func testNeverRetryableFailuresAreExcludedFromRemediationTargeting() throws {
        let profile = "exittwofilter"
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-ExitTwo-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true
        )
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        defer {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let stateDir = try WorkspacePaths.stateDir(for: profile)
        let store = StateFileStore(directory: stateDir)
        // A usage/credentials-gate failure — cannot succeed on retry.
        store.record(.failed(exitCode: CLIBridge.exitCodeUsage), report: "security", at: now)
        // A policy refusal (jamf-cli 1.28+) — equally permanent, different cause.
        store.record(
            .failed(exitCode: CLIBridge.exitCodeRefusedByPolicy), report: "policies", at: now)
        // A transient (retryable-class) failure on a different kind — must stay.
        store.record(.failed(exitCode: 1), report: "computers", at: now)

        let issues = [
            DataFreshnessIssue(
                snapshotKind: "security", tier: .refresh, kind: .failing,
                lastSuccess: nil, consecutiveFailures: 2, lastFailure: now
            ),
            DataFreshnessIssue(
                snapshotKind: "policies", tier: .scan, kind: .failing,
                lastSuccess: nil, consecutiveFailures: 2, lastFailure: now
            ),
            DataFreshnessIssue(
                snapshotKind: "computers", tier: .inventory, kind: .failing,
                lastSuccess: nil, consecutiveFailures: 2, lastFailure: now
            )
        ]

        let remediable = WorkspaceStore.excludingPermanentUsageFailures(issues, profile: profile)
        XCTAssertEqual(remediable.map(\.snapshotKind), ["computers"])
        XCTAssertEqual(DataFreshnessHealth.tiersToRemediate(remediable), [.inventory])
    }

    /// Exit 3 (HTTP 401) means the stored credentials were rejected. Until someone
    /// re-authenticates, every hourly retry repeats the same 401 against the server, so
    /// remediation leaves those kinds to Collect now and the tick's same-day retries.
    func testCredentialRejectionsAreExcludedFromRemediationTargeting() throws {
        let profile = "exitthreefilter"
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-ExitThree-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true
        )
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        defer {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let stateDir = try WorkspacePaths.stateDir(for: profile)
        let store = StateFileStore(directory: stateDir)
        // Rejected credentials on kinds in two tiers — neither can land before a re-auth.
        store.record(
            .failed(exitCode: CLIBridge.exitCodeUnauthorized), report: "security", at: now)
        store.record(
            .failed(exitCode: CLIBridge.exitCodeUnauthorized),
            report: "patch-device-failures", at: now)
        // A transient (retryable-class) failure on a different kind — must stay.
        store.record(.failed(exitCode: 1), report: "computers", at: now)

        let issues = [
            DataFreshnessIssue(
                snapshotKind: "security", tier: .refresh, kind: .failing,
                lastSuccess: nil, consecutiveFailures: 2, lastFailure: now
            ),
            DataFreshnessIssue(
                snapshotKind: "patch-device-failures", tier: .scan, kind: .failing,
                lastSuccess: nil, consecutiveFailures: 2, lastFailure: now
            ),
            DataFreshnessIssue(
                snapshotKind: "computers", tier: .inventory, kind: .failing,
                lastSuccess: nil, consecutiveFailures: 2, lastFailure: now
            )
        ]

        let remediable = WorkspaceStore.excludingPermanentUsageFailures(issues, profile: profile)
        XCTAssertEqual(remediable.map(\.snapshotKind), ["computers"])
        XCTAssertEqual(DataFreshnessHealth.tiersToRemediate(remediable), [.inventory])
    }

    /// Spec §9.5: a rejected scope ID, an unserved endpoint and a missing permission cannot be
    /// fixed by retrying; a gateway edge block can.
    func testPermanentFailureCausesAreExcludedFromRemediationTargeting() throws {
        let profile = "causefilter"
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Cause-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true
        )
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        defer {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        let store = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        func record(_ report: String, _ kind: FailureCause.Kind, exit: Int32) {
            store.record(.failed(exitCode: exit), report: report, at: now,
                         cause: FailureCause(kind: kind, names: [], hint: nil, exitCode: exit))
        }
        record("security", .missingPermission, exit: 5)
        record("computers", .unknownEnvironment, exit: 4)
        record("policies", .edgeBlocked, exit: 5)

        let issues = ["security", "computers", "policies"].map {
            DataFreshnessIssue(
                snapshotKind: $0, tier: .inventory, kind: .failing,
                lastSuccess: nil, consecutiveFailures: 2, lastFailure: now
            )
        }
        let remediable = WorkspaceStore.excludingPermanentUsageFailures(issues, profile: profile)
        XCTAssertEqual(remediable.map(\.snapshotKind), ["policies"])
    }

    func testNoExitTwoFailureLeavesIssuesUntouched() throws {
        let profile = "exittwofilter-none"
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-ExitTwo-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true
        )
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        defer {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }

        let stateDir = try WorkspacePaths.stateDir(for: profile)
        StateFileStore(directory: stateDir)
            .record(.failed(exitCode: 1), report: "security", at: now)

        let issues = [
            DataFreshnessIssue(
                snapshotKind: "security", tier: .refresh, kind: .failing,
                lastSuccess: nil, consecutiveFailures: 2, lastFailure: now
            )
        ]
        XCTAssertEqual(
            WorkspaceStore.excludingPermanentUsageFailures(issues, profile: profile), issues
        )
    }

    // MARK: - In-run retry policy

    func testRetryNeverRepeatsAnAuthOrUsageFailure() {
        // Retrying 401/403 cannot succeed (credential state does not change in
        // three seconds) and risks tripping server-side lockout; 2 is a caller
        // bug; 4 means the resource does not exist. Only transient classes retry.
        for deterministic in [CLIBridge.exitCodeUsage,
                              CLIBridge.exitCodeUnauthorized,
                              CLIBridge.exitCodeNotFound,
                              CLIBridge.exitCodePermissionDenied,
                              CLIBridge.exitCodePartialFailure] {
            XCTAssertFalse(
                ReportEngine.retryableExitCodes.contains(deterministic),
                "exit \(deterministic) must not be retried"
            )
        }
    }

    func testRetryCoversTheTransientClasses() {
        XCTAssertTrue(ReportEngine.retryableExitCodes.contains(1),
                      "generic failure is the on-prem request timeout")
        XCTAssertTrue(ReportEngine.retryableExitCodes.contains(CLIBridge.exitCodeRateLimited),
                      "429 is a retry instruction by definition")
    }

    // MARK: - Degraded-run detection

    private func outcome(_ kind: String, _ code: Int32) -> ReportEngine.CollectOutcome {
        ReportEngine.CollectOutcome(kind: kind, exitCode: code)
    }

    func testDegradedKindsNamesOnlySourcesThatServedStaleCache() {
        let degraded = ReportEngine.degradedKinds(
            outcomes: [outcome("overview", 0), outcome("security", 1), outcome("computers", 5)],
            savedKinds: ["overview"]
        )
        XCTAssertEqual(degraded, ["computers", "security"])
    }

    func testExitSevenThatSavedIsNotDegraded() {
        // Exit 7 normally carries valid JSON for the successful subset, which
        // `collect` saves. Flagging it would put a Partial pill on a run whose
        // data landed — a pill that cries wolf is worse than no pill at all.
        let degraded = ReportEngine.degradedKinds(
            outcomes: [outcome("patch-status", CLIBridge.exitCodePartialFailure)],
            savedKinds: ["patch-status"]
        )
        XCTAssertTrue(degraded.isEmpty)
    }

    func testExitSevenThatSavedNothingIsDegraded() {
        // The case an exit-code-based rule gets wrong: exit 7 whose output was
        // empty or non-JSON writes no snapshot, so the operator IS being served
        // stale cache and must be told.
        let degraded = ReportEngine.degradedKinds(
            outcomes: [outcome("patch-status", CLIBridge.exitCodePartialFailure)],
            savedKinds: []
        )
        XCTAssertEqual(degraded, ["patch-status"])
    }

    func testExitZeroCarryingUnusableOutputIsDegraded() {
        // Cobra prints parent help and exits 0 for a renamed command; nothing is
        // saved. A rule keyed on the exit code would call that run healthy.
        let degraded = ReportEngine.degradedKinds(
            outcomes: [outcome("classic-macos-profiles", 0)], savedKinds: []
        )
        XCTAssertEqual(degraded, ["classic-macos-profiles"])
    }

    func testAKindThatSavedDespiteAFailingExitIsNotDegraded() {
        let degraded = ReportEngine.degradedKinds(
            outcomes: [outcome("security", 1)], savedKinds: ["security"]
        )
        XCTAssertTrue(degraded.isEmpty, "The snapshot on disk is what the operator cares about")
    }

    func testHealthyRunReportsNothingDegraded() {
        let degraded = ReportEngine.degradedKinds(
            outcomes: [outcome("overview", 0), outcome("security", 0)],
            savedKinds: ["overview", "security"]
        )
        XCTAssertTrue(degraded.isEmpty)
    }

    // MARK: - Remediation rate limit

    func testRemediationRateLimitIsHourlyNotDaily() {
        let f = WorkspaceStore.hourKeyFormatter
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // Two attempts in the same hour collapse to one key (the second no-ops);
        // an hour later the key changes, so a source broken at 10:00 is retried
        // when the operator opens the app at 14:00 rather than waiting a day.
        XCTAssertEqual(f.string(from: base), f.string(from: base.addingTimeInterval(59 * 60)))
        XCTAssertNotEqual(f.string(from: base), f.string(from: base.addingTimeInterval(3600)))
        XCTAssertNotEqual(f.string(from: base), f.string(from: base.addingTimeInterval(86_400)))
    }

    // MARK: - Copy

    func testCadenceLabelDerivesFromTheTierNotAHardcodedString() {
        XCTAssertEqual(CollectionTier.refresh.cadenceLabel, "12h")
        XCTAssertEqual(CollectionTier.inventory.cadenceLabel, "2 days")
        XCTAssertEqual(CollectionTier.scan.cadenceLabel, "7 days")
    }

    func testNeverCollectedSummaryDoesNotClaimAnAge() {
        let issues = DataFreshnessHealth.evaluate(
            states: [state("overview", successAgo: 600), state("update-device-failures")],
            hasCollectedBefore: true, now: now
        )
        let summary = try? XCTUnwrap(issues.first).summary
        XCTAssertEqual(summary, "update-device-failures has never been collected successfully")
    }

    // MARK: - neverCollected (never attempted vs never landed)

    /// Both dates nil means the kind was never attempted here. One recorded
    /// failure is an attempt; one recorded success is obviously not "never".
    func testNeverCollectedIsTrueOnlyWhenNoSuccessAndNoFailureAreRecorded() {
        func issue(success: Date?, failure: Date?) -> DataFreshnessIssue {
            DataFreshnessIssue(
                snapshotKind: "computers", tier: .inventory, kind: .stale,
                lastSuccess: success, consecutiveFailures: failure == nil ? 0 : 1,
                lastFailure: failure
            )
        }
        XCTAssertTrue(issue(success: nil, failure: nil).neverCollected)
        XCTAssertFalse(issue(success: nil, failure: now).neverCollected)
        XCTAssertFalse(issue(success: now, failure: nil).neverCollected)
        XCTAssertFalse(issue(success: now, failure: now).neverCollected)
    }

    /// The evaluator threads both dates through, so a kind never attempted on
    /// an established workspace reads `neverCollected` while a kind that keeps
    /// failing (an attempt) does not — even though neither has ever landed.
    func testEvaluateDistinguishesNeverAttemptedFromNeverLanded() {
        let issues = DataFreshnessHealth.evaluate(
            states: [
                state("overview", successAgo: 600),
                state("update-device-failures"),
                state("computers", failures: 3),
            ],
            hasCollectedBefore: true, now: now
        )
        let byKind = Dictionary(uniqueKeysWithValues: issues.map { ($0.snapshotKind, $0) })
        XCTAssertEqual(byKind["update-device-failures"]?.neverCollected, true)
        XCTAssertEqual(byKind["computers"]?.neverCollected, false)
    }

    /// Never-attempted kinds are still collect work: remediation and the
    /// banner's "Collect now" must keep targeting their tiers.
    func testNeverCollectedKindsStillTargetTheirTierForRemediation() throws {
        let issues = DataFreshnessHealth.evaluate(
            states: [state("overview", successAgo: 600), state("update-device-failures")],
            hasCollectedBefore: true, now: now
        )
        let issue = try XCTUnwrap(issues.first)
        XCTAssertTrue(issue.neverCollected)
        XCTAssertEqual(DataFreshnessHealth.tiersToRemediate(issues), [issue.tier])
    }

    func testAnIssueCarriesItsKindsRecordedCause() {
        let cause = FailureCause(kind: .unknownEnvironment, names: [], hint: nil, exitCode: 4)
        let issues = DataFreshnessHealth.evaluate(
            states: [KindCollectionState(kind: "security", lastSuccess: nil,
                                         consecutiveFailures: 2, lastFailure: now, cause: cause)],
            hasCollectedBefore: true, now: now)
        XCTAssertEqual(issues.first?.cause, cause)
    }
}

/// Thread-safe call recorder for `WorkspaceStore.RemediationCollector` spies —
/// mirrors `RouterCallCounter` in `CollectRouterTests.swift`.
private final class RemediationDispatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [Set<CollectionTier>] = []
    var calls: [Set<CollectionTier>] { lock.withLock { _calls } }
    func record(_ tiers: Set<CollectionTier>) {
        lock.withLock { _calls.append(tiers) }
    }
}
