import Foundation

/// Detects hand-built (non-managed) Jamf Reports LaunchAgents that the active
/// managed automation policy now duplicates, so the operator can retire them
/// after switching to managed automation.
///
/// Pure and side-effect-free: the UI passes the installed schedules
/// (`LaunchAgentService.list()`) and the current policy; removal is a separate,
/// explicitly-confirmed step. A reserved managed label is NEVER a candidate —
/// those are owned by `ManagedAutomation` and must not be offered for removal
/// (the inverse of `ManagedAutomation.defaultRemove`'s `owns`-only guard).
enum ScheduleConsolidation {

    /// A hand-built agent the managed policy now covers.
    struct Candidate: Identifiable, Sendable, Equatable {
        let label: String
        let displayName: String
        let mode: Schedule.RunMode
        let isMulti: Bool
        /// Human label of the managed capability that now covers this agent.
        let coveredBy: String
        var id: String { label }
    }

    /// Hand-built schedules the active managed policy duplicates.
    ///
    /// Empty when the policy is unmanaged (managed installs nothing, so nothing
    /// is redundant). A schedule is a candidate only when ALL hold:
    /// - it is not a reserved managed label (`ManagedAutomation.owns` is false),
    /// - it carries a launch-agent label,
    /// - an *enabled* managed capability covers its run mode, AND
    /// - managed actually covers its profile scope (see exclusions below).
    ///
    /// Exclusions: managed agents run all-profiles MINUS `excludedProfiles`, so
    /// an agent doing work managed deliberately skips is NOT redundant. A
    /// per-profile hand-built agent for an excluded profile is never flagged. A
    /// multi/all-profiles hand-built agent is not flagged while ANY profile is
    /// excluded, because managed leaves those profiles uncovered. The rule
    /// deliberately under-recommends on partial coverage — a removal is
    /// destructive and prod-facing, so it must never recommend killing live
    /// collection the operator intentionally kept.
    static func candidates(
        installed: [Schedule],
        policy: AutomationPolicy
    ) -> [Candidate] {
        guard policy.isManaged else { return [] }
        let hasExclusions = !policy.excludedProfiles.isEmpty
        return installed.compactMap { sched -> Candidate? in
            guard let label = sched.launchAgentLabel,
                  !ManagedAutomation.owns(label),
                  let covered = coveringCapability(for: sched.mode, policy: policy) else {
                return nil
            }
            let isMulti = sched.multiTarget != nil
            if hasExclusions {
                // All-profiles managed coverage is partial while exclusions exist.
                if isMulti { return nil }
                // A per-profile agent for an excluded profile is intentionally
                // outside managed coverage.
                if policy.excludedProfiles.contains(sched.profile) { return nil }
            }
            return Candidate(
                label: label,
                displayName: sched.name,
                mode: sched.mode,
                isMulti: isMulti,
                coveredBy: covered
            )
        }
        .sorted { $0.label < $1.label }
    }

    /// The managed capability that covers `mode`, but only when that capability
    /// is enabled in `policy`. Returns nil when no enabled managed capability
    /// covers the mode — the hand-built agent is then doing work the policy does
    /// NOT, and must not be flagged. Gating only; never mutates the policy.
    static func coveringCapability(
        for mode: Schedule.RunMode,
        policy: AutomationPolicy
    ) -> String? {
        switch mode {
        case .snapshotOnly:
            if policy.freshnessEnabled { return "data freshness" }
            if policy.scanEnabled { return "weekly deep scan" }
            return nil
        case .jamfCLIOnly, .jamfCLIFull, .csvAssisted:
            return policy.reportsCadence != .off ? "report generation" : nil
        case .backup:
            return policy.backupsEnabled ? "configuration backup" : nil
        }
    }
}
