import Foundation

/// How often a report should be fetched.
///
/// - `.seconds(N)`: fetch when the last successful run is at least
///   N seconds old. Cadence math is inclusive: a report fetched
///   exactly N seconds ago is due.
/// - `.never`: never fetch. Unknown/unmapped report kinds resolve here.
///
/// `.never` is the type-safe alternative to overloading nil.
enum Cadence: Sendable, Hashable {
    case seconds(Int)
    case never

    /// Short human-readable label used in run-log "[skip] not due" lines.
    var label: String {
        switch self {
        case .seconds(let n): return "\(n)s"
        case .never:          return "never"
        }
    }
}

/// Pure scheduling decisions.
///
/// `isDue(lastRun:cadence:now:)` is the core gate that
/// `ReportEngine.collect` consults per report before launching a
/// jamf-cli subprocess. It has no I/O — callers read the state
/// file via `StateFileStore` and pass the timestamp in.
///
/// `cadence(forReport:)` maps a report kind to its fixed cloud cadence
/// via `CollectionTier`. Unknown kinds return `.never`.
enum CadenceResolver {

    /// Decide whether `report` should be fetched at `now` given its
    /// last successful fetch and target cadence.
    ///
    /// - `lastRun: nil` (never fetched) is due unless cadence is `.never`.
    /// - `lastRun` ≥ cadence ago is due.
    /// - `lastRun` < cadence ago is not due.
    /// - `cadence: .never` is never due regardless of `lastRun`.
    ///
    /// `now` defaults to `Date()` for production callers; tests inject
    /// a fixed clock so the suite is deterministic.
    static func isDue(
        lastRun: Date?,
        cadence: Cadence,
        now: Date = Date()
    ) -> Bool {
        switch cadence {
        case .never:
            return false
        case .seconds(let interval):
            guard let lastRun else { return true }
            let elapsed = now.timeIntervalSince(lastRun)
            return elapsed >= TimeInterval(interval)
        }
    }

    /// Resolve the fixed cloud cadence for `report`.
    ///
    /// Unknown/unmapped kinds return `.never` — refuse to fetch something
    /// the tier map has no policy for.
    static func cadence(forReport report: String) -> Cadence {
        guard let tier = CollectionTier.tier(forReport: report) else { return .never }
        return .seconds(tier.intervalSeconds)
    }
}
