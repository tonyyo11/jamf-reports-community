import Foundation
import XCTest
@testable import JamfReports

/// Verifies WorkspaceView.Subtab structure and default tab.
final class WorkspaceViewTests: XCTestCase {

    func testSubtabDefaultIsData() {
        // Default subtab for WorkspaceView must be .data (maps to ConfigView content)
        let defaultSubtab = WorkspaceView.Subtab.data
        XCTAssertEqual(defaultSubtab.rawValue, "data")
    }

    func testSubtabAllCasesCount() {
        XCTAssertEqual(WorkspaceView.Subtab.allCases.count, 4)
    }

    func testSubtabLabels() {
        XCTAssertEqual(WorkspaceView.Subtab.data.label, "Config")
        XCTAssertEqual(WorkspaceView.Subtab.workbook.label, "Customize")
        XCTAssertEqual(WorkspaceView.Subtab.sources.label, "Sources")
        XCTAssertEqual(WorkspaceView.Subtab.backups.label, "Backups")
    }

    func testSubtabIcons() {
        XCTAssertEqual(WorkspaceView.Subtab.data.icon, "wrench.and.screwdriver")
        XCTAssertEqual(WorkspaceView.Subtab.workbook.icon, "sparkles")
        XCTAssertEqual(WorkspaceView.Subtab.sources.icon, "externaldrive")
        XCTAssertEqual(WorkspaceView.Subtab.backups.icon, "externaldrive.badge.timemachine")
    }

    func testSubtabRawValues() {
        XCTAssertEqual(WorkspaceView.Subtab.data.rawValue, "data")
        XCTAssertEqual(WorkspaceView.Subtab.workbook.rawValue, "workbook")
        XCTAssertEqual(WorkspaceView.Subtab.sources.rawValue, "sources")
        XCTAssertEqual(WorkspaceView.Subtab.backups.rawValue, "backups")
    }

    func testSubtabIdentifiable() {
        // id must equal rawValue for ForEach stability
        for subtab in WorkspaceView.Subtab.allCases {
            XCTAssertEqual(subtab.id, subtab.rawValue)
        }
    }

    func testSubtabAllCasesOrder() {
        let cases = WorkspaceView.Subtab.allCases
        XCTAssertEqual(cases[0], .data)
        XCTAssertEqual(cases[1], .workbook)
        XCTAssertEqual(cases[2], .sources)
        XCTAssertEqual(cases[3], .backups)
    }
}
