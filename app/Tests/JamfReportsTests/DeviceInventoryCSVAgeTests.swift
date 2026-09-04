import Foundation
import XCTest
@testable import JamfReports

/// A dropped inventory CSV is a point-in-time roster: it can never report a
/// check-in newer than the day it ran. These tests pin the bound that stops an
/// aged export being served as current inventory — the defect that showed 5
/// retired devices at 119 days on the Offline Outreach screen, four months
/// after the export.
final class DeviceInventoryCSVAgeTests: XCTestCase {

    private let day: TimeInterval = 86_400

    private func date(_ ymd: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ymd)!
    }

    // MARK: - Export date

    /// The load-bearing case. 2.7.0 ships workspaces on synced storage, where a
    /// provider restamps mtime when it materializes a file — so a months-old
    /// export downloads as "modified today". If mtime won, the bound would be
    /// inert on exactly the deployment it exists to protect.
    func testFilenameStampBeatsModificationTime() {
        let resolved = DeviceInventoryService.inventoryCSVExportDate(
            filename: "automation_inventory_config_2026_04_28_090007_2026-04-28_090526.csv",
            modified: date("2026-08-25")
        )
        XCTAssertEqual(resolved, date("2026-04-28"),
                       "filename stamp must win; a restamped mtime hides a stale export")
    }

    /// Export names carry a config stamp ahead of the run stamp, so the LAST
    /// stamp is the run. Taking the first would be right here by luck and wrong
    /// whenever the two dates differ.
    func testLastStampWinsWhenNameCarriesTwoDates() {
        XCTAssertEqual(
            DeviceInventoryService.lastDateStamp(
                in: "automation_inventory_config_2026_01_02_090007_2026-04-28_090526.csv"
            ),
            date("2026-04-28")
        )
    }

    func testModificationTimeUsedWhenFilenameCarriesNoStamp() {
        XCTAssertEqual(
            DeviceInventoryService.inventoryCSVExportDate(
                filename: "inventory.csv", modified: date("2026-08-01")
            ),
            date("2026-08-01")
        )
    }

    func testGarbageStampDoesNotParseAsADate() {
        XCTAssertNil(DeviceInventoryService.lastDateStamp(in: "report_1234-56-78_x.csv"))
    }

    // MARK: - Currency verdict

    func testExportPastStaleThresholdIsNotCurrent() {
        XCTAssertFalse(
            DeviceInventoryService.inventoryCSVIsCurrent(
                exportDate: date("2026-04-28"), now: date("2026-08-25"), staleDeviceDays: 30
            ),
            "119 days old at a 30-day threshold must not be served as current inventory"
        )
    }

    func testExportOnTheThresholdIsStillCurrent() {
        // Boundary: exactly `staleDeviceDays` old is inside the window. A device
        // at exactly the threshold is not yet stale, so the file that reports it
        // is not yet useless.
        let now = date("2026-08-25")
        XCTAssertTrue(
            DeviceInventoryService.inventoryCSVIsCurrent(
                exportDate: now.addingTimeInterval(-30 * day), now: now, staleDeviceDays: 30
            )
        )
        XCTAssertFalse(
            DeviceInventoryService.inventoryCSVIsCurrent(
                exportDate: now.addingTimeInterval(-31 * day), now: now, staleDeviceDays: 30
            )
        )
    }

    /// The bound scales with the org's own threshold rather than a new number:
    /// the same file that is useless at 30 days is legitimate at 180.
    func testBoundFollowsTheConfiguredThreshold() {
        XCTAssertTrue(
            DeviceInventoryService.inventoryCSVIsCurrent(
                exportDate: date("2026-04-28"), now: date("2026-08-25"), staleDeviceDays: 180
            )
        )
    }

    func testUnknownExportDateFailsTowardLoading() {
        // No stamp and no mtime: we cannot judge it, so we must not silently
        // discard data the operator placed there deliberately.
        XCTAssertTrue(
            DeviceInventoryService.inventoryCSVIsCurrent(
                exportDate: nil, now: date("2026-08-25"), staleDeviceDays: 30
            )
        )
    }

    func testDisabledThresholdAppliesNoBound() {
        XCTAssertTrue(
            DeviceInventoryService.inventoryCSVIsCurrent(
                exportDate: date("2020-01-01"), now: date("2026-08-25"), staleDeviceDays: 0
            )
        )
    }

    func testFutureStampReadsAsCurrentNotInfinitelyStale() {
        // Clock skew across machines sharing a workspace must not make a file
        // look ancient. Negative age is current.
        XCTAssertTrue(
            DeviceInventoryService.inventoryCSVIsCurrent(
                exportDate: date("2026-09-01"), now: date("2026-08-25"), staleDeviceDays: 30
            )
        )
    }

    // MARK: - End to end

    /// The reported defect, reproduced against a real workspace: an aged
    /// csv-inbox export must not contribute devices, and the operator must be
    /// told why rather than left with a silently different device list.
    func testAgedInboxCSVIsSkippedAndExplained() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jrc-csvage-\(UUID().uuidString)", isDirectory: true)
        let profile = "csvage"
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        let inbox = workspace.appendingPathComponent("csv-inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }

        // Dated four years back so the file is aged out under any plausible
        // configured threshold, without depending on today's date.
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date().addingTimeInterval(-1_460 * day))
        }()
        let csv = inbox.appendingPathComponent("automation_inventory_\(stamp)_090526.csv")
        try """
        Serial Number,Computer Name,Last Check-in
        RETIRED001,Retired Mac,2022-01-01
        """.write(to: csv, atomically: true, encoding: .utf8)

        let snapshot = DeviceInventoryService.load(profile: profile, demoMode: false)

        XCTAssertTrue(snapshot.devices.isEmpty,
                      "an aged export must not resurrect devices the fleet has retired")
        XCTAssertTrue(
            snapshot.warnings.contains { $0.contains(csv.lastPathComponent) },
            "the skip must name the ignored file — an ignored drop-file is never silent"
        )
        XCTAssertFalse(
            snapshot.sourceFiles.contains { $0.contains(csv.lastPathComponent) },
            "a file we refused to read must not be listed as a source"
        )
    }
}
