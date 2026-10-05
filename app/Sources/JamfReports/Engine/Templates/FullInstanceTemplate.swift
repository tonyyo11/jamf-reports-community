import Foundation

// MARK: - FullInstanceTemplate

/// Full instance report — the most complete view of a Jamf Pro tenant.
///
/// Audience: Jamf admins, MacAdmins, and anyone doing a full-detail review.
/// Includes every available sheet and every HTML section; the report starts with every
/// detail group collapsed.
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
            .patchVelocity,
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
            .ddmDeviceStatus,
            .mdmCommandHealth,
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
            .aiNarrative,
            .atAGlance,
            .needsAttention,
            .jamfDashboard,
            // Security and compliance
            .securityTiles,
            .complianceBands,
            .agentHealth,
            .exceptionList,
            .protectAlerts,
            .insightsDrift,
            .auditEvidence,
            // Patching
            .patchBar,
            .patchQueue,
            .osAdoptionChart,
            .osCurrency,
            // Devices, policies, trends, failures
            .interventionList,
            .policyTable,
            .profileTable,
            .appTable,
            .cleanupAnalysis,
            .timeline,
            .recentFailures,
            // Breakdowns
            .purchaseCohorts,
            .buildingBreakdown,
            .departmentBreakdown,
            .orgInfo,
            .auditAppendix,
        ]
    }

    let pdfPagination: PaginationStrategy = .standard
    let recommendedSchedule: TemplateDataTier = .full
}
