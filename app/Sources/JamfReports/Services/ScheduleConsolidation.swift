import Foundation

/// Detects imported hand-built LaunchAgent plists that are still loaded by
/// launchd after the schedule has moved into the `ScheduleStore` — either
/// runs twice per fire (launchd's own trigger AND the tick), until the
/// operator retires the old plist.
///
/// Pure and side-effect-free: the UI passes what `LaunchAgentService`
/// discovers on disk plus the store's own labels; removal is a separate,
/// explicitly-confirmed step. A reserved managed label is NEVER a candidate —
/// those are owned by `ManagedAutomation` and the first launch already
/// removed them.
enum ScheduleConsolidation {

    /// An imported plist that is still loaded by launchd.
    struct Candidate: Identifiable, Sendable, Equatable {
        let label: String
        let displayName: String
        let mode: Schedule.RunMode
        /// Human label of what now runs this schedule.
        let coveredBy: String
        var id: String { label }
    }

    /// Imported hand-built plists that are still loaded by launchd. Until the
    /// operator retires them, each fires twice: once from launchd, once from
    /// the tick. Managed plists never appear here — the first launch removed them.
    static func stillLoaded(installed: [Schedule], storeLabels: Set<String>) -> [Candidate] {
        installed.compactMap { s in
            guard let label = s.launchAgentLabel, storeLabels.contains(label),
                  !ManagedAutomation.owns(label) else { return nil }
            return Candidate(label: label, displayName: s.name, mode: s.mode,
                             coveredBy: "the JamfReports background item")
        }
    }
}
