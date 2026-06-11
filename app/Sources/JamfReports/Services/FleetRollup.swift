import Foundation

/// Consolidated fleet KPIs across a report group's profiles, with
/// period-over-period deltas (v2.2.0 Phase 4).
///
/// Pure and unit-tested: the emitter loads each profile's current and
/// prior-period `DailySummary` and feeds them here. Percentage KPIs are
/// **device-weighted** across profiles (a 1000-device tenant at 90% outweighs a
/// 10-device tenant at 50%); counts are summed.
struct FleetRollup: Sendable, Equatable {

    enum Unit: Sendable, Equatable { case count, percent }

    struct Metric: Sendable, Equatable {
        let key: String
        let label: String
        let unit: Unit
        /// Current aggregated value; nil when no profile reports the KPI.
        let value: Double?
        /// Prior-period aggregated value; nil when unavailable.
        let previous: Double?

        /// current − previous, when both are present.
        var delta: Double? {
            guard let value, let previous else { return nil }
            return value - previous
        }
    }

    let groupName: String
    let profileCount: Int
    let totalDevices: Int
    let metrics: [Metric]

    /// Aggregate `current` summaries (and `previous` for deltas). The caller
    /// passes one latest summary per profile in the group, and the matching
    /// prior-period summary per profile (yesterday for daily, ~7 days back for
    /// weekly, etc. — the rollup is agnostic to which period "previous" means).
    static func compute(
        groupName: String,
        current: [DailySummary],
        previous: [DailySummary]
    ) -> FleetRollup {
        let metrics: [Metric] = [
            sumMetric("devices", "Devices", current, previous) { Double($0.totalDevices) },
            sumMetric("stale", "Stale Devices", current, previous) { Double($0.staleCount ?? 0) },
            weightedMetric("compliance", "Compliance %", current, previous, \.compliancePct),
            weightedMetric("fileVault", "FileVault %", current, previous, \.fileVaultPct),
            weightedMetric("patch", "Patch %", current, previous, \.patchPct),
            weightedMetric("osCurrent", "OS Current %", current, previous, \.osCurrentPct),
            weightedMetric("securityScore", "Security Score", current, previous, \.securityScore),
        ]
        return FleetRollup(
            groupName: groupName,
            profileCount: current.count,
            totalDevices: current.reduce(0) { $0 + $1.totalDevices },
            metrics: metrics
        )
    }

    // MARK: - Aggregators

    private static func sumMetric(
        _ key: String, _ label: String,
        _ current: [DailySummary], _ previous: [DailySummary],
        _ value: (DailySummary) -> Double
    ) -> Metric {
        Metric(
            key: key, label: label, unit: .count,
            value: current.isEmpty ? nil : current.reduce(0.0) { $0 + value($1) },
            previous: previous.isEmpty ? nil : previous.reduce(0.0) { $0 + value($1) }
        )
    }

    private static func weightedMetric(
        _ key: String, _ label: String,
        _ current: [DailySummary], _ previous: [DailySummary],
        _ keyPath: KeyPath<DailySummary, Double?>
    ) -> Metric {
        Metric(
            key: key, label: label, unit: .percent,
            value: deviceWeighted(current, keyPath),
            previous: deviceWeighted(previous, keyPath)
        )
    }

    /// Device-weighted average of a percent KPI: Σ(pct × devices) / Σ(devices)
    /// over profiles that report it. nil when no profile reports the KPI (or all
    /// reporting profiles have zero devices).
    private static func deviceWeighted(
        _ summaries: [DailySummary], _ keyPath: KeyPath<DailySummary, Double?>
    ) -> Double? {
        var weightedSum = 0.0
        var weight = 0
        for summary in summaries {
            guard let pct = summary[keyPath: keyPath] else { continue }
            weightedSum += pct * Double(summary.totalDevices)
            weight += summary.totalDevices
        }
        return weight > 0 ? weightedSum / Double(weight) : nil
    }
}
