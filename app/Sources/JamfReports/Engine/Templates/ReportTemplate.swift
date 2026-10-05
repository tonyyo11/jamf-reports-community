import Foundation

// MARK: - Identifiers

/// Logical sheet identifiers that map to `CoreDashboard.sheetPlan` names.
/// Raw values match the exact sheet names used in the plan so the engine
/// can resolve a template's `includedSheets` against the write-plan.
enum SheetID: String, Sendable, CaseIterable {
    // Framing / exec-priority
    case executiveSummary    = "Executive Summary"
    case cover               = "Cover"
    case compliancePosture   = "Compliance Posture"
    case fleetOverview       = "Fleet Overview"
    case securityPosture     = "Security Posture"
    case patchCompliance     = "Patch Compliance"
    case deviceCompliance    = "Device Compliance"
    case auditSummary        = "Audit Summary"
    // Inventory & hardware
    case inventorySummary    = "Inventory Summary"
    case hardwareModels      = "Hardware Models"
    case mobileFleetSummary  = "Mobile Fleet Summary"
    case mobileInventory     = "Mobile Inventory"
    // Configuration health
    case policyHealth        = "Policy Health"
    case profileStatus       = "Profile Status"
    case mobileConfigProfiles = "Mobile Config Profiles"
    case appStatus           = "App Status"
    case softwareInstalls    = "Software Installs"
    case packageLifecycle    = "Package Lifecycle"
    case eaCoverage          = "EA Coverage"
    case eaDefinitions       = "EA Definitions"
    case environmentStats    = "Environment Stats"
    // Device health
    case checkinHealth       = "Check-in Health"
    case activeDevices       = "Active Devices"
    case groupHygiene        = "Group Hygiene"
    // Update & patch details
    case patchFailures       = "Patch Failures"
    case updateStatus        = "Update Status"
    case updateFailures      = "Update Failures"
    case smartGroups         = "Smart Groups"
    case patchSummaryDashboard = "Patch Summary Dashboard"
    case patchVelocity       = "Patch Velocity"
    // Device security & supervision detail
    case deviceSecurityState = "Device Security State"
    case mobileSupervisionStatus = "Mobile Supervision Status"
    // Platform / DDM
    case complianceDevices   = "Compliance Devices"
    case complianceRules     = "Compliance Rules"
    case ddmStatus           = "DDM Status"
    case blueprintStatus     = "Blueprint Status"
    // Per-device scan (2.8.0)
    case ddmDeviceStatus     = "DDM Device Status"
    case mdmCommandHealth    = "MDM Command Health"
    // Protect
    case protectOverview     = "Protect Overview"
    case protectAlerts       = "Protect Alerts"
    case protectComputers    = "Protect Computers"
    case protectInsights     = "Protect Insights"
    case protectPlans        = "Protect Plans"
    case protectThreatOverview = "Protect Threat Overview"
    // OS currency
    case osCurrency          = "OS Currency"
    // mSCP / STIG compliance
    case mscpCompliance      = "mSCP Compliance"
    case complianceTrend     = "Compliance Trend"
}

/// Logical HTML section identifiers.
///
/// A report has a fixed shape: the framing sections (`aiNarrative`, `atAGlance`,
/// `needsAttention`, `jamfDashboard`, `auditAppendix`) and, between the dashboard and the
/// appendix, the detail sections, which `HtmlDetailGroup` gathers into collapsed groups. A
/// template lists the sections it wants; the order of the list does not change the order of
/// the page.
enum SectionID: String, Sendable, CaseIterable {
    /// Six figures with their change over about a week.
    case atAGlance       = "at_a_glance"
    /// A sentence per rule that fires, each linking to the part that lists it.
    case needsAttention  = "needs_attention"
    /// Data sources, metric definitions, the security policy and what the report leaves out.
    case auditAppendix   = "audit_appendix"
    case securityTiles   = "security_tiles"
    case osAdoptionChart = "os_adoption_chart"
    case patchBar        = "patch_bar"
    case policyTable     = "policy_table"
    case profileTable    = "profile_table"
    /// Apps that failed to install, from `app-status`; the profile table's twin.
    case appTable        = "app_table"
    case complianceBands = "compliance_bands"
    case auditEvidence   = "audit_evidence"
    case exceptionList   = "exception_list"
    case orgInfo         = "org_info"
    case protectAlerts   = "protect_alerts"
    case insightsDrift   = "insights_drift"
    case agentHealth     = "agent_health"
    case recentFailures  = "recent_failures"
    case interventionList = "intervention_list"
    case patchQueue      = "patch_queue"
    case purchaseCohorts = "purchase_cohorts"
    case buildingBreakdown = "building_breakdown"
    case departmentBreakdown = "department_breakdown"
    // AI executive narrative (F3) — renders only when a narrative was passed
    // into the engine (GUI-generate only); omitted entirely otherwise.
    case aiNarrative     = "ai_narrative"
    case cleanupAnalysis = "cleanup_analysis"
    case timeline        = "timeline"
    case osCurrency      = "os_currency"
    /// jamf-cli's `dashboard` page, embedded from the newest `dashboard` snapshot.
    case jamfDashboard   = "jamf_dashboard"
}

/// PDF pagination strategy hint.
enum PaginationStrategy: String, Sendable {
    /// The summary on one page, then a page per detail group — for formal auditor
    /// deliverables.
    case sectionPerPage  = "section_per_page"
    /// Compact flow — minimize page count for NOC/daily ops brevity.
    case compact         = "compact"
    /// Standard — balanced pagination for general management review.
    case standard        = "standard"
}

/// Data-collection completeness tier for templates.
///
/// Describes the minimum set of jamf-cli collect commands required to fully
/// populate a template. The engine team can use this to warn users when required
/// snapshots are stale or absent.
///
/// Distinct from `CollectionTier` (Services layer), which describes per-report
/// collection cadence.
enum TemplateDataTier: String, Sendable {
    /// Requires only the core jamf-cli pro collect set (security, patch, inventory).
    case core        = "core"
    /// Requires core plus DDM/blueprint/compliance-devices.
    case platform    = "platform"
    /// Requires platform plus Protect collect.
    case protect     = "protect"
    /// Requires full collect including EA results (slow on large tenants).
    case full        = "full"
    /// Requires jamf-cli school collect (Jamf School tenants only).
    case school      = "school"
}

// MARK: - Protocol

/// A pure-data description of a report template.
///
/// Templates carry no rendering logic — they describe which sheets/sections to
/// include and how to present them. The engine team consumes this at generation
/// time to filter `CoreDashboard.sheetPlan` and configure `HtmlReport` sections.
///
/// All concrete types must be `Sendable` (pure value types or `@unchecked Sendable`
/// for reference types that guarantee thread-safety by construction).
protocol ReportTemplate: Sendable {

    /// Stable, lowercase, hyphenated identifier. Never localised.
    /// Example: `"executive"`, `"operational"`.
    var identifier: String { get }

    /// Short human-readable name shown in the UI template picker.
    var displayName: String { get }

    /// One-sentence description of the template's audience and purpose.
    var description: String { get }

    /// Short phrase naming the intended audience.
    /// Displayed below the picker in GenerateSheet as "For: <audience>".
    /// Example: `"K-12 IT, lab managers, education sysadmin"`.
    var audience: String { get }

    /// Ordered list of Excel sheet IDs to include. The engine preserves this order
    /// unless the user has applied a custom `sheets.order` override.
    var includedSheets: [SheetID] { get }

    /// HTML section IDs to render in the instance report. Membership only: the page's order
    /// is fixed (see `SectionID`).
    var htmlSections: [SectionID] { get }

    /// Sections whose detail group starts open in the HTML report. A group holding any of
    /// them is open; every other group starts collapsed. Empty by default.
    var htmlOpenSections: [SectionID] { get }

    /// PDF pagination hint. Passed to `PDFExporter` as a page-break strategy.
    var pdfPagination: PaginationStrategy { get }

    /// Minimum data-collection tier required for a complete render.
    var recommendedSchedule: TemplateDataTier { get }
}

extension ReportTemplate {
    var htmlOpenSections: [SectionID] { [] }
}
