import Foundation
@testable import JamfReports

/// Helpers for tests that score a fleet through the same functions the app uses.
enum SecurityScoreTestSupport {
    /// The score of the factors a policy counts by default, measured from the security report's
    /// counts alone: no other snapshot is loaded, so only FileVault, SIP, Firewall and
    /// Gatekeeper (less any set to `ignore`) have data.
    static func score(
        _ fleet: SecurityFleetCounts, policy: SecurityControlPolicy = .default
    ) -> SecurityScore {
        let factors = policy.resolvedScoreFactors(agents: [], baselines: [])
        return SecurityScoreCalculator.score(
            factors: factors,
            measures: SecurityScoreInputs.measures(
                for: factors, fleet: fleet, sources: .none, config: nil))
    }
}

extension SecurityPostureService.Snapshot {
    /// The snapshot with its score taken from the security report alone, under its own policy:
    /// the four controls have data and every other factor has none.
    func scoredFromReportAlone() -> SecurityPostureService.Snapshot {
        var scored = self
        let factors = policy.resolvedScoreFactors(agents: [], baselines: [])
        scored.scoreFactors = factors
        scored.scoreMeasures = SecurityScoreInputs.measures(
            for: factors, fleet: fleetCounts, sources: .none, config: nil)
        return scored
    }

    /// A snapshot read through the `load(from:policy:hardware:)` seam carries no factors; this
    /// adds what `load(profile:)` adds, from the workspace's config and data directory.
    func scored(config: ReportConfig, dataDir: URL) -> SecurityPostureService.Snapshot {
        var scored = self
        let factors = config.resolvedScoreFactors
        scored.scoreFactors = factors
        scored.scoreMeasures = SecurityScoreInputs.measures(
            for: factors, fleet: fleetCounts,
            sources: SecurityScoreInputs.load(dataDir: dataDir, factors: factors),
            config: config)
        scored.staleDays = config.thresholds?.resolvedStaleDays ?? 30
        return scored
    }
}
