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
            .atAGlance,
            .needsAttention,
            .jamfDashboard,
            .recentFailures,
            .interventionList,
            .patchQueue,
            .patchBar,
            .policyTable,
            .profileTable,
            .appTable,
            .agentHealth,
            .auditAppendix,
        ]
    }

    /// The action lists start open; the rest of the report starts collapsed.
    var htmlOpenSections: [SectionID] {
        [.recentFailures, .interventionList, .patchQueue]
    }

    let pdfPagination: PaginationStrategy = .compact
    let recommendedSchedule: TemplateDataTier = .core
}
