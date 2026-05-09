import Foundation

// MARK: - SchoolTemplate

/// Jamf School report template — K-12 and education lab inventory.
///
/// Audience: K-12 IT administrators, lab managers, and education sysadmins.
/// Covers device inventory, OS versions, device status, stale devices,
/// school overview, device groups, users, classes, apps, profiles, and locations.
/// Requires the `school` collection tier (jamf-cli school collect).
struct SchoolTemplate: ReportTemplate {

    let identifier = "school"
    let displayName = "School (Jamf School)"
    let description = "Inventory, classes, users, profiles, and device status for " +
        "Jamf School-managed iPads and Macs."
    let audience = "K-12 IT, lab managers, education sysadmin"

    var includedSheets: [SheetID] {
        // School-specific sheets from SchoolDashboard.writeAll() sheet plan.
        // SheetID values map to the exact sheet names SchoolDashboard writes.
        // mobileInventory ≈ Device Inventory; mobileFleetSummary ≈ School Overview.
        // Remaining school sheet names (Device Groups, Users, Classes, etc.) do not
        // yet have dedicated SheetID cases — tracked in the engine backlog.
        // The four entries below are the intersection of school content and existing SheetIDs.
        [
            .mobileFleetSummary,
            .mobileInventory,
            .mobileConfigProfiles,
            .appStatus,
        ]
    }

    var htmlSections: [SectionID] {
        [
            .kpiTiles,
            .fleetSummary,
            .osAdoptionChart,
            .orgInfo,
        ]
    }

    let pdfPagination: PaginationStrategy = .compact
    let recommendedSchedule: TemplateDataTier = .school
}
