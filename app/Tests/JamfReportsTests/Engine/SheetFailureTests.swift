import Foundation
import XCTest
@testable import JamfReports

// MARK: - SheetFailureTests
//
// Verifies the partial-success contract introduced in the Swift engine to mirror
// Python's `(written, failures)` tuple returned by CoreDashboard/SchoolDashboard.
//
// Contract:
//   - SheetSkippable errors (e.g. noCachedData) → silent skip, not a failure.
//   - All other errors → SheetFailure entry with "<ErrorType>: <message>" string.
//   - SheetRegistry.writeSelected returns (written, failures, unimplemented).
//   - All-succeed → failures is empty.
//   - One unexpected failure → failures has one entry, written excludes that sheet.
//   - error string format matches Python's "<ErrorType>: <message>" convention.

// MARK: - Test error types

/// Simulates a "data absent" condition that should be silently skipped.
private struct TestSkippableError: Error, SheetSkippable {}

/// Simulates an unexpected runtime error that should be reported as a failure.
private struct TestRealError: Error {
    let message: String
}

// MARK: - Minimal ReportTemplate stub

private struct SingleSheetTemplate: ReportTemplate {
    let identifier = "test-single"
    let displayName = "Test Single"
    let description = ""
    let audience = "tests"
    let includedSheets: [SheetID]
    let htmlSections: [SectionID] = []
    let pdfPagination: PaginationStrategy = .standard
    let recommendedSchedule: TemplateDataTier = .core

    init(sheetIDs: [SheetID]) {
        self.includedSheets = sheetIDs
    }
}

// MARK: - SheetRegistryFailureTests

final class SheetRegistryFailureTests: XCTestCase {

    // MARK: - All succeed → no failures

    func testAllSucceedProducesNoFailures() {
        let template = SingleSheetTemplate(sheetIDs: [.fleetOverview, .securityPosture])
        let plan: [(name: String, write: () throws -> Void)] = [
            (SheetID.fleetOverview.rawValue, {}),
            (SheetID.securityPosture.rawValue, {}),
        ]
        let registry = SheetRegistry(plan: plan)
        let (written, failures, unimplemented) = registry.writeSelected(template: template)

        XCTAssertEqual(written.count, 2, "Both sheets should be written")
        XCTAssertTrue(failures.isEmpty, "No failures when all writers succeed")
        XCTAssertTrue(unimplemented.isEmpty, "No unimplemented when all IDs are registered")
    }

    // MARK: - Skippable error → skip, no failure

    func testSkippableErrorProducesSkipNotFailure() {
        let template = SingleSheetTemplate(sheetIDs: [.fleetOverview])
        let plan: [(name: String, write: () throws -> Void)] = [
            (SheetID.fleetOverview.rawValue, { throw TestSkippableError() }),
        ]
        let registry = SheetRegistry(plan: plan)
        let (written, failures, unimplemented) = registry.writeSelected(template: template)

        XCTAssertTrue(written.isEmpty, "Skipped sheet must not appear in written")
        XCTAssertTrue(failures.isEmpty, "SheetSkippable must not produce a failure entry")
        XCTAssertTrue(unimplemented.isEmpty)
    }

    // MARK: - Unexpected error → failure entry

    func testUnexpectedErrorProducesFailureEntry() {
        let template = SingleSheetTemplate(sheetIDs: [.fleetOverview])
        let plan: [(name: String, write: () throws -> Void)] = [
            (SheetID.fleetOverview.rawValue, { throw TestRealError(message: "disk full") }),
        ]
        let registry = SheetRegistry(plan: plan)
        let (written, failures, _) = registry.writeSelected(template: template)

        XCTAssertTrue(written.isEmpty, "Failed sheet must not appear in written")
        XCTAssertEqual(failures.count, 1, "One failure expected")
        XCTAssertEqual(failures[0].sheet, SheetID.fleetOverview.rawValue)
        // Verify Python-compatible error format: "<ErrorType>: <description>"
        XCTAssertTrue(failures[0].error.hasPrefix("TestRealError:"),
                      "Error string must start with the type name: \(failures[0].error)")
    }

    // MARK: - Mixed: one success, one skip, one failure

    func testMixedResultsAreCorrectlyBucketed() {
        let template = SingleSheetTemplate(sheetIDs: [
            .fleetOverview, .securityPosture, .patchCompliance,
        ])
        let plan: [(name: String, write: () throws -> Void)] = [
            (SheetID.fleetOverview.rawValue, {}),                                    // success
            (SheetID.securityPosture.rawValue, { throw TestSkippableError() }),      // skip
            (SheetID.patchCompliance.rawValue, { throw TestRealError(message: "x") }), // fail
        ]
        let registry = SheetRegistry(plan: plan)
        let (written, failures, unimplemented) = registry.writeSelected(template: template)

        XCTAssertEqual(written, [SheetID.fleetOverview.rawValue])
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].sheet, SheetID.patchCompliance.rawValue)
        XCTAssertTrue(unimplemented.isEmpty)
    }

    // MARK: - CoreDashboardError conforms to SheetSkippable

    func testCoreDashboardNoCachedDataIsSkippable() {
        // Cast via Error existential so the `as?` check is not trivially true at compile time.
        let err: Error = CoreDashboardError.noCachedData(names: ["security"])
        XCTAssertNotNil(err as? SheetSkippable,
                        "CoreDashboardError.noCachedData must conform to SheetSkippable " +
                        "so absent jamf-cli snapshots are skipped, not flagged as failures")
    }

    // MARK: - SchoolDashboardError conforms to SheetSkippable

    func testSchoolDashboardNoCachedDataIsSkippable() {
        // Cast via Error existential so the `as?` check is not trivially true at compile time.
        let err: Error = SchoolDashboardError.noCachedData(names: ["school-devices"])
        XCTAssertNotNil(err as? SheetSkippable,
                        "SchoolDashboardError.noCachedData must conform to SheetSkippable " +
                        "so absent school snapshots are skipped, not flagged as failures")
    }
}

// MARK: - CoreDashboardWriteAllFailureTests

final class CoreDashboardWriteAllFailureTests: XCTestCase {

    // An empty dataDir means all write* methods throw CoreDashboardError.noCachedData.
    // Those are SheetSkippable — so failures should be empty even though nothing wrote.
    func testEmptyDataDirProducesNoFailures() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let workbook = Workbook()
        let dash = CoreDashboard(config: ReportConfig(), dataDir: tmp, workbook: workbook)
        let (_, failures) = dash.writeAll()

        XCTAssertTrue(failures.isEmpty,
                      "All noCachedData throws must be treated as skips, not failures")
    }
}

// MARK: - SchoolDashboardWriteAllFailureTests

final class SchoolDashboardWriteAllFailureTests: XCTestCase {

    // An empty dataDir means all school write* methods throw SchoolDashboardError.noCachedData.
    // These are SheetSkippable → written = [], failures = [].
    func testEmptyDataDirProducesNoFailures() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-school-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let workbook = Workbook()
        let dash = SchoolDashboard(config: ReportConfig(), dataDir: tmp, workbook: workbook)
        let (written, failures) = dash.writeAll()

        XCTAssertTrue(written.isEmpty)
        XCTAssertTrue(failures.isEmpty,
                      "noCachedData for school sheets must be treated as skips, not failures")
    }
}
