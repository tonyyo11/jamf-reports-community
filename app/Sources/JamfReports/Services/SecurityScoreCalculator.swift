import Foundation

/// Computes a fleet-wide weighted security score from per-metric compliant
/// counts. Mirrors `jamf_reports_cli_v3.5.py:FleetHealthDashboard
/// ._calculate_metrics()`.
///
/// Usage:
/// ```
/// let input = SecurityScoreCalculator.Input(
///     totalDevices: 655,
///     compliantCounts: [.fileVault: 647, .sip: 655, ...]
/// )
/// let score = SecurityScoreCalculator.score(input: input, weights: .defaultWeights)
/// ```
///
/// Metrics absent from `compliantCounts` are skipped and their weights
/// dropped from the denominator, so a tenant without CrowdStrike gets a
/// score comparable to one that has it.
struct SecurityScoreCalculator: Sendable {
    struct Input: Sendable, Equatable {
        let totalDevices: Int
        /// Map of metric → number of compliant devices. Missing keys are
        /// treated as "no data" (skipped, not zero).
        let compliantCounts: [SecurityScore.Metric: Int]

        init(totalDevices: Int, compliantCounts: [SecurityScore.Metric: Int]) {
            self.totalDevices = totalDevices
            self.compliantCounts = compliantCounts
        }
    }

    /// Returns a `SecurityScore` for the given input. Returns a `.f`-graded
    /// score with `value = 0` and empty `available` when `totalDevices <= 0`
    /// or no metrics are present.
    static func score(
        input: Input,
        weights: SecurityScoreWeights = .defaultWeights
    ) -> SecurityScore {
        guard input.totalDevices > 0, !input.compliantCounts.isEmpty else {
            return SecurityScore(
                value: 0,
                grade: .f,
                available: [],
                missing: SecurityScore.Metric.allCases,
                appliedWeights: [:]
            )
        }

        var weightedSum: Double = 0
        var totalWeight: Double = 0
        var available: [SecurityScore.Metric] = []
        var missing: [SecurityScore.Metric] = []
        var applied: [SecurityScore.Metric: Double] = [:]

        for metric in SecurityScore.Metric.allCases {
            guard let compliant = input.compliantCounts[metric] else {
                missing.append(metric)
                continue
            }
            let weight = weights.weight(for: metric)
            guard weight > 0 else {
                // Zero weight means the operator explicitly disabled this
                // metric — neither score nor surface it as "missing data".
                continue
            }
            let pct = (Double(compliant) / Double(input.totalDevices)) * 100
            let clamped = min(max(pct, 0), 100)
            weightedSum += clamped * weight
            totalWeight += weight
            available.append(metric)
            applied[metric] = weight
        }

        let value = totalWeight > 0 ? (weightedSum / totalWeight) : 0
        let rounded = (value * 10).rounded() / 10
        return SecurityScore(
            value: rounded,
            grade: SecurityScore.Grade.from(value: rounded),
            available: available,
            missing: missing,
            appliedWeights: applied
        )
    }

    /// Convenience: derive `Input.compliantCounts` from a `DailySummary` by
    /// reversing each percentage into a count (`pct/100 * totalDevices`).
    /// Used when seeding charts/historical screens from existing summaries.
    static func input(from summary: DailySummary) -> Input {
        let total = summary.totalDevices
        var counts: [SecurityScore.Metric: Int] = [:]
        if let pct = summary.fileVaultPct { counts[.fileVault] = countFor(pct: pct, total: total) }
        if let pct = summary.sipPct { counts[.sip] = countFor(pct: pct, total: total) }
        if let pct = summary.firewallPct { counts[.firewall] = countFor(pct: pct, total: total) }
        if let pct = summary.crowdstrikePct { counts[.edrAgent] = countFor(pct: pct, total: total) }
        if let pct = summary.mscpScorePct { counts[.mscp] = countFor(pct: pct, total: total) }
        if let pct = summary.xprotectPct { counts[.xprotect] = countFor(pct: pct, total: total) }
        if let pct = summary.cvePct { counts[.cve] = countFor(pct: pct, total: total) }
        if let pct = summary.secureBootPct { counts[.secureBoot] = countFor(pct: pct, total: total) }
        return Input(totalDevices: total, compliantCounts: counts)
    }

    private static func countFor(pct: Double, total: Int) -> Int {
        guard total > 0 else { return 0 }
        let raw = (pct / 100.0) * Double(total)
        return Int(raw.rounded())
    }
}
