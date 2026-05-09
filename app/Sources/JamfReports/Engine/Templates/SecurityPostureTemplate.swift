import Foundation

// MARK: - SecurityPostureTemplate

/// Security posture deep-dive template.
///
/// Audience: Security engineers and CISO staff conducting periodic security reviews.
/// Surfaces Protect alerts, mSCP audit findings, FileVault/Gatekeeper/SIP/Firewall
/// percentages, CrowdStrike and other security-agent health, and Protect insights
/// drift over time. Requires the `protect` collection tier.
struct SecurityPostureTemplate: ReportTemplate {

    let identifier = "security-posture"
    let displayName = "Security Posture"
    let description = "Security-engineer deep-dive: Protect alerts, mSCP findings, " +
        "FileVault/SIP/Gatekeeper/Firewall health, agent coverage, and insights drift."
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
            .protectInsights,
            .patchCompliance,
            .patchFailures,
            .eaCoverage,
        ]
    }

    var htmlSections: [SectionID] {
        [
            .kpiTiles,
            .securityTiles,
            .protectAlerts,
            .insightsDrift,
            .agentHealth,
            .auditEvidence,
            .complianceBands,
            .patchBar,
            .exceptionList,
        ]
    }

    let pdfPagination: PaginationStrategy = .sectionPerPage
    let recommendedSchedule: TemplateDataTier = .protect
}
