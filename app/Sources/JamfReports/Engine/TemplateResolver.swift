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
    static var allTemplates: [any ReportTemplate] {
        [
            ExecutiveTemplate(),
            OperationalTemplate(),
            ComplianceTemplate(),
            AssetTemplate(),
            SecurityPostureTemplate(),
            SchoolTemplate(),
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
        if let match = allTemplates.first(where: { $0.identifier == identifier }) {
            return match
        }
        let known = allTemplates.map(\.identifier).joined(separator: ", ")
        print("[warn] TemplateResolver: unknown identifier '\(identifier)'. " +
              "Known: \(known). Falling back to ExecutiveTemplate.")
        return ExecutiveTemplate()
    }
}
