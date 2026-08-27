import Foundation

/// One snapshot kind that is not keeping up with its tier cadence.
///
/// The twin of `AutomationHealthIssue`: that one asks "did the schedule fire?",
/// this one asks "did the data actually land?". A run can fire, exit 0, and
/// still leave a kind months stale — `ReportEngine.collect` warns and falls
/// back to cache on a per-kind failure, which never reaches the run's exit
/// code. Without this evaluator that degradation is only visible on whichever
/// screen happens to read that kind.
struct DataFreshnessIssue: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable {
        /// The kind's last success is far past its cadence (or it never landed).
        case stale
        /// The kind failed on consecutive collect attempts.
        case failing
    }

    var id: String { "\(kind.rawValue):\(snapshotKind)" }
    let snapshotKind: String
    let tier: CollectionTier
    let kind: Kind
    /// Last successful fetch, or nil when the kind has never landed.
    let lastSuccess: Date?
    /// Consecutive failed attempts recorded by `StateFileStore`.
    let consecutiveFailures: Int
    let lastFailure: Date?

    /// Plain-language reason for the banner and the Automation health card.
    var summary: String {
        switch kind {
        case .failing:
            let attempts = consecutiveFailures == 1 ? "attempt" : "attempts"
            return "\(snapshotKind) has failed \(consecutiveFailures) collect \(attempts) in a row"
        case .stale:
            guard let lastSuccess else {
                return "\(snapshotKind) has never been collected successfully"
            }
            let days = max(0, Int(Date().timeIntervalSince(lastSuccess) / 86_400))
            return "\(snapshotKind) last landed \(days)d ago (expected every \(tier.cadenceLabel))"
        }
    }
}

/// Per-kind collection state read off disk, fed to the pure evaluator.
struct KindCollectionState: Sendable, Equatable {
    let kind: String
    let lastSuccess: Date?
    let consecutiveFailures: Int
    let lastFailure: Date?
}

/// Pure evaluator for per-kind data freshness. No I/O — the caller reads
/// `StateFileStore` and passes the states in, same contract as
/// `AutomationHealth.evaluate`.
enum DataFreshnessHealth {

    /// How many cadence periods a kind may fall behind before it is called
    /// stale. One missed cycle is normal (a slow night, a cadence boundary);
    /// three consecutive misses is a pattern. Resolves to 36h / 6d / 21d for
    /// the refresh / inventory / scan tiers.
    static let staleCadenceMultiple: Double = 3

    /// Consecutive failures before a kind is called failing. One blip is a
    /// transient server hiccup — the in-run retry in `ReportEngine.collect`
    /// already absorbs those — so alerting on the first is noise.
    static let failingThreshold = 2

    /// Evaluate one pass. `now` is injected for deterministic tests.
    ///
    /// A kind is reported at most once: `.failing` wins over `.stale`, because
    /// a repeatedly-failing kind is stale *for a known reason* and the operator
    /// should see the cause, not the symptom.
    ///
    /// `hasCollectedBefore` guards the never-collected case. On a fresh
    /// workspace every kind is nil and the honest answer is "nothing has run
    /// yet", not thirty alarms; once any kind has landed, a known kind that
    /// still has no success is a real gap (prod's `update-device-failures`).
    static func evaluate(
        states: [KindCollectionState],
        hasCollectedBefore: Bool,
        now: Date = Date()
    ) -> [DataFreshnessIssue] {
        states.compactMap { state in
            guard let tier = CollectionTier.tier(forReport: state.kind) else { return nil }

            if state.consecutiveFailures >= failingThreshold {
                return DataFreshnessIssue(
                    snapshotKind: state.kind, tier: tier, kind: .failing,
                    lastSuccess: state.lastSuccess,
                    consecutiveFailures: state.consecutiveFailures,
                    lastFailure: state.lastFailure
                )
            }

            guard let lastSuccess = state.lastSuccess else {
                guard hasCollectedBefore else { return nil }
                return DataFreshnessIssue(
                    snapshotKind: state.kind, tier: tier, kind: .stale,
                    lastSuccess: nil,
                    consecutiveFailures: state.consecutiveFailures,
                    lastFailure: state.lastFailure
                )
            }

            let budget = Double(tier.intervalSeconds) * staleCadenceMultiple
            guard now.timeIntervalSince(lastSuccess) >= budget else { return nil }
            return DataFreshnessIssue(
                snapshotKind: state.kind, tier: tier, kind: .stale,
                lastSuccess: lastSuccess,
                consecutiveFailures: state.consecutiveFailures,
                lastFailure: state.lastFailure
            )
        }
        .sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .failing }
            return lhs.snapshotKind < rhs.snapshotKind
        }
    }

    /// Tiers that need a re-collect to clear `issues`. The remediation pass
    /// collects by tier because that is the only granularity
    /// `ReportEngine.collect` accepts.
    static func tiersToRemediate(_ issues: [DataFreshnessIssue]) -> Set<CollectionTier> {
        Set(issues.map(\.tier))
    }
}

extension CollectionTier {
    /// Human cadence for issue copy ("every 12h"), derived from the one
    /// source of truth so a tier retune can never desync the message.
    var cadenceLabel: String {
        let hours = intervalSeconds / 3_600
        if hours >= 24 {
            let days = hours / 24
            return days == 1 ? "1 day" : "\(days) days"
        }
        return "\(hours)h"
    }
}
