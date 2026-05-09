import Foundation

// MARK: - OperationalTemplate

/// Operational / NOC daily template — compact drill-down for ops engineers.
///
/// Audience: Mac operations engineers and NOC staff running daily triage.
/// Focuses on actionable failure lists, queued patches, stale/unhealthy devices,
/// and check-in anomalies. Compact PDF minimizes screen real estate.
struct OperationalTemplate: ReportTemplate {

    let identifier = "operational"
    let displayName = "Operational"
    let description = "Daily NOC view for ops engineers: failures, patch queue, " +
        "stale devices, check-in anomalies, and group hygiene."
    let audience = "Mac ops engineers, NOC staff"

    var includedSheets: [SheetID] {
        [
            .fleetOverview,
            .checkinHealth,
            .activeDevices,
            .patchCompliance,
            .patchFailures,
            .updateStatus,
            .updateFailures,
            .deviceCompliance,
            .policyHealth,
            .groupHygiene,
            .profileStatus,
            .appStatus,
        ]
    }

    var htmlSections: [SectionID] {
        [
            .kpiTiles,
            .recentFailures,
            .interventionList,
            .patchQueue,
            .patchBar,
            .policyTable,
            .profileTable,
            .agentHealth,
        ]
    }

    let pdfPagination: PaginationStrategy = .compact
    let recommendedSchedule: TemplateDataTier = .core
}
