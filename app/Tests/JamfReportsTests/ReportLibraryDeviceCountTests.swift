import Foundation
import XCTest
@testable import JamfReports

final class ReportLibraryDeviceCountTests: XCTestCase {

    private var tempDir: URL!
    private var summariesDir: URL!
    private let library = ReportLibrary()

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportLibraryDeviceCountTests-\(UUID().uuidString)", isDirectory: true)
        summariesDir = tempDir.appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - totalDevices as Int

    func testDeviceCountFromSummaryWithIntTotalDevices() throws {
        let summary: [String: Any] = ["totalDevices": 247, "status": "ok"]
        try writeSummary(date: "2024-05-29", json: summary)

        let reportURL = URL(fileURLWithPath: "report_main_2024-05-29_143022.xlsx")
        let result = library.deviceCount(forReportURL: reportURL, summariesDir: summariesDir)

        XCTAssertEqual(result, 247)
    }

    // MARK: - totalDevices as Double (JSON numbers can decode as Double)

    func testDeviceCountFromSummaryWithDoubleTotalDevices() throws {
        // Simulate a JSON serializer that writes the number as Double
        let summary: [String: Any] = ["totalDevices": Double(524), "status": "ok"]
        try writeSummary(date: "2024-06-01", json: summary)

        let reportURL = URL(fileURLWithPath: "report_prod_2024-06-01_060000.xlsx")
        let result = library.deviceCount(forReportURL: reportURL, summariesDir: summariesDir)

        XCTAssertEqual(result, 524)
    }

    // MARK: - Missing summary → nil

    func testDeviceCountReturnsNilWhenSummaryFileMissing() {
        let reportURL = URL(fileURLWithPath: "report_main_2024-05-30_143022.xlsx")
        let result = library.deviceCount(forReportURL: reportURL, summariesDir: summariesDir)

        XCTAssertNil(result)
    }

    // MARK: - Filename without date → nil

    func testDeviceCountReturnsNilWhenFilenameHasNoDate() throws {
        let summary: [String: Any] = ["totalDevices": 100]
        try writeSummary(date: "2024-05-29", json: summary)

        let reportURL = URL(fileURLWithPath: "report_nodatestamp.xlsx")
        let result = library.deviceCount(forReportURL: reportURL, summariesDir: summariesDir)

        XCTAssertNil(result)
    }

    // MARK: - Non-numeric totalDevices → nil

    func testDeviceCountReturnsNilWhenTotalDevicesIsString() throws {
        let summary: [String: Any] = ["totalDevices": "not-a-number"]
        try writeSummary(date: "2024-07-10", json: summary)

        let reportURL = URL(fileURLWithPath: "report_main_2024-07-10_080000.xlsx")
        let result = library.deviceCount(forReportURL: reportURL, summariesDir: summariesDir)

        XCTAssertNil(result)
    }

    // MARK: - Missing totalDevices key → nil

    func testDeviceCountReturnsNilWhenTotalDevicesKeyAbsent() throws {
        let summary: [String: Any] = ["status": "ok", "managedDevices": 100]
        try writeSummary(date: "2024-08-15", json: summary)

        let reportURL = URL(fileURLWithPath: "report_main_2024-08-15_090000.xlsx")
        let result = library.deviceCount(forReportURL: reportURL, summariesDir: summariesDir)

        XCTAssertNil(result)
    }

    // MARK: - Report.devices field is Int?

    func testReportDevicesFieldIsOptional() {
        let withCount = Report(
            name: "test_2024-01-01.xlsx", size: "1 MB", date: "Jan 1", source: "Test",
            sheets: 5, devices: 100
        )
        let withoutCount = Report(
            name: "test_no_summary.xlsx", size: "1 MB", date: "Jan 1", source: "Test",
            sheets: 5, devices: nil
        )

        XCTAssertEqual(withCount.devices, 100)
        XCTAssertNil(withoutCount.devices)
    }

    // MARK: - Helpers

    private func writeSummary(date: String, json: [String: Any]) throws {
        let url = summariesDir.appendingPathComponent("summary_\(date).json")
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: url)
    }
}
