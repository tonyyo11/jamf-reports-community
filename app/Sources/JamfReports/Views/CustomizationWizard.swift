import SwiftUI
import AppKit
import OSLog

// MARK: - WizardState

/// Observable state for the 7-step customization wizard.
///
/// Each step writes to this model; `ConfigView`/`CustomizeView` read back from
/// `WorkspaceStore.configState` after the wizard commits.
@Observable
@MainActor
final class WizardState {

    // MARK: Step 0 — Template Selection
    var selectedTemplate: (any ReportTemplate)?
    var useCustomTemplate: Bool = false

    // MARK: Step 1 — Org Branding
    var orgName: String = ""
    var logoPath: String = ""
    var accentColor: Color = Color(hex: "#2D5EA2") ?? .blue
    var accentDark: Color = Color(hex: "#004165") ?? .blue

    // MARK: Step 2 — Compliance Framework
    enum Framework: String, CaseIterable, Identifiable {
        case none          = "None"
        case nist80053     = "NIST 800-53 Moderate"
        case fedramp       = "FedRAMP"
        case cis           = "CIS Benchmark"
        case disaStig      = "DISA STIG"
        case custom        = "Custom"
        var id: String { rawValue }
    }
    var framework: Framework = .none
    var customFrameworkLabel: String = ""

    var resolvedFramework: String {
        switch framework {
        case .none:   return ""
        case .custom: return customFrameworkLabel
        default:      return framework.rawValue
        }
    }

    // MARK: Step 3 — Extension Attributes
    var availableEAs: [ExtensionAttribute] = []
    var eaLoadError: String? = nil
    var isLoadingEAs: Bool = false
    var selectedEAIDs: Set<String> = []
    /// For EAs with type "boolean": user-supplied value that means compliant.
    var booleanTrueValues: [String: String] = [:]

    func selectedEAs() -> [ExtensionAttribute] {
        availableEAs.filter { ea in
            guard let id = ea.id else { return false }
            return selectedEAIDs.contains(id)
        }
    }

    // MARK: Step 4 — Sheet order
    var orderedSheets: [SheetItem] = []

    // MARK: Step 5 — Inventory fields
    var availableInventoryKeys: [String] = []
    var selectedInventoryKeys: Set<String> = []

    // MARK: Step 6 — Output preferences
    var outputDir: String = "Generated Reports"
    var timestampOutputs: Bool = true
    var keepLatestRuns: Int = 10

    // MARK: Step 7 — Exceptions (optional)
    var exceptions: [ConfigException] = []
    var exceptionDrafts: [CLISuggester.DraftException] = []

    // MARK: Navigation
    var currentStep: Int = 0
    let totalSteps = 9
    var isComplete: Bool = false

    /// Flipped to true on any user input; used to gate the discard-changes confirmation.
    var hasUnsavedChanges: Bool = false

    func advance() { if currentStep < totalSteps { currentStep += 1 } }
    func retreat() { if currentStep > 0 { currentStep -= 1 } }

    // MARK: Validation

    /// True when Continue should be enabled on the current step.
    var canContinue: Bool {
        if currentStep == 0 {
            return selectedTemplate != nil || useCustomTemplate
        }
        if currentStep == 2 && framework == .custom {
            return !customFrameworkLabel.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    /// Applies wizard selections on top of the workspace's current config state.
    func applyTo(_ state: inout ConfigState) {
        state.orgName = orgName
        state.logoPath = logoPath
        state.accentColor = accentColor.hexString
        state.accentDark = accentDark.hexString
        // ConfigState uses `baselineLabel` for the compliance framework label.
        state.baselineLabel = resolvedFramework

        let picked = selectedEAs()
        let newEAs: [ConfigCustomEA] = picked.map { ea in
            let name = ea.name ?? "EA"
            let trueVal = booleanTrueValues[ea.id ?? ""] ?? ""
            return ConfigCustomEA(
                name: name,
                column: name,
                // ConfigCustomEA.type is String; use the raw value directly.
                type: ea.inferredEAType,
                trueValue: trueVal,
                warningThreshold: "",
                criticalThreshold: "",
                currentVersions: [],
                warningDays: ""
            )
        }
        // Merge: keep existing EAs that aren't being re-added.
        let existingNames = Set(state.customEAs.map(\.name))
        let additions = newEAs.filter { !existingNames.contains($0.name) }
        state.customEAs.append(contentsOf: additions)

        state.outputDir = outputDir
        state.timestampOutputs = timestampOutputs
        // ConfigState stores keepLatestRuns as String.
        state.keepLatestRuns = String(keepLatestRuns)
    }

    // MARK: Exception Operations

    /// Convert a draft exception to a real ConfigException and remove from drafts.
    ///
    /// - Parameters:
    ///   - draft: The draft to accept.
    ///   - expiresDate: Optional ISO-8601 `yyyy-MM-dd` expiry date string.
    ///                  When `nil`, the exception is accepted without an expiry and
    ///                  `hasNoExpiryWarning` is set so the UI can surface an audit warning.
    @discardableResult
    func acceptDraft(_ draft: CLISuggester.DraftException, expiresDate: String? = nil) -> ConfigException {
        let exception = ConfigException(
            id: draft.draftId,
            description: draft.description,
            signedOffBy: draft.proposedSignedOffBy,
            signedOffDate: draft.proposedSignedOffDate,
            expiresDate: expiresDate,
            linkedFinding: draft.linkedFinding
        )
        if expiresDate == nil { hasNoExpiryWarning = true }

        // Remove from drafts and add to accepted
        if let index = exceptionDrafts.firstIndex(where: { $0.id == draft.id }) {
            exceptionDrafts.remove(at: index)
        }
        exceptions.append(exception)

        return exception
    }

    /// Set when an exception was accepted without an expiry date.
    /// Cleared when the next exception accepted includes an expiry date.
    /// The UI uses this to show a one-line audit warning.
    var hasNoExpiryWarning: Bool = false

    /// Remove a draft exception without accepting
    func rejectDraft(_ draft: CLISuggester.DraftException) {
        if let index = exceptionDrafts.firstIndex(where: { $0.id == draft.id }) {
            exceptionDrafts.remove(at: index)
        }
    }

    /// Add a new empty exception for manual entry
    func addEmptyException() {
        let exception = ConfigException(
            id: "MANUAL-\(String(format: "%03d", exceptions.count + 1))",
            description: "Manual exception entry",
            signedOffBy: "",
            signedOffDate: "",
            expiresDate: nil,
            linkedFinding: nil
        )
        exceptions.append(exception)
    }

    /// Returns a display label for the selected template.
    var selectedTemplateName: String {
        if useCustomTemplate {
            return "Custom"
        } else if let template = selectedTemplate {
            return template.displayName
        } else {
            return "None selected"
        }
    }
}

// MARK: - Inventory field heuristic

/// Maps raw inventory key strings (camelCase / snake_case / display) to `columns.*` config keys.
enum InventoryFieldMatcher {
    static func matchColumnKey(_ rawKey: String) -> String? {
        let lower = rawKey.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        let map: [String: String] = [
            "fullname": "full_name", "displayname": "full_name",
            "assettag": "asset_tag",
            "building": "building",
            "position": "position",
            "lastloggedinuser": "last_logged_in_user",
            "lastloggedinusername": "last_logged_in_user",
            "recoverylockpassword": "recovery_lock", "recoverylock": "recovery_lock",
            "batteryhealth": "battery_health", "batterylifecyclecount": "battery_health",
            "entrassoregistrationstatus": "entra_sso_status",
            "entrassoregistered": "entra_sso_status",
            // Phase 6 addition — purchase date.
            "purchasedate": "purchase_date", "podate": "purchase_date",
            "acquireddate": "purchase_date", "acquired": "purchase_date",
        ]
        return map[lower]
    }
}

// MARK: - Color + Hex helpers

extension Color {
    /// Initialise from a CSS hex string: "#RRGGBB" or "#RGB".
    init?(hex: String) {
        let raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let full: String
        switch raw.count {
        case 3:  full = raw.map { "\($0)\($0)" }.joined()
        case 6:  full = raw
        default: return nil
        }
        guard let value = UInt64(full, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >>  8) & 0xFF) / 255
        let b = Double( value        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// Returns a "#RRGGBB" string for use in config.yaml.
    var hexString: String {
        let resolved = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((resolved.redComponent   * 255).rounded())
        let g = Int((resolved.greenComponent * 255).rounded())
        let b = Int((resolved.blueComponent  * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
