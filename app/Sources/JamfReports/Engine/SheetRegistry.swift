import Foundation

// MARK: - SheetSkippable

/// Marker protocol for errors that represent absent-but-expected data.
///
/// When a sheet writer throws a `SheetSkippable` error the loop treats it as
/// a graceful skip — the sheet is omitted from the workbook but the run is
/// **not** marked partial. This mirrors Python's `RuntimeError`-skip semantics:
/// `CoreDashboardError.noCachedData` and `SchoolDashboardError.noCachedData`
/// both conform so tenants without specific jamf-cli snapshots don't generate
/// spurious partial-success reports.
///
/// Genuine unexpected failures (decode bugs, type mismatches, I/O errors on
/// data that *is* present) should not conform — they land in `SheetFailure`
/// and trigger the `[partial]` log line.
protocol SheetSkippable: Error {}

// MARK: - SheetFailure

/// Records a sheet that failed with an unexpected error during a generate run.
///
/// The `error` string follows the Python convention `"<ErrorType>: <message>"`
/// so downstream consumers (log parsers, run-summary readers) can handle both
/// engines uniformly.
struct SheetFailure: Sendable {
    /// The sheet name as it appears in `sheetPlan`.
    let sheet: String
    /// Serialized error: `"\(type(of: error)): \(error)"`.
    let error: String
}

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
    /// - If the action throws a `SheetSkippable` error (e.g. `noCachedData`),
    ///   the sheet is silently skipped — expected-absent data is not a failure.
    /// - If the action throws any other error, the sheet is recorded in `failures`
    ///   and a `[fail]` line is printed — unexpected errors surface as partial-success.
    /// - If the `SheetID.rawValue` has no entry in the registry, a warning is
    ///   printed and the ID is added to the returned `unimplemented` list.
    ///
    /// Returns the names of all sheets successfully written, any that failed
    /// unexpectedly, and any `SheetID`s with no registered writer.
    @discardableResult
    func writeSelected(
        template: any ReportTemplate
    ) -> (written: [String], failures: [SheetFailure], unimplemented: [SheetID]) {
        var written: [String] = []
        var failures: [SheetFailure] = []
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
            } catch let skippable as SheetSkippable {
                // Data absent or expected-missing — omit sheet, not a failure.
                print("  [skip] \(name): \(skippable)")
            } catch {
                let label = "\(type(of: error)): \(error)"
                failures.append(SheetFailure(sheet: name, error: label))
                print("  [fail] \(name): unexpected error — \(label)")
            }
        }
        return (written, failures, unimplemented)
    }
}
