import Foundation

extension ReportEngine {
    /// The deployment-health groups a Jamf Pro daily summary records, one per kind that landed
    /// this run and whose newest snapshot reads. A landed empty list, or one whose rows are all
    /// under the floor, is a measured zero; an unreadable or not-set-up source writes no group,
    /// so the earlier value stands. No cache-age limit: `landed` already means this run.
    static func deploymentSummaryFigures(
        dataDir: URL, landed: Set<String>, levels: DeploymentHealth.Levels, now: Date = Date()
    ) -> [DeploymentHealth.Source: DeploymentSummaryGroup]? {
        let sources = DeploymentHealth.Source.allCases.filter { landed.contains($0.kind) }
        guard !sources.isEmpty else { return nil }
        let states = DeploymentHealth.load(dataDir: dataDir, now: now)
        var groups: [DeploymentHealth.Source: DeploymentSummaryGroup] = [:]
        for source in sources {
            guard case .rows(let rows, _, _)? = states[source] else { continue }
            groups[source] = DeploymentSummaryGroup(
                figures: DeploymentHealth.figures(rows, levels: levels), levels: levels)
        }
        return groups.isEmpty ? nil : groups
    }
}
