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
            profileCount: 2, initializedProfileCount: 0, demoMode: false, dismissed: false
        ))
        XCTAssertFalse(ExistingCLISetupFlow.shouldOffer(
            profileCount: 0, initializedProfileCount: 0, demoMode: false, dismissed: false
        ), "no profiles → the connection onboarding owns first launch")
        XCTAssertFalse(ExistingCLISetupFlow.shouldOffer(
            profileCount: 2, initializedProfileCount: 1, demoMode: false, dismissed: false
        ), "any initialized workspace means the app is already set up")
        XCTAssertFalse(ExistingCLISetupFlow.shouldOffer(
            profileCount: 2, initializedProfileCount: 0, demoMode: true, dismissed: false
        ), "demo mode never shows real setup")
        XCTAssertFalse(ExistingCLISetupFlow.shouldOffer(
            profileCount: 2, initializedProfileCount: 0, demoMode: false, dismissed: true
        ), "completed or skipped → never again")
    }

    // MARK: - run loop

    func testRunInitializesAndCollectsEverySelectedProfile() async {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha", "beta"])
        var initialized: [String] = []
        var collected: [String] = []

        await flow.run(
            initialize: { initialized.append($0); return 0 },
            collect: { collected.append($0); return 0 }
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
            collect: { _ in 0 }
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
            collect: { collected.append($0); return 0 }
        )

        XCTAssertEqual(collected, ["beta"], "failed init must not attempt a collect")
        XCTAssertEqual(flow.statuses["alpha"], .failed("workspace init exited 1"))
        XCTAssertEqual(flow.statuses["beta"], .done)
        XCTAssertTrue(flow.didComplete, "one failure never blocks completion")
    }

    func testCollectFailureCarriesActionableMessage() async {
        let flow = ExistingCLISetupFlow(profileNames: ["alpha"])

        await flow.run(initialize: { _ in 0 }, collect: { _ in 3 })

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

        await flow.run(initialize: { _ in throw Boom() }, collect: { _ in 0 })

        XCTAssertEqual(flow.statuses["alpha"], .failed("boom"))
        XCTAssertTrue(flow.didComplete)
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
}
