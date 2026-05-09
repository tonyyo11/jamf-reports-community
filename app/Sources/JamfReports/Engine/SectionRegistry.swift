import Foundation

// MARK: - SectionRegistry

/// Maps `SectionID` values to the HTML section builders in `HtmlReport`.
///
/// Each section builder is a zero-argument closure returning an HTML string fragment.
/// The registry mirrors `SheetRegistry`'s dispatch pattern for HTML sections:
/// iterate `template.htmlSections`, invoke registered builders in template order,
/// skip unknown IDs with a warning.
///
/// Sections that `HtmlReport` cannot yet render are logged as `unimplemented` —
/// they are NOT silently dropped. The engine-team follow-up list comes from here.
/// - Note: `@unchecked Sendable` because stored closures may not be `@Sendable`.
///   Safety is guaranteed by the same single-task, read-only-after-init pattern
///   used by `SheetRegistry`.
struct SectionRegistry: @unchecked Sendable {

    // MARK: - Types

    /// A builder closure that returns an HTML string fragment for one section.
    typealias BuildAction = () -> String

    // MARK: - Storage

    private let builders: [String: BuildAction]

    // MARK: - Init

    /// Register section builders by `SectionID.rawValue`.
    ///
    /// - Parameter builders: Dictionary keyed by `SectionID.rawValue`. Empty string
    ///   returns are valid — `HtmlReport` returns `""` for sections with no data.
    init(builders: [String: BuildAction]) {
        self.builders = builders
    }

    // MARK: - Dispatch

    /// Render the sections listed in `template.htmlSections`, in template order.
    ///
    /// For each `SectionID` in `template.htmlSections`:
    /// - If registered, the builder is invoked and its output appended.
    /// - If unregistered, a `<!-- section: <id> unimplemented -->` comment is
    ///   inserted and the ID is added to the returned `unimplemented` list so the
    ///   engine team has a clear follow-up list.
    ///
    /// Returns the concatenated HTML body and the list of unimplemented section IDs.
    func renderSelected(
        template: any ReportTemplate
    ) -> (html: String, unimplemented: [SectionID]) {
        var parts: [String] = []
        var unimplemented: [SectionID] = []
        for sectionID in template.htmlSections {
            let key = sectionID.rawValue
            if let builder = builders[key] {
                let fragment = builder()
                if !fragment.isEmpty {
                    parts.append(fragment)
                }
            } else {
                print("[warn] SectionRegistry: no builder registered for SectionID '\(key)' " +
                      "(template: \(template.identifier)). This is an engine-team follow-up.")
                parts.append("<!-- section: \(key) unimplemented -->")
                unimplemented.append(sectionID)
            }
        }
        return (parts.joined(separator: "\n"), unimplemented)
    }
}
