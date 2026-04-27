import Foundation
import Observation

@Observable final class TrendStore {
    private var allSummaries: [DailySummary] = []
    private(set) var filteredSummaries: [DailySummary] = []
    private(set) var currentProfile: String?
    private(set) var currentRange: TrendRange = .w26

    func load(profile: String, range: TrendRange) {
        if profile != currentProfile {
            allSummaries = readSummaries(profile: profile)
            currentProfile = profile
        }

        currentRange = range
        filterSummaries(range: range)
    }

    /// Force a re-scan of the on-disk summaries directory for the active
    /// profile. The cheap `load(profile:range:)` short-circuits when the
    /// profile is unchanged; callers that just generated a new summary use
    /// `reload()` to invalidate that cache.
    func reload() {
        guard let profile = currentProfile else { return }
        allSummaries = readSummaries(profile: profile)
        filterSummaries(range: currentRange)
    }

    /// Read summaries from the configured `charts.historical_csv_dir/summaries`
    /// (or the workspace fallback if config is unavailable).
    private func readSummaries(profile: String) -> [DailySummary] {
        // Validate at the boundary — string-interpolating an unvalidated profile
        // into a path component is a traversal vector.
        guard let summariesDir = WorkspacePaths.summariesDir(for: profile)
            ?? fallbackSummariesDir(for: profile) else {
            return []
        }
        return SummaryJSONParser.parseDirectory(summariesDir)
    }

    private func fallbackSummariesDir(for profile: String) -> URL? {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return nil }
        return workspace.appendingPathComponent("snapshots/summaries", isDirectory: true)
    }

    private func filterSummaries(range: TrendRange) {
        // newest first to take N
        let sorted = allSummaries.sorted { $0.date > $1.date }
        let count: Int? = {
            switch range {
            case .w4: return 4
            case .w12: return 12
            case .w26: return 26
            case .w52: return 52
            case .all: return nil
            }
        }()

        if let count = count {
            // Take newest N, then back to ascending for display
            filteredSummaries = Array(sorted.prefix(count)).reversed()
        } else {
            filteredSummaries = allSummaries.sorted { $0.date < $1.date }
        }
    }

    func values(metric: TrendSeries.Metric) -> [Double] {
        filteredSummaries.map { summary in
            switch metric {
            case .activeDevices: return Double(summary.totalDevices)
            case .compliance:  return summary.compliancePct
            case .fileVault:   return summary.fileVaultPct
            case .osCurrent:   return summary.osCurrentPct
            case .crowdstrike: return summary.crowdstrikePct
            case .stale:       return Double(summary.staleCount)
            case .patch:       return summary.patchPct
            }
        }
    }

    func dates() -> [String] {
        filteredSummaries.map { $0.date }
    }

    var isEmpty: Bool {
        allSummaries.isEmpty
    }
}
