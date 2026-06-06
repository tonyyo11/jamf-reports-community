import Foundation

// MARK: - ComplianceTemplate

/// Compliance / auditor template — evidence-grade deliverable.
///
/// Audience: Internal auditors, security teams, and compliance officers.
/// Includes mSCP audit results, patch compliance bands, OS adoption,
/// exception lists, DDM/Blueprint status, and an evidence appendix.
/// Paginated one-section-per-page for formal review packages.
struct ComplianceTemplate: ReportTemplate {

    let identifier = "compliance"
    let displayName = "Compliance"
    let description = "Auditor-grade deliverable: mSCP results, patch compliance bands, " +
        "OS adoption, exception list, DDM status, and evidence appendix."
    let audience = "Internal auditors, security teams, compliance officers"

    var includedSheets: [SheetID] {
        [
            .cover,
            .compliancePosture,
            .auditSummary,
            .mscpCompliance,
            .complianceTrend,
            .deviceCompliance,
            .complianceDevices,
            .complianceRules,
            .ddmStatus,
            .blueprintStatus,
            .patchCompliance,
            .patchFailures,
            .securityPosture,
            .profileStatus,
            .eaCoverage,
            .eaDefinitions,
        ]
    }

    var htmlSections: [SectionID] {
        [
            .kpiTiles,
            .complianceBands,
            .auditEvidence,
            .exceptionList,
            .osAdoptionChart,
            .profileTable,
        ]
    }

    let pdfPagination: PaginationStrategy = .sectionPerPage
    let recommendedSchedule: TemplateDataTier = .platform
}
