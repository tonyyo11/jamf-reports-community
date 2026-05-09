import Foundation

/// Pure service that applies a `ReportTemplate` to wizard state.
///
/// Maps template characteristics → sensible defaults for wizard fields:
/// sheets enabled, thresholds, schedule hint, retention defaults.
/// No I/O, no CLI calls, no side effects beyond mutating `WizardState`.
enum TemplateApplier {

    /// Apply template defaults to wizard state on `@MainActor`.
    @MainActor
    static func apply(_ template: any ReportTemplate, to state: WizardState) {
        applySheetDefaults(template, to: state)
        applyThresholdDefaults(template, to: state)
        applyOutputDefaults(template, to: state)
    }

    /// Enable sheets based on template's `includedSheets`.
    @MainActor
    private static func applySheetDefaults(_ template: any ReportTemplate, to state: WizardState) {
        let enabledSheetNames = Set(template.includedSheets.map(\.rawValue))

        for i in state.orderedSheets.indices {
            state.orderedSheets[i].on = enabledSheetNames.contains(state.orderedSheets[i].name)
        }
    }

    /// Set threshold and stale-days defaults per template audience.
    @MainActor
    private static func applyThresholdDefaults(_ template: any ReportTemplate, to state: WizardState) {
        // Future: when wizard gains threshold step, populate here
        // For now, just set a computed property that suggester can reference
    }

    /// Set output retention and naming defaults per template.
    @MainActor
    private static func applyOutputDefaults(_ template: any ReportTemplate, to state: WizardState) {
        switch template.identifier {
        case "executive":
            state.keepLatestRuns = 20  // Executives review monthly archives
            state.timestampOutputs = true

        case "compliance":
            state.keepLatestRuns = 50  // Auditors need long historical trail
            state.timestampOutputs = true

        case "operational":
            state.keepLatestRuns = 7   // NOC generates daily, keep recent only
            state.timestampOutputs = true

        case "asset":
            state.keepLatestRuns = 15  // Asset lifecycle tracking
            state.timestampOutputs = true

        case "security-posture":
            state.keepLatestRuns = 30  // Security review cycles
            state.timestampOutputs = true

        default:
            state.keepLatestRuns = 10  // Default fallback
            state.timestampOutputs = true
        }
    }

    /// Get recommended stale device threshold for template.
    static func recommendedStaleDays(for template: any ReportTemplate) -> Int {
        switch template.identifier {
        case "compliance":     return 30  // Audit tolerances
        case "asset":          return 60  // Asset lifecycle view
        case "operational":    return 14  // Daily ops needs current data
        case "executive":      return 30  // Executive monthly view
        case "security-posture": return 7 // Security needs fresh data
        default:               return 30  // Balanced default
        }
    }

    /// Get recommended warning/critical thresholds for percentage EAs.
    static func recommendedThresholds(for template: any ReportTemplate) -> (warning: Int, critical: Int) {
        switch template.identifier {
        case "compliance":
            return (warning: 85, critical: 95)  // Tight audit standards
        case "operational":
            return (warning: 80, critical: 90)  // Actionable NOC thresholds
        case "security-posture":
            return (warning: 70, critical: 85)  // Security prefers early warnings
        default:
            return (warning: 80, critical: 90)  // Balanced defaults
        }
    }

    /// Get EA keyword hints for template-relevant filtering.
    static func eaKeywords(for template: any ReportTemplate) -> [String] {
        switch template.identifier {
        case "compliance":
            return ["audit", "compliance", "stig", "nist", "cis", "baseline", "check", "rule"]
        case "security-posture":
            return ["filevault", "gatekeeper", "firewall", "crowd", "sentinel", "defender",
                    "security", "encryption", "antivirus", "endpoint"]
        case "asset":
            return ["warranty", "purchase", "asset", "serial", "model", "hardware",
                    "lifecycle", "depreciation"]
        case "operational":
            return ["status", "health", "uptime", "connectivity", "agent", "client",
                    "maintenance", "service"]
        default:
            return []
        }
    }
}