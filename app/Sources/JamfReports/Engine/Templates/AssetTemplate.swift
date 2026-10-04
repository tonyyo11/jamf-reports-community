import Foundation

// MARK: - AssetTemplate

/// Asset inventory and lifecycle template.
///
/// Audience: Asset managers, finance teams, and IT procurement.
/// Surfaces purchase-date cohorts and building/department breakdowns. The device-by-device
/// inventory (serial, asset tag, department, building) is in the workbook: an HTML report is
/// forwarded, so it carries no full device list. Uses custom field logical names:
/// `asset_tag`, `department`, `building`, `cost_center`, `purchase_date`.
struct AssetTemplate: ReportTemplate {

    let identifier = "asset"
    let displayName = "Asset Inventory"
    let description = "Asset view for asset managers: purchase-date cohorts and " +
        "building/department breakdowns. The device inventory is in the workbook."
    let audience = "Asset managers, finance teams, IT procurement"

    var includedSheets: [SheetID] {
        [
            .inventorySummary,
            .hardwareModels,
            .checkinHealth,
            .activeDevices,
            .mobileFleetSummary,
            .mobileInventory,
            .softwareInstalls,
            .packageLifecycle,
            .environmentStats,
            .eaDefinitions,
        ]
    }

    var htmlSections: [SectionID] {
        [
            .atAGlance,
            .needsAttention,
            .purchaseCohorts,
            .buildingBreakdown,
            .departmentBreakdown,
            .osAdoptionChart,
            .orgInfo,
            .auditAppendix,
        ]
    }

    let pdfPagination: PaginationStrategy = .standard
    // EA results are needed for asset_tag and purchase_date fields.
    let recommendedSchedule: TemplateDataTier = .full
}
