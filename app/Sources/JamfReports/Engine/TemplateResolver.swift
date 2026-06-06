import Foundation

// MARK: - TemplateResolver

/// Resolves a template identifier string to a concrete `ReportTemplate`.
///
/// The identifier must match one of the registered templates exactly (case-sensitive,
/// hyphenated). Unknown identifiers fall back to `ExecutiveTemplate` with a warning
/// log line so callers never receive an invalid template from untrusted input.
///
/// Template selection always goes through this resolver — identifiers from disk, from
/// `UserDefaults`, or from the picker binding are never cast to `any ReportTemplate`
/// directly. This prevents arbitrary template injection via user-supplied strings.
enum TemplateResolver {

    // MARK: - All known templates

    /// The authoritative list of all registered templates.
    ///
    /// Adding a new template: append it here and nowhere else. The picker and
    /// `SheetRegistry` both derive their lists from this single source.
    /// Note: CustomTemplate is not included here since it requires specific
    /// sheet selection and is handled separately by `resolveCustom`.
    static var allTemplates: [any ReportTemplate] {
        [
            FullInstanceTemplate(),
            ExecutiveTemplate(),
            OperationalTemplate(),
            ComplianceTemplate(),
            AssetTemplate(),
            SecurityPostureTemplate(),
            SchoolTemplate(),
            CustomTemplate(includedSheets: []), // Empty placeholder for UI listing
        ]
    }

    // MARK: - Resolve

    /// Return the template matching `identifier`, or `ExecutiveTemplate` on a miss.
    ///
    /// A warning is printed to stderr when the identifier is unrecognized. This is
    /// intentional: silent fallback hides configuration drift; a log line surfaces it.
    ///
    /// - Parameter identifier: The `ReportTemplate.identifier` value to look up.
    ///   Must be a known, stable identifier such as `"executive"` or `"compliance"`.
    /// - Returns: The matching template, or `ExecutiveTemplate()` when unrecognized.
    static func resolve(identifier: String) -> any ReportTemplate {
        // Special case: "custom" requires specific sheets and should not be resolved here
        if identifier == "custom" {
            print("[warn] TemplateResolver: 'custom' template requires sheets selection. " +
                  "Use resolveCustom(sheets:) instead. Falling back to ExecutiveTemplate.")
            return ExecutiveTemplate()
        }

        if let match = allTemplates.first(where: { $0.identifier == identifier }) {
            return match
        }
        let known = allTemplates.map(\.identifier).joined(separator: ", ")
        print("[warn] TemplateResolver: unknown identifier '\(identifier)'. " +
              "Known: \(known). Falling back to ExecutiveTemplate.")
        return ExecutiveTemplate()
    }

    /// Resolve a custom template with the specified sheet selection.
    ///
    /// - Parameter sheets: The ordered list of sheets to include in the custom report.
    ///                     Must contain at least one sheet.
    /// - Returns: A CustomTemplate configured with the specified sheets,
    ///            or ExecutiveTemplate if the sheets list is empty.
    static func resolveCustom(sheets: [SheetID]) -> any ReportTemplate {
        guard !sheets.isEmpty else {
            print("[warn] TemplateResolver: custom template requires at least one sheet. " +
                  "Falling back to ExecutiveTemplate.")
            return ExecutiveTemplate()
        }
        return CustomTemplate(includedSheets: sheets)
    }
}
