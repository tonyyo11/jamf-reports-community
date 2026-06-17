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
}
