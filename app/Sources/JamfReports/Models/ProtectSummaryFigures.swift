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

    /// One agent finding this run measured: `share` nil when it could not be judged (a
    /// baseline under a day old, or no Mac reporting the fields), never `{0, 0}`.
    struct Measured: Equatable, Sendable {
        var share: MobileSummary.Share?

        init(_ share: MobileSummary.Share?) {
            self.share = share.flatMap { $0.of > 0 ? $0 : nil }
        }
    }

    /// `ProtectAgentHealth`'s findings; a nil member is one this run did not measure, so the
    /// summary keeps the earlier value for it.
    struct Agent: Equatable, Sendable {
        var signaturesBehind: Measured?
        var agentBehind: Measured?
        var disconnected: Measured?
    }

    var computers: Computers?
    var alerts: Alerts?
    var agent: Agent?
}

extension MobileSummary.Share {
    /// `pct` to one decimal, the one rounding every Protect match reader shows.
    var pctOneDecimal: Double? { pct.map { ($0 * 10).rounded() / 10 } }
}
