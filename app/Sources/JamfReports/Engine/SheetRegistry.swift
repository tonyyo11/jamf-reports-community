import Foundation

// MARK: - SheetRegistry

/// Maps `SheetID` values to the write closures exposed by `CoreDashboard.sheetPlan`.
///
/// The registry is built once per generate run from the dashboard's `sheetPlan` —
/// a flat list of `(name: String, write: () throws -> Void)` tuples. The registry
/// indexes those closures by `SheetID.rawValue` so the engine can iterate
/// `template.includedSheets` and dispatch in template order rather than plan order.
///
/// Unknown IDs (i.e., `SheetID` values not present in the plan) are skipped with
/// a warning. This is the expected path for template entries that reference sheets
/// planned for a future sprint — graceful degradation keeps the workbook valid.
/// - Note: `@unchecked Sendable` because the stored closures are plain
///   `() throws -> Void` (not `@Sendable`). Safety is guaranteed by construction:
///   the registry is built once synchronously, then used read-only within a single
///   structured-concurrency task. No concurrent access occurs.
struct SheetRegistry: @unchecked Sendable {

    // MARK: - Types

    /// A write closure captured from `CoreDashboard.sheetPlan`.
    ///
    /// Not marked `@Sendable` because `sheetPlan` returns plain `() throws -> Void`
    /// closures that capture a copy of the `Sendable` struct. These are used
    /// synchronously within a single structured-concurrency task — no cross-actor
    /// boundary is crossed during dispatch.
    typealias WriteAction = () throws -> Void

    // MARK: - Storage

    // `@unchecked Sendable` is safe here: actions are write-once at init, read-only
    // after construction, and only invoked from the engine's async task.
    private let actions: [String: WriteAction]

    // MARK: - Init

    /// Build a registry from a sheet plan array.
    ///
    /// - Parameter plan: The `sheetPlan` from `CoreDashboard` — ordered tuples of
    ///   `(name: String, write: () throws -> Void)`. The registry indexes by name,
    ///   so order in `plan` does not matter here; template sheet order governs output.
    init(plan: [(name: String, write: () throws -> Void)]) {
        var map: [String: WriteAction] = [:]
        for (name, action) in plan {
            map[name] = action
        }
        self.actions = map
    }

    // MARK: - Dispatch

    /// Write the sheets listed in `template.includedSheets`, in template order.
    ///
    /// For each `SheetID` in `template.includedSheets`:
    /// - If the registry contains a matching write action, it is called.
    /// - If the action throws (missing or malformed data), the sheet is silently
    ///   skipped — same graceful behavior as `CoreDashboard.writeAll()`.
    /// - If the `SheetID.rawValue` has no entry in the registry, a warning is
    ///   printed and the ID is added to the returned `unimplemented` list.
    ///
    /// Returns the names of all sheets that were successfully written.
    @discardableResult
    func writeSelected(template: any ReportTemplate) -> (written: [String], unimplemented: [SheetID]) {
        var written: [String] = []
        var unimplemented: [SheetID] = []
        for sheetID in template.includedSheets {
            let name = sheetID.rawValue
            guard let action = actions[name] else {
                print("[warn] SheetRegistry: no writer registered for SheetID '\(name)' " +
                      "(template: \(template.identifier)). Add a sheet writer to CoreDashboard.")
                unimplemented.append(sheetID)
                continue
            }
            do {
                try action()
                written.append(name)
            } catch {
                // Data absent or malformed — skip sheet gracefully, matching CoreDashboard behavior.
            }
        }
        return (written, unimplemented)
    }
}
