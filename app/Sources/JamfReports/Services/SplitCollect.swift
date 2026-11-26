import Foundation

/// The split collect (spec 2026-11-25): a scheduled run that stopped at its budget is continued
/// by the tick through the day instead of retried as a failure.
enum SplitCollect {
    /// The stop the tick continues, or nil. A full refresh of the same workspace collects what
    /// was left; a Protect-only collect has no cadence skip, so a continuation would read as a
    /// dead run; a mode that does not collect has nothing to continue.
    static func continuableStop(
        _ stop: ReportEngine.RunStop?, mode: Schedule.RunMode, protectOnly: Bool
    ) -> SplitStop? {
        guard let stop, mode.runsAtLoad, !protectOnly else { return nil }
        let split = SplitStop(stop)
        return split == .manualRefresh ? nil : split
    }
}
