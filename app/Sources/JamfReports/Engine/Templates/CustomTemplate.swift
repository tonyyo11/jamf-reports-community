import Foundation

// MARK: - CustomTemplate

/// User-selectable custom template for generating reports with specific sheets.
///
/// Allows users to choose exactly which sheets to include in their reports,
/// rather than using pre-defined template collections. Sheets are ordered by
/// SheetID rawValue sort order (the storage key) regardless of tap order.
struct CustomTemplate: ReportTemplate {

    let identifier = "custom"
    let displayName = "Custom — choose sheets"
    let description = "User-selected sheets only — choose exactly which sections to include."
    let audience = "Custom reporting requirements"

    /// The user-selected sheets to include in the report.
    /// Ordered by SheetID rawValue sort order (serialized via `.sorted()` in storage).
    let includedSheets: [SheetID]

    /// HTML sections derived from the selected sheets.
    /// Maps each selected sheet to its corresponding HTML section when possible.
    var htmlSections: [SectionID] {
        // Map selected sheets to their corresponding HTML sections
        // For sheets without a clear HTML mapping, include common sections
        var sections: [SectionID] = []

        // Always include these foundational sections for readability
        if !includedSheets.isEmpty {
            sections.append(.kpiTiles)
            sections.append(.fleetSummary)
        }

        // Map specific sheets to their HTML sections
        for sheet in includedSheets {
            switch sheet {
            case .executiveSummary:
                if !sections.contains(.aiNarrative) { sections.append(.aiNarrative) }
                if !sections.contains(.execSummary) { sections.append(.execSummary) }
            case .securityPosture:
                if !sections.contains(.securityTiles) { sections.append(.securityTiles) }
            case .compliancePosture:
                if !sections.contains(.complianceBands) { sections.append(.complianceBands) }
            case .patchCompliance, .patchFailures:
                if !sections.contains(.patchBar) { sections.append(.patchBar) }
                if !sections.contains(.patchQueue) { sections.append(.patchQueue) }
            case .auditSummary:
                if !sections.contains(.auditEvidence) { sections.append(.auditEvidence) }
            case .inventorySummary, .hardwareModels:
                if !sections.contains(.assetMap) { sections.append(.assetMap) }
            case .osCurrency:
                if !sections.contains(.osAdoptionChart) { sections.append(.osAdoptionChart) }
                if !sections.contains(.osCurrency) { sections.append(.osCurrency) }
            case .policyHealth:
                if !sections.contains(.policyTable) { sections.append(.policyTable) }
            case .profileStatus, .mobileConfigProfiles:
                if !sections.contains(.profileTable) { sections.append(.profileTable) }
            case .protectOverview, .protectAlerts, .protectComputers, .protectInsights:
                if !sections.contains(.protectAlerts) { sections.append(.protectAlerts) }
                if !sections.contains(.insightsDrift) { sections.append(.insightsDrift) }
            default:
                // For other sheets, no specific HTML section mapping
                break
            }
        }

        // Always include org info if any sheets were selected
        if !sections.contains(.orgInfo) && !includedSheets.isEmpty {
            sections.append(.orgInfo)
        }

        return sections
    }

    let pdfPagination: PaginationStrategy = .standard
    let recommendedSchedule: TemplateDataTier = .core

    /// Initialize with a specific set of sheets.
    ///
    /// - Parameter sheets: The ordered list of sheets to include in the custom report.
    init(includedSheets: [SheetID]) {
        self.includedSheets = includedSheets
    }
}