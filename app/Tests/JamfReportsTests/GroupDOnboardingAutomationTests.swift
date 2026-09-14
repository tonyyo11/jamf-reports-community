import Foundation
import XCTest
@testable import JamfReports

// MARK: - GroupD: first-time-admin review fixes
//
// D1 — onboarding's first report collects before it generates (Jamf Pro path).
// D5 — the optional "Map your columns" checklist row doesn't block completion.
// D10 — the "Automation is off" banner only fires when something wants the ticker.

@MainActor
final class GroupDOnboardingAutomationTests: XCTestCase {

    // MARK: - D1: runFirstReport collects before generating (Jamf Pro path)

    /// Records the order closures were invoked in. A plain class (not an
    /// actor) is safe here: `runFirstReport` is `@MainActor` and awaits each
    /// closure directly — it never hops to a background task before invoking
    /// `collect`/`generate` — so every mutation happens serially on the
    /// main actor, same as the test itself.
    private final class CallRecorder {
        var calls: [String] = []
    }

    /// Isolates `ProfileService.discoverLocal()` (called by `WorkspaceStore`
    /// init and `reloadFromDisk()`) to a throwaway temp directory instead of
    /// the real `~/Jamf-Reports`, mirroring the pattern in
    /// `OnboardingFlowMultiProductTests`.
    private func withIsolatedWorkspacesRoot(_ body: () async throws -> Void) async rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroupD-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        defer {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        try await body()
    }

    func test_runFirstReport_proPath_collectsBeforeGenerating() async throws {
        await withIsolatedWorkspacesRoot {
            let flow = OnboardingFlow()
            flow.productPath = .pro
            flow.profileName = "grpd\(Int.random(in: 1000...9999))"
            let workspace = WorkspaceStore(demoMode: true)
            let recorder = CallRecorder()

            await flow.runFirstReport(
                workspaceStore: workspace,
                collect: { _, _ in recorder.calls.append("collect"); return 0 },
                generate: { _, _ in recorder.calls.append("generate"); return 0 }
            )

            XCTAssertEqual(
                recorder.calls, ["collect", "generate"],
                "the Jamf Pro path must collect before it generates"
            )
            XCTAssertEqual(flow.firstReportExitCode, 0)
            XCTAssertNil(flow.lastError)
        }
    }

    func test_runFirstReport_proPath_stopsBeforeGenerateOnCollectFailure() async throws {
        await withIsolatedWorkspacesRoot {
            let flow = OnboardingFlow()
            flow.productPath = .pro
            flow.profileName = "grpd\(Int.random(in: 1000...9999))"
            let workspace = WorkspaceStore(demoMode: true)
            let recorder = CallRecorder()

            await flow.runFirstReport(
                workspaceStore: workspace,
                collect: { _, _ in recorder.calls.append("collect"); return 3 },
                generate: { _, _ in recorder.calls.append("generate"); return 0 }
            )

            XCTAssertEqual(
                recorder.calls, ["collect"],
                "generate must never run when the collect step failed"
            )
            XCTAssertEqual(
                flow.firstReportExitCode, 3,
                "the reported exit code must be the collect failure, not a generate result"
            )
            XCTAssertNotNil(flow.lastError)
        }
    }

    // The Jamf School path is deliberately left unchanged (per D1) and so is
    // not given an injectable seam here — it calls the real, un-mocked
    // `CLIBridge().schoolGenerate`, which would spawn a real jamf-cli
    // process. It is exercised by the existing School-path onboarding tests,
    // not this group.

    // MARK: - D5: the optional "Map your columns" row doesn't block completion

    func test_checklist_customizeStep_isMarkedOptional() {
        let checklist = GettingStartedChecklist.build(
            connected: false, collected: false, customized: false, scheduled: false, reported: false
        )
        let customize = checklist.steps.first { $0.kind == .customize }
        XCTAssertEqual(customize?.isOptional, true, "'Map your columns' must be optional")
        for step in checklist.steps where step.kind != .customize {
            XCTAssertFalse(step.isOptional, "\(step.kind) must remain a required step")
        }
    }

    func test_checklist_isComplete_ignoresTheOptionalCustomizeRow() {
        let checklist = GettingStartedChecklist.build(
            connected: true, collected: true,
            customized: false, scheduled: true, reported: true
        )
        XCTAssertTrue(
            checklist.isComplete,
            "an undone optional step must not block GettingStartedChecklist.isComplete"
        )
        XCTAssertEqual(checklist.completedCount, 4, "customize is still counted as not-done")
    }

    func test_checklist_isComplete_stillRequiresEveryNonOptionalStep() {
        let checklist = GettingStartedChecklist.build(
            connected: true, collected: true,
            customized: true, scheduled: false, reported: true
        )
        XCTAssertFalse(
            checklist.isComplete,
            "a required step (schedule) left undone must still block completion"
        )
    }

    // MARK: - D10: the ticker-disabled banner only fires when something wants the ticker

    func test_tickerDisabledBanner_hidesWhenNothingWantsTheTicker() {
        let policy = AutomationPolicy()  // isManaged == false by default
        XCTAssertFalse(
            tickerDisabledBannerShouldShow(
                policy: policy, hasHandBuilt: false, tickerStatus: .notRegistered
            ),
            "an unregistered ticker with nothing scheduled is the correct state, not a problem"
        )
        XCTAssertFalse(
            tickerDisabledBannerShouldShow(
                policy: policy, hasHandBuilt: false, tickerStatus: .requiresApproval
            )
        )
    }

    func test_tickerDisabledBanner_showsWhenManagedAutomationWantsIt() {
        let policy = AutomationPolicy(isManaged: true)
        XCTAssertTrue(
            tickerDisabledBannerShouldShow(
                policy: policy, hasHandBuilt: false, tickerStatus: .notRegistered
            )
        )
        XCTAssertFalse(
            tickerDisabledBannerShouldShow(
                policy: policy, hasHandBuilt: false, tickerStatus: .enabled
            ),
            "a running ticker is never a problem, managed or not"
        )
    }

    func test_tickerDisabledBanner_showsWhenAHandBuiltScheduleWantsIt() {
        let policy = AutomationPolicy()  // isManaged == false
        XCTAssertTrue(
            tickerDisabledBannerShouldShow(
                policy: policy, hasHandBuilt: true, tickerStatus: .requiresApproval
            ),
            "a hand-built schedule needs the ticker too, even with managed automation off"
        )
    }

    func test_tickerDisabledBanner_ignoresTheUnavailableStatus() {
        let policy = AutomationPolicy(isManaged: true)
        XCTAssertFalse(
            tickerDisabledBannerShouldShow(
                policy: policy, hasHandBuilt: false, tickerStatus: .unavailable
            ),
            "an unavailable (dev-build) ticker has its own separate banner"
        )
    }
}
