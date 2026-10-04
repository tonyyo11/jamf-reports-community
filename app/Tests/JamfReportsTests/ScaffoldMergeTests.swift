import Foundation
import XCTest
@testable import JamfReports

/// `ScaffoldService.mergeColumns` is the non-destructive re-scaffold core: fill
/// empty mappings, keep valid ones, repair stale ones, flag unresolvable ones —
/// so re-running as the CSV changes over time never clobbers hand-tuned config.
final class ScaffoldMergeTests: XCTestCase {

    func testFillsEmptySlotsFromDetection() {
        let (merged, report) = ScaffoldService.mergeColumns(
            existing: ["computer_name": ""],
            detected: ["computer_name": "Computer Name"],
            csvHeaders: ["Computer Name"])
        XCTAssertEqual(merged["computer_name"], "Computer Name")
        XCTAssertEqual(report.added, ["computer_name"])
        XCTAssertEqual(report.keptCount, 0)
    }

    func testKeepsExistingValidMappingEvenIfDetectionDiffers() {
        // User hand-mapped to "Device Name"; the CSV still has it, and detection
        // guessed a different header — we must NOT clobber the user's choice.
        let (merged, report) = ScaffoldService.mergeColumns(
            existing: ["computer_name": "Device Name"],
            detected: ["computer_name": "Computer Name"],
            csvHeaders: ["Device Name", "Computer Name"])
        XCTAssertEqual(merged["computer_name"], "Device Name")
        XCTAssertEqual(report.keptCount, 1)
        XCTAssertTrue(report.added.isEmpty)
        XCTAssertTrue(report.repaired.isEmpty)
    }

    func testRepairsStaleMappingWhenColumnRenamedInCSV() {
        // The CSV no longer has "Serial" but now has "Serial Number"; detection
        // found the new header — repair the stale mapping.
        let (merged, report) = ScaffoldService.mergeColumns(
            existing: ["serial_number": "Serial"],
            detected: ["serial_number": "Serial Number"],
            csvHeaders: ["Serial Number"])
        XCTAssertEqual(merged["serial_number"], "Serial Number")
        XCTAssertEqual(report.repaired, ["serial_number"])
        XCTAssertEqual(report.keptCount, 0)
    }

    func testFlagsStaleMappingWithNoReplacement() {
        // Mapped header is gone and detection found nothing — keep it but flag it.
        let (merged, report) = ScaffoldService.mergeColumns(
            existing: ["email": "Old Email Field"],
            detected: [:],
            csvHeaders: ["Computer Name"])
        XCTAssertEqual(merged["email"], "Old Email Field", "kept so the user can fix it")
        XCTAssertEqual(report.staleUnresolved, ["email"])
        XCTAssertTrue(report.summary.contains("no longer"))
    }

    func testHeaderMatchIsCaseInsensitive() {
        let (_, report) = ScaffoldService.mergeColumns(
            existing: ["computer_name": "computer name"],
            detected: ["computer_name": "Computer Name"],
            csvHeaders: ["Computer Name"])
        XCTAssertEqual(report.keptCount, 1, "case-different header still counts as present")
        XCTAssertTrue(report.repaired.isEmpty)
    }

    // MARK: - mergeIntoConfig: the Config screen's re-scaffold, end to end

    private func workspace(config: String, csvHeaders: [String]) throws
        -> (root: URL, profile: String, csv: URL)
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScaffoldMergeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let profile = "rescaffold-\(UUID().uuidString.prefix(8).lowercased())"
        let configURL = try ConfigService.configURL(for: profile, workspaceRoot: root)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        let csv = root.appendingPathComponent("export.csv")
        try (csvHeaders.joined(separator: ",") + "\nrow\n")
            .write(to: csv, atomically: true, encoding: .utf8)
        return (root, profile, csv)
    }

    func testRescaffoldWritesADetectedExtraColumnAndReportsExactlyWhatWasWritten() throws {
        let ws = try workspace(
            config: "columns:\n  computer_name: Computer Name\n",
            csvHeaders: ["Computer Name", "Serial Number", "Building", "Purchase Date"])
        let outcome = try ScaffoldService.mergeIntoConfig(
            csvURL: ws.csv, profile: ws.profile, workspaceRoot: ws.root)

        XCTAssertEqual(Set(outcome.report.added), ["serial_number", "building"])
        XCTAssertEqual(outcome.report.keptCount, 1)

        let url = try ConfigService.configURL(for: ws.profile, workspaceRoot: ws.root)
        let columns = try XCTUnwrap(ConfigLoader.load(from: url).columns)
        XCTAssertEqual(columns.building, "Building")
        XCTAssertEqual(columns.serialNumber, "Serial Number")
        // purchase_date has no scaffold hint: it is never filled by a re-scaffold.
        XCTAssertNil(columns.purchaseDate)

        // What the report and the returned state describe is what a reload finds in the file.
        let reloaded = try ConfigService.load(profile: ws.profile, workspaceRoot: ws.root)
        XCTAssertEqual(reloaded.state.columns, outcome.state.columns)
    }

    /// The re-scaffold's save says what it left as typed and where the copy of the file is.
    func testRescaffoldReturnsItsSavesReport() throws {
        let ws = try workspace(
            config: "columns:\n  # mine\n  computer_name: Computer Name\n"
                + "custom_eas:\n  Battery:\n    column: Battery\n",
            csvHeaders: ["Computer Name", "Serial Number"])
        let outcome = try ScaffoldService.mergeIntoConfig(
            csvURL: ws.csv, profile: ws.profile, workspaceRoot: ws.root)

        XCTAssertEqual(outcome.saveReport.keptBlocks, ["custom_eas"])
        XCTAssertTrue(outcome.saveReport.droppedComments)
        XCTAssertNotNil(outcome.saveReport.backupName)
    }

    func testRescaffoldKeepsTheUsersMappingForAnExtraColumn() throws {
        let ws = try workspace(
            config: "columns:\n  computer_name: Computer Name\n  position: My Title Col\n",
            csvHeaders: ["Computer Name", "My Title Col", "Position"])
        let outcome = try ScaffoldService.mergeIntoConfig(
            csvURL: ws.csv, profile: ws.profile, workspaceRoot: ws.root)

        XCTAssertFalse(outcome.report.added.contains("position"), "not reported as filled")
        XCTAssertTrue(outcome.report.repaired.isEmpty)
        XCTAssertEqual(outcome.report.keptCount, 2, "computer_name and position are kept")
        XCTAssertEqual(outcome.state.columns["position"], "My Title Col")

        let url = try ConfigService.configURL(for: ws.profile, workspaceRoot: ws.root)
        XCTAssertEqual(try ConfigLoader.load(from: url).columns?.position, "My Title Col")
    }

    func testRescaffoldRepairsAnExtraColumnWhoseHeaderWasRenamed() throws {
        let ws = try workspace(
            config: "columns:\n  asset_tag: Old Tag\n",
            csvHeaders: ["Computer Name", "Asset Tag"])
        let outcome = try ScaffoldService.mergeIntoConfig(
            csvURL: ws.csv, profile: ws.profile, workspaceRoot: ws.root)

        XCTAssertEqual(outcome.report.repaired, ["asset_tag"])
        let url = try ConfigService.configURL(for: ws.profile, workspaceRoot: ws.root)
        XCTAssertEqual(try ConfigLoader.load(from: url).columns?.assetTag, "Asset Tag")
    }

    /// A config from before `model_identifier` existed, with the old `architecture` default:
    /// a re-scaffold on an export that has the Jamf headers fills the new key, repairs the
    /// architecture header and keeps `model`.
    func testRescaffoldFillsModelIdentifierAndRepairsArchitectureOnAnOlderConfig() throws {
        let ws = try workspace(
            config: "columns:\n  computer_name: Computer Name\n  model: Model\n"
                + "  architecture: Architecture\n",
            csvHeaders: ["Computer Name", "Model", "Model Identifier", "Architecture Type"])
        let outcome = try ScaffoldService.mergeIntoConfig(
            csvURL: ws.csv, profile: ws.profile, workspaceRoot: ws.root)

        XCTAssertEqual(outcome.report.added, ["model_identifier"])
        XCTAssertEqual(outcome.report.repaired, ["architecture"])
        XCTAssertEqual(outcome.report.keptCount, 2, "computer_name and model are kept")

        let url = try ConfigService.configURL(for: ws.profile, workspaceRoot: ws.root)
        let columns = try XCTUnwrap(ConfigLoader.load(from: url).columns)
        XCTAssertEqual(columns.model, "Model")
        XCTAssertEqual(columns.modelIdentifier, "Model Identifier")
        XCTAssertEqual(columns.architecture, "Architecture Type")
    }

    func testRescaffoldOfAMobileExportMergesMobileColumns() throws {
        let ws = try workspace(
            config: "columns:\n  computer_name: Computer Name\n",
            csvHeaders: ["Display Name", "Serial Number", "IMEI", "Building"])
        let outcome = try ScaffoldService.mergeIntoConfig(
            csvURL: ws.csv, profile: ws.profile, workspaceRoot: ws.root)

        XCTAssertEqual(outcome.familyLabel, "mobile device export")
        XCTAssertEqual(outcome.state.mobileColumns["device_name"], "Display Name")
        XCTAssertNil(outcome.state.columns["building"].flatMap { $0.isEmpty ? nil : $0 },
                     "a mobile export does not map computer columns")
    }

    func testRescaffoldMergesComplianceColumns() throws {
        let ws = try workspace(
            config: "columns:\n  computer_name: Computer Name\n",
            csvHeaders: ["Computer Name", "Gatekeeper", "Failed mSCP Results Count"])
        let outcome = try ScaffoldService.mergeIntoConfig(
            csvURL: ws.csv, profile: ws.profile, workspaceRoot: ws.root)

        XCTAssertEqual(outcome.familyLabel, "computer export")
        XCTAssertEqual(outcome.state.failuresCountColumn, "Failed mSCP Results Count")
        XCTAssertTrue(outcome.report.added.contains("failures_count_column"))
    }
}
