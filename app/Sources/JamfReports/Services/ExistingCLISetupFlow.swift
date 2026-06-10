import Foundation

/// State machine for the secondary onboarding (issue #181 follow-on): first
/// launch where jamf-cli is already installed and configured — profiles exist,
/// so `OnboardingView` never runs — but no profile has an app workspace yet.
///
/// The standard `OnboardingFlow` assumes a brand-new connection (creates the
/// profile, authenticates via PTY). This flow skips straight to what an
/// existing jamf-cli user is missing: per-profile workspaces with fresh
/// `jamf-cli-data`, automated scans (the managed `AutomationPolicy` layer),
/// and a first collection so Trends has a starting data point.
///
/// `ExistingCLISetupView` owns an instance; `ContentView` routes to it via
/// the pure `shouldOffer` predicate.
@MainActor
@Observable
final class ExistingCLISetupFlow {

    enum ProfileStatus: Equatable {
        case pending
        case initializing
        case collecting
        case done
        case failed(String)
    }

    /// UserDefaults key set when the user completes or skips the setup, so the
    /// screen never re-appears. Everything it does remains reachable later
    /// (Overview Collect now, Automation tab), so skipping loses nothing.
    static let dismissedKey = "existingCLISetupDismissed"

    /// jamf-cli profiles discovered at launch, in discovery order.
    let profileNames: [String]

    /// Profiles the user wants set up. Defaults to all — the common case is
    /// one tenant, and excluding is the exception.
    var selected: Set<String>

    /// Whether completing the setup also turns on managed automation.
    var enableAutomation = true
    var scanWeekday: Int
    var reportsCadence: AutomationPolicy.ReportsCadence
    var runTime: String

    private(set) var statuses: [String: ProfileStatus] = [:]
    private(set) var isRunning = false
    private(set) var didComplete = false

    init(profileNames: [String]) {
        self.profileNames = profileNames
        self.selected = Set(profileNames)
        let defaults = AutomationPolicy()
        self.scanWeekday = defaults.scanWeekday
        self.reportsCadence = defaults.reportsCadence
        self.runTime = defaults.runTime
        for name in profileNames { statuses[name] = .pending }
    }

    // MARK: - Trigger

    /// True when the secondary setup should replace the main shell: real
    /// (non-demo) launch, jamf-cli profiles exist, none of them has an
    /// initialized workspace, and the user hasn't completed or skipped it.
    nonisolated static func shouldOffer(
        profileCount: Int,
        initializedProfileCount: Int,
        demoMode: Bool,
        dismissed: Bool
    ) -> Bool {
        !demoMode && !dismissed && profileCount > 0 && initializedProfileCount == 0
    }

    // MARK: - Automation policy

    /// The policy completing the setup writes. Starts from the currently
    /// stored policy (all defaults on a fresh install) so a future field is
    /// never clobbered, then applies the user's choices. `isManaged` flips on
    /// only when the user kept automation enabled.
    func configuredPolicy(basedOn base: AutomationPolicy = .current()) -> AutomationPolicy {
        var policy = base
        guard enableAutomation else { return policy }
        policy.isManaged = true
        policy.scanWeekday = scanWeekday
        policy.reportsCadence = reportsCadence
        policy.reportsWeekday = scanWeekday
        policy.runTime = runTime
        return policy
    }

    // MARK: - Run

    var selectionSummary: (succeeded: Int, failed: Int) {
        var succeeded = 0, failed = 0
        for name in profileNames where selected.contains(name) {
            switch statuses[name] {
            case .done: succeeded += 1
            case .failed: failed += 1
            default: break
            }
        }
        return (succeeded, failed)
    }

    /// Initialize a workspace and run the first collection for every selected
    /// profile, sequentially (parallel collects would stampede an on-prem Jamf
    /// Pro). One profile's failure never blocks the others; failures carry an
    /// actionable message into the status row.
    ///
    /// `initialize` / `collect` default to the real `CLIBridge` calls; tests
    /// inject spies.
    func run(
        initialize: @escaping (String) async throws -> Int32 = { profile in
            try await CLIBridge().initializeWorkspace(profile: profile, onLine: CLIBridge.noOpOnLine)
        },
        collect: @escaping (String) async throws -> Int32 = { profile in
            try await CLIBridge().collect(profile: profile, force: true, onLine: CLIBridge.noOpOnLine)
        }
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        for name in profileNames where selected.contains(name) {
            statuses[name] = .initializing
            do {
                let initExit = try await initialize(name)
                guard initExit == 0 else {
                    statuses[name] = .failed("workspace init exited \(initExit)")
                    continue
                }
                statuses[name] = .collecting
                let collectExit = try await collect(name)
                statuses[name] = collectExit == 0
                    ? .done
                    : .failed(Self.collectFailureReason(exit: collectExit))
            } catch {
                statuses[name] = .failed(error.localizedDescription)
            }
        }
        didComplete = true
    }

    /// Only exit 3 means dead credentials; exit 1 is usually partial per-kind
    /// failures, and blaming auth for it sends the user to the wrong page.
    nonisolated static func collectFailureReason(exit: Int32) -> String {
        exit == CLIBridge.exitCodeUnauthorized
            ? "jamf-cli credentials expired — re-authenticate this profile"
            : "collect exited \(exit) — see Run History for the failing commands"
    }
}
