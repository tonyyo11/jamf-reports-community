import Foundation

// MARK: - SecurityPostureTemplate

/// Security posture deep-dive template.
///
/// Audience: Security engineers and CISO staff conducting periodic security reviews.
/// Surfaces Protect alerts, mSCP audit findings, FileVault/Gatekeeper/SIP/Firewall
/// percentages, and CrowdStrike and other security-agent health.
/// Requires the `protect` collection tier.
struct SecurityPostureTemplate: ReportTemplate {

    let identifier = "security-posture"
    let displayName = "Security Posture"
    let description = "Security-engineer deep-dive: Protect alerts, mSCP findings, " +
        "FileVault/SIP/Gatekeeper/Firewall health, and agent coverage."
    let audience = "Security engineers, CISO staff"

    var includedSheets: [SheetID] {
        [
            .cover,
            .securityPosture,
            .compliancePosture,
            .auditSummary,
            .deviceCompliance,
            .complianceDevices,
            .complianceRules,
            .protectOverview,
            .protectAlerts,
            .protectComputers,
            .patchCompliance,
            .patchFailures,
            .eaCoverage,
            .managementHealth,
        ]
    }

    var htmlSections: [SectionID] {
        [
            .atAGlance,
            .needsAttention,
            .jamfDashboard,
            .securityTiles,
            .protectAlerts,
            .protectAgents,
            .agentHealth,
            .auditEvidence,
            .complianceBands,
            .patchBar,
            .exceptionList,
            .mobileFleet,
            .auditAppendix,
        ]
    }

    /// The security and compliance group starts open: it is what this template is for.
    var htmlOpenSections: [SectionID] {
        [.securityTiles, .protectAlerts, .protectAgents, .agentHealth, .auditEvidence,
         .complianceBands, .exceptionList]
    }

    let pdfPagination: PaginationStrategy = .sectionPerPage
    let recommendedSchedule: TemplateDataTier = .protect
}
