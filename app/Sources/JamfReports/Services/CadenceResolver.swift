import Foundation

/// PR-22: how often a report should be fetched.
///
/// - `.seconds(N)`: fetch when the last successful run is at least
///   N seconds old. Cadence math is inclusive: a report fetched
///   exactly N seconds ago is due.
/// - `.never`: never fetch. The "kill switch" for reports that
///   crash the server (e.g., `update-status` on memory-fragile
///   on-prem Jamf Pro) or that the operator never wants. Wins over
///   "never fetched" — a `.never` report is never due even if it
///   has no state file.
///
/// `.never` is the type-safe alternative to overloading nil. Callers
/// can distinguish "report has no per_report config (use preset
/// default)" from "operator explicitly disabled this report" by
/// keeping nil and `.never` semantically separate.
enum Cadence: Sendable, Hashable {
    case seconds(Int)
    case never
}

/// PR-22 T-4 + T-7: pure scheduling decisions.
///
/// `isDue(lastRun:cadence:now:)` is the core gate that
/// `ReportEngine.collect` consults per report before launching a
/// jamf-cli subprocess. It has no I/O — callers (T-8) read the state
/// file via `StateFileStore` and pass the timestamp in.
///
/// `resolve(report:config:)` (T-7) sits on top of this and picks the
/// cadence from a `CollectCadenceConfig` + preset; both functions
/// live here so the resolver + decision API form a tight, testable
/// pair.
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
}
