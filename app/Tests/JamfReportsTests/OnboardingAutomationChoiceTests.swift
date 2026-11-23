import Foundation
import XCTest
@testable import JamfReports

/// The last onboarding step's "Run automatically" choice and optional webhook, applied by
/// `OnboardingFlow.finishSetup`. No jamf-cli and no real SMAppService (`StubTickerRegistrar`).
@MainActor
final class OnboardingAutomationChoiceTests: XCTestCase {
    private let profile = "onb-auto"

    private func policy() -> AutomationPolicy { AutomationPolicy.current() }

    /// A temp workspaces root holding `profile`'s config.yaml, an empty stored policy, and the
    /// legacy-plist import marked done so `applyAutomationPolicy` never reads the real
    /// ~/Library/LaunchAgents.
    private func makeStore(
        storedPolicy: AutomationPolicy? = nil, demo: Bool = false, realProfile: Bool = true,
        otherProfile: String? = nil
    ) throws -> (WorkspaceStore, StubTickerRegistrar) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnbAuto-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("jamf_cli:\n  profile: \"\(profile)\"\n".utf8)
            .write(to: workspace.appendingPathComponent("config.yaml"))
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)

        let defaults = UserDefaults.standard
        let savedPolicy = defaults.object(forKey: AutomationPolicy.storageKey)
        let savedImport = defaults.object(forKey: ScheduleImport.defaultsKey)
        defaults.set(true, forKey: ScheduleImport.defaultsKey)
        if let storedPolicy {
            defaults.set(storedPolicy.serialize(), forKey: AutomationPolicy.storageKey)
        } else {
            defaults.removeObject(forKey: AutomationPolicy.storageKey)
        }
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
            defaults.set(savedPolicy, forKey: AutomationPolicy.storageKey)
            defaults.set(savedImport, forKey: ScheduleImport.defaultsKey)
            defaults.removeObject(forKey: WorkspaceStore.forceDemoModeKey)
        }
        _ = useTemporaryTickLock()
        let registrar = StubTickerRegistrar()
        let profile = profile
        let store = WorkspaceStore(
            demoMode: demo, tickerRegistrar: registrar,
            jamfCLIProfileNames: { [] },
            discoverProfiles: {
                (otherProfile.map { [JamfCLIProfile(name: $0, url: "", schedules: 0, status: .idle)] }
                    ?? [])
                    + (realProfile
                        ? [JamfCLIProfile(name: profile, url: "", schedules: 0, status: .idle)] : [])
            },
            jamfCLIInstallation: { nil })
        store.resolveAuthMethod = { _ in nil }
        return (store, registrar)
    }

    private func makeFlow() -> OnboardingFlow {
        let flow = OnboardingFlow()
        flow.profileName = profile
        return flow
    }

    func testTickedByDefaultTurnsOnManagedAutomationAndRegistersTheAgent() async throws {
        let (store, registrar) = try makeStore()
        let flow = makeFlow()
        XCTAssertTrue(flow.automation.enabled, "the choice is on by default")

        await flow.finishSetup(in: store)

        XCTAssertTrue(policy().isManaged)
        XCTAssertEqual(registrar.registerCalls, 1)
    }

    /// New workspace from the Add sheet: another workspace is active when setup finishes, and
    /// Overview must open on the one just made.
    func testFinishingSetupMakesTheNewWorkspaceActive() async throws {
        let (store, _) = try makeStore(otherProfile: "onb-earlier")
        store.reloadFromDisk()
        store.setProfile("onb-earlier")
        XCTAssertEqual(store.profile, "onb-earlier")

        await makeFlow().finishSetup(in: store)

        XCTAssertEqual(store.profile, profile)
    }

    func testUntickedLeavesThePolicyAndTheAgentAlone() async throws {
        let (store, registrar) = try makeStore()
        let flow = makeFlow()
        flow.automation.enabled = false

        await flow.finishSetup(in: store)

        XCTAssertFalse(policy().isManaged)
        XCTAssertEqual(registrar.registerCalls, 0)
        XCTAssertEqual(registrar.unregisterCalls, 0)
    }

    func testAnExistingManagedPolicyIsNeverTurnedOffOrRewritten() async throws {
        var existing = AutomationPolicy(isManaged: true)
        existing.runTime = "02:30"
        existing.scanWeekday = 4
        let (store, _) = try makeStore(storedPolicy: existing)

        let unticked = makeFlow()
        unticked.automation.enabled = false
        await unticked.finishSetup(in: store)
        XCTAssertEqual(policy(), existing)

        let ticked = makeFlow()
        await ticked.finishSetup(in: store)
        XCTAssertEqual(policy(), existing, "setup must not overwrite the user's schedule")
    }

    func testTheChosenScheduleReachesThePolicy() async throws {
        let (store, _) = try makeStore()
        let flow = makeFlow()
        flow.automation.scanWeekday = 3
        flow.automation.reportsCadence = .monthly
        flow.automation.runTime = "07:15"

        await flow.finishSetup(in: store)

        XCTAssertEqual(policy().scanWeekday, 3)
        XCTAssertEqual(policy().reportsCadence, .monthly)
        XCTAssertEqual(policy().runTime, "07:15")
    }

    func testAnHTTPSWebhookIsWrittenAsTheNotifyBlock() async throws {
        let (store, _) = try makeStore()
        let flow = makeFlow()
        flow.webhookProvider = .slack
        flow.webhookURL = "  https://hooks.example.com/abc  "

        await flow.finishSetup(in: store)

        let notify = NotifyConfigLoader.load(profile: profile)
        XCTAssertTrue(notify.isUsable)
        XCTAssertEqual(notify.resolvedProvider, .slack)
        XCTAssertEqual(notify.resolvedURL, "https://hooks.example.com/abc")
        XCTAssertEqual(notify.resolvedDetail, .full)
    }

    func testAnEmptyOrNonHTTPSWebhookWritesNothing() async throws {
        for url in ["", "   ", "http://hooks.example.com/abc", "hooks.example.com"] {
            let (store, _) = try makeStore()
            let flow = makeFlow()
            flow.webhookURL = url
            XCTAssertFalse(flow.isWebhookUsable, url)

            await flow.finishSetup(in: store)

            let text = try String(
                contentsOf: ProfileService.workspaceURL(for: profile)!
                    .appendingPathComponent("config.yaml"), encoding: .utf8)
            XCTAssertFalse(text.contains("notify:"), "no notify block for \"\(url)\"")
        }
    }

    /// Setup started from demo mode creates a real profile; finishing it gets both.
    func testSetupStartedInDemoModeAppliesTheWebhookAndTheAutomation() async throws {
        let (store, registrar) = try makeStore(demo: true)
        let flow = makeFlow()
        flow.webhookURL = "https://hooks.example.com/abc"

        await flow.finishSetup(in: store)

        XCTAssertFalse(store.demoMode)
        XCTAssertTrue(policy().isManaged)
        XCTAssertEqual(registrar.registerCalls, 1)
        XCTAssertTrue(NotifyConfigLoader.load(profile: profile).isUsable)
    }

    /// No real profile found: the store stays in demo mode and neither is applied.
    func testAStoreStillInDemoModeAppliesNeither() async throws {
        let (store, registrar) = try makeStore(demo: true, realProfile: false)
        let flow = makeFlow()
        flow.webhookURL = "https://hooks.example.com/abc"

        await flow.finishSetup(in: store)

        XCTAssertTrue(store.demoMode)
        XCTAssertFalse(policy().isManaged)
        XCTAssertEqual(registrar.registerCalls, 0)
        XCTAssertFalse(NotifyConfigLoader.load(profile: profile).isUsable)
    }

    func testSharedChoiceBuildsThePolicyTheAdoptFlowUses() {
        let choice = AutomationSetupChoice(
            enabled: true, scanWeekday: 2, reportsCadence: .daily, runTime: "05:00")
        let applied = choice.applied(to: AutomationPolicy())
        XCTAssertTrue(applied.isManaged)
        XCTAssertEqual(applied.reportsWeekday, 2)
        var off = choice
        off.enabled = false
        XCTAssertEqual(off.applied(to: AutomationPolicy(isManaged: true)).isManaged, true)
    }
}
