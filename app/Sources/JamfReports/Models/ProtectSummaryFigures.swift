import Foundation

/// The Jamf Protect figures a daily summary records (environment model P9-R2). A group is nil
/// when this run did not land its snapshot, so the summary keeps the earlier value.
struct ProtectSummaryFigures: Equatable, Sendable {
    struct Computers: Equatable, Sendable {
        var count: Int
        /// nil when there is nothing to match against; see `ProtectProCorrelation.matchedShare`.
        var matched: MobileSummary.Share?
    }

    struct Alerts: Equatable, Sendable {
        var open: Int
        /// nil when no open alert carries a severity.
        var counts: [String: Int]?
    }

    var computers: Computers?
    var alerts: Alerts?
}

extension MobileSummary.Share {
    /// `pct` to one decimal, the one rounding every Protect match reader shows.
    var pctOneDecimal: Double? { pct.map { ($0 * 10).rounded() / 10 } }
}
