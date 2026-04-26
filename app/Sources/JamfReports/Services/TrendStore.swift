import Foundation
import Observation

@Observable final class TrendStore {
    private var allSummaries: [DailySummary] = []
    private(set) var filteredSummaries: [DailySummary] = []
    private(set) var currentProfile: String?
    private(set) var currentRange: TrendRange = .w26

    func load(profile: String, range: TrendRange) {
        if profile != currentProfile {
            // Validate at the boundary — string-interpolating an unvalidated profile
            // into a path component is a traversal vector.
            if let workspace = ProfileService.workspaceURL(for: profile) {
                let summariesDir = workspace
                    .appendingPathComponent("snapshots/summaries", isDirectory: true)
                allSummaries = SummaryJSONParser.parseDirectory(summariesDir)
            } else {
                allSummaries = []
            }
            currentProfile = profile
        }

        currentRange = range
        filterSummaries(range: range)
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
