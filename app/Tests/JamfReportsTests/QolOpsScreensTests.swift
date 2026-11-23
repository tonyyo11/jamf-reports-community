import XCTest
@testable import JamfReports

/// The tiles that open a filter count the same items the filter shows (2.12).
@MainActor
final class QolOpsScreensTests: XCTestCase {

    private func row(_ title: String, onLatest: Int, total: Int) -> PatchStatusRow {
        PatchStatusRow(
            title: title, id: title, onLatest: onLatest, onOther: max(total - onLatest, 0),
            total: total, latest: "1.0", compliancePct: "")
    }

    func testPatchTileFiltersListWhatTheTilesCount() {
        let sets = [
            DemoData.patchStatus.titles,
            [row("A", onLatest: 90, total: 100), row("B", onLatest: 49, total: 100),
             row("C", onLatest: 50, total: 100), row("D", onLatest: 0, total: 0),
             row("E", onLatest: 100, total: 100)],
        ]
        for titles in sets {
            let snapshot = PatchStatusService.Snapshot(
                titles: titles, failures: [], sourceFile: nil, snapshotDate: nil)
            XCTAssertEqual(PatchView.titles(titles, in: .compliant).count,
                           snapshot.compliantTitleCount)
            XCTAssertEqual(PatchView.titles(titles, in: .failing).count,
                           snapshot.failingTitleCount)
            XCTAssertEqual(PatchView.titles(titles, in: nil).count, titles.count)
        }
    }

    func testPatchPNGExportIsCappedAtTwelveRows() {
        XCTAssertEqual(PatchView.pngExportRowCap, 12)
    }

    func testSchoolDeviceFiltersListWhatTheTilesCount() {
        let snapshot = DemoData.schoolSnapshot
        let now = DemoData.referenceDate
        let days = 30
        func count(_ filter: SchoolDevicesView.Filter) -> Int {
            SchoolDevicesView.filtered(
                snapshot.devices, filter: filter, query: "", staleDays: days, now: now).count
        }
        XCTAssertEqual(count(.all), snapshot.devices.count)
        XCTAssertEqual(count(.managed), snapshot.managed?.met)
        XCTAssertEqual(count(.supervised), snapshot.supervised?.met)
        XCTAssertEqual(count(.stale), snapshot.staleCount(atDays: days, now: now))
    }

    func testJailbreakTileFilterListsWhatTheTileCounts() throws {
        let json = """
        [{"mobileDeviceId": "1", "deviceType": "iOS", "general": {"managed": true,
          "supervised": true, "jailbreakDetected": "Detected", "serialNumber": "A"}},
         {"mobileDeviceId": "2", "deviceType": "iOS", "general": {"managed": true,
          "supervised": true, "jailbreakDetected": "None", "serialNumber": "B"}}]
        """
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qol-mobile-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = MobileFleetService.load(listURL: nil, inventoryURL: url, profilesURL: nil)
        let context = snapshot.findingContext(staleDays: 30, now: Date())
        XCTAssertEqual(
            snapshot.devices(snapshot.richDevices, affectedBy: .jailbreak, context: context).count,
            snapshot.jailbreakDetectedCount)
    }
}
