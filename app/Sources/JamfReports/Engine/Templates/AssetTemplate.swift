import Foundation

// MARK: - AssetTemplate

/// Asset inventory and lifecycle template.
///
/// Audience: Asset managers, finance teams, and IT procurement.
/// Maps serial numbers to asset tags, surfaces warranty expiry dates,
/// purchase-date cohorts, building/department breakdowns, and full device
/// inventory. Uses custom field logical names: `asset_tag`, `department`,
/// `building`, `cost_center`, `purchase_date`, `warranty_expires`.
struct AssetTemplate: ReportTemplate {

    let identifier = "asset"
    let displayName = "Asset Inventory"
    let description = "Full device inventory for asset managers: serial/asset-tag map, " +
        "warranty expiry, purchase-date cohorts, and building/department breakdowns."
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
            .fleetSummary,
            .assetMap,
            .warrantyTable,
            .purchaseCohorts,
            .buildingBreakdown,
            .departmentBreakdown,
            .osAdoptionChart,
            .orgInfo,
        ]
    }

    let pdfPagination: PaginationStrategy = .standard
    // EA results are needed for asset_tag, purchase_date, warranty_expires fields.
    let recommendedSchedule: TemplateDataTier = .full
}
