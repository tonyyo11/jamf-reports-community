import Foundation

// MARK: - FullInstanceTemplate

/// Full instance report — the most complete view of a Jamf Pro tenant.
///
/// Audience: Jamf admins, MacAdmins, and anyone doing a full-detail review.
/// Includes every available sheet and every HTML section in a logical reading order.
struct FullInstanceTemplate: ReportTemplate {

    let identifier = "full-instance"
    let displayName = "Full Instance Report"
    let description = "Complete instance report with every available section — " +
        "all sheets, all HTML sections, full detail."
    let audience = "Jamf admins, MacAdmins, full-detail review"

    var includedSheets: [SheetID] {
        [
            // Framing / exec-priority
            .executiveSummary,
            .cover,
            .compliancePosture,
            .fleetOverview,
            .securityPosture,
            .patchCompliance,
            .deviceCompliance,
            .auditSummary,
            // Inventory & hardware
            .inventorySummary,
            .hardwareModels,
            .mobileFleetSummary,
            .mobileInventory,
            // Configuration health
            .policyHealth,
            .profileStatus,
            .mobileConfigProfiles,
            .appStatus,
            .softwareInstalls,
            .packageLifecycle,
            .eaCoverage,
            .eaDefinitions,
            .environmentStats,
            // Device health
            .checkinHealth,
            .activeDevices,
            .groupHygiene,
            // Update & patch details
            .patchFailures,
            .updateStatus,
            .updateFailures,
            .smartGroups,
            .patchSummaryDashboard,
            // Device security & supervision detail
            .deviceSecurityState,
            .mobileSupervisionStatus,
            // OS currency
            .osCurrency,
            // Platform / DDM
            .complianceDevices,
            .complianceRules,
            .ddmStatus,
            .blueprintStatus,
            // Protect
            .protectOverview,
            .protectAlerts,
            .protectComputers,
            .protectInsights,
            .protectPlans,
            .protectThreatOverview,
            // mSCP / STIG compliance
            .mscpCompliance,
            .complianceTrend,
        ]
    }

    var htmlSections: [SectionID] {
        [
            .execSummary,
            .kpiTiles,
            .fleetSummary,
            .securityTiles,
            .osAdoptionChart,
            .patchBar,
            .complianceBands,
            .recentFailures,
            .interventionList,
            .patchQueue,
            .policyTable,
            .profileTable,
            .assetMap,
            .warrantyTable,
            .purchaseCohorts,
            .buildingBreakdown,
            .departmentBreakdown,
            .agentHealth,
            .timeline,
            .cleanupAnalysis,
            .auditEvidence,
            .exceptionList,
            .protectAlerts,
            .insightsDrift,
            .orgInfo,
            .osCurrency,
        ]
    }

    let pdfPagination: PaginationStrategy = .standard
    let recommendedSchedule: TemplateDataTier = .full
}
