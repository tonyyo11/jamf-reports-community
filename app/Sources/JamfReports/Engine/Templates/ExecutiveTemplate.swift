import Foundation

// MARK: - ExecutiveTemplate

/// Executive summary template.
///
/// Audience: Directors, VPs, and CISOs reviewing fleet health at a glance.
/// The HTML report is the framing only: the six figures, what needs attention, the jamf-cli
/// dashboard and the audit appendix, with no detail groups. The workbook carries the detail.
struct ExecutiveTemplate: ReportTemplate {

    let identifier = "executive"
    let displayName = "Executive"
    let description = "Summary for directors and CISOs: six figures with their change, " +
        "what needs attention, and the fleet dashboard. No detail tables in the HTML report."
    let audience = "Directors, VPs, CISOs"

    var includedSheets: [SheetID] {
        [
            .executiveSummary,
            .cover,
            .compliancePosture,
            .fleetOverview,
            .securityPosture,
            .patchCompliance,
            .deviceCompliance,
            .auditSummary,
            .inventorySummary,
        ]
    }

    var htmlSections: [SectionID] {
        [
            .aiNarrative,
            .atAGlance,
            .needsAttention,
            .jamfDashboard,
            .auditAppendix,
        ]
    }

    let pdfPagination: PaginationStrategy = .standard
    let recommendedSchedule: TemplateDataTier = .core
}
