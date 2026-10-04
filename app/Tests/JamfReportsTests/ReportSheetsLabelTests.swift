import XCTest
@testable import JamfReports

final class ReportSheetsLabelTests: XCTestCase {

    private func report(_ name: String, sheets: Int) -> Report {
        Report(name: name, size: "1 MB", date: "Sep 3, 08:12", source: "Weekly",
               sheets: sheets, devices: nil)
    }

    func testOnlyAWorkbookHasASheetCount() {
        XCTAssertEqual(report("report_lab_2026-09-03_081200.xlsx", sheets: 14).sheetsLabel, "14")
        XCTAssertEqual(report("report_lab_2026-09-03_081200.XLSX", sheets: 14).sheetsLabel, "14")
        for name in ["report_lab_2026-09-03.html", "report_lab_2026-09-03.pdf",
                     "devices-lab-2026-09-03_081200.csv"] {
            XCTAssertEqual(report(name, sheets: 0).sheetsLabel, "—", name)
        }
    }

    func testVoiceOverNamesSheetsOnlyForAWorkbook() {
        XCTAssertEqual(report("a.xlsx", sheets: 1).accessibilityLabel, "a.xlsx, 1 sheet, 1 MB")
        XCTAssertEqual(report("a.xlsx", sheets: 12).accessibilityLabel, "a.xlsx, 12 sheets, 1 MB")
        XCTAssertEqual(report("a.html", sheets: 0).accessibilityLabel, "a.html, 1 MB")
    }
}
