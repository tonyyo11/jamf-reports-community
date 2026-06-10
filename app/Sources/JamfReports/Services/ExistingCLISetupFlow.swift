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

    /// Live tally of the collect stream, parsed from the engine's per-kind
    /// log lines so the user sees motion during a multi-minute first collect
    /// instead of an opaque spinner.
    struct CollectProgress: Equatable {
        var currentKind: String?
        var collected = 0
        var failed = 0
        var skipped = 0

        var summary: String {
            var parts = ["\(collected) collected"]
            if failed > 0 { parts.append("\(failed) failed") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            return parts.joined(separator: ", ")
        }
    }

    /// How the setup screen was dismissed. The distinction matters for
    /// re-offering: a COMPLETED setup created workspaces, so if the user later
    /// wipes ~/Jamf-Reports the on-disk state is first-launch again and the
    /// screen re-offers (state derives from real artifacts, not progress
    /// flags). An explicit SKIP is a choice — never nag again; everything the
    /// screen does stays reachable (Overview Collect now, Automation tab).
    enum SetupOutcome: String {
        case completed
        case skipped
    }

    /// UserDefaults key holding the `SetupOutcome` raw value ("" = never seen).
    nonisolated static let outcomeKey = "existingCLISetupOutcome"

    /// Pre-2.2.1 builds stored a Bool under this key; treated as `.completed`
    /// when the new key is unset so field-test installs keep their semantics.
    nonisolated static let legacyDismissedKey = "existingCLISetupDismissed"

    /// Resolve the stored outcome, honoring the legacy Bool.
    nonisolated static func storedOutcome(
        defaults: UserDefaults = .standard
    ) -> SetupOutcome? {
        if let raw = defaults.string(forKey: outcomeKey),
           let outcome = SetupOutcome(rawValue: raw) {
            return outcome
        }
        return defaults.bool(forKey: legacyDismissedKey) ? .completed : nil
    }

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
    /// Progress of the profile currently collecting (sequential, so one at a time).
    private(set) var progress = CollectProgress()
    /// Final per-profile tallies, rendered next to the finished status rows.
    private(set) var kindSummaries: [String: CollectProgress] = [:]

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
    /// (non-demo) launch, jamf-cli profiles exist, and none of them has an
    /// initialized workspace. A prior `.completed` outcome does NOT block —
    /// reaching zero initialized workspaces again means the user wiped
    /// ~/Jamf-Reports, and the on-disk state IS first launch. Only an
    /// explicit `.skipped` suppresses the screen permanently.
    nonisolated static func shouldOffer(
        profileCount: Int,
        initializedProfileCount: Int,
        demoMode: Bool,
        outcome: SetupOutcome?
    ) -> Bool {
        !demoMode && outcome != .skipped && profileCount > 0 && initializedProfileCount == 0
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
    /// inject spies. The collect closure receives an onLine sink — the engine's
    /// per-kind log stream — which feeds `progress` for the live UI.
    func run(
        initialize: @escaping (String) async throws -> Int32 = { profile in
            try await CLIBridge().initializeWorkspace(profile: profile, onLine: CLIBridge.noOpOnLine)
        },
        collect: @escaping (String, @escaping @Sendable (CLIBridge.LogLine) -> Void) async throws -> Int32 = {
            profile, onLine in
            try await CLIBridge().collect(profile: profile, force: true, onLine: onLine)
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
                progress = CollectProgress()
                let collectExit = try await collect(name) { [weak self] line in
                    Task { @MainActor in self?.ingest(line.text) }
                }
                // Let queued ingest hops land before snapshotting the tally —
                // the last few [ok] lines arrive as unstructured MainActor
                // tasks and would otherwise be cut off the final summary.
                await Task.yield()
                kindSummaries[name] = progress
                statuses[name] = collectExit == 0
                    ? .done
                    : .failed(Self.collectFailureReason(exit: collectExit))
            } catch {
                statuses[name] = .failed(error.localizedDescription)
            }
        }
        didComplete = true
    }

    /// Parse one engine log line into the live tally. Line shapes (from
    /// `ReportEngine.collect`): `[info] collecting <kind> for <profile>`,
    /// `[ok] <kind>: N bytes`, `[warn] <kind>: …`, `[skip] <kind>: …`.
    /// Anything else (subprocess output, SOFA notes) is ignored.
    func ingest(_ text: String) {
        if text.hasPrefix("[info] collecting ") {
            let rest = text.dropFirst("[info] collecting ".count)
            progress.currentKind = rest.split(separator: " ").first.map(String.init)
        } else if text.hasPrefix("[ok] ") {
            progress.collected += 1
            progress.currentKind = nil
        } else if text.hasPrefix("[warn] ") {
            progress.failed += 1
            progress.currentKind = nil
        } else if text.hasPrefix("[skip] ") {
            progress.skipped += 1
        }
    }

    /// Only exit 3 means dead credentials; exit 1 is usually partial per-kind
    /// failures, and blaming auth for it sends the user to the wrong page.
    nonisolated static func collectFailureReason(exit: Int32) -> String {
        exit == CLIBridge.exitCodeUnauthorized
            ? "jamf-cli credentials expired — re-authenticate this profile"
            : "collect exited \(exit) — see Run History for the failing commands"
    }
}
