import Foundation

// MARK: - ExecutiveTemplate

/// Executive summary template — the historical default layout.
///
/// Audience: Directors, VPs, and CISOs reviewing fleet health at a glance.
/// Covers KPI tiles, fleet overview, security posture, compliance, and
/// top-10 patch titles with an executive narrative appendix.
struct ExecutiveTemplate: ReportTemplate {

    let identifier = "executive"
    let displayName = "Executive"
    let description = "KPI overview for directors and CISOs: security posture, " +
        "compliance health, top-10 patch titles, and fleet summary."
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
            .kpiTiles,
            .osAdoptionChart,
            .complianceBands,
            .execSummary,
            .orgInfo,
        ]
    }

    let pdfPagination: PaginationStrategy = .standard
    let recommendedSchedule: TemplateDataTier = .core
}
