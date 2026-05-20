import Foundation
import XCTest
@testable import JamfReports

/// Verifies that the W23 IA reorg tab renames landed correctly and that the old
/// tab case names no longer exist in the enum.
final class TabRenameTests: XCTestCase {

    func testHealthCheckCaseExists() {
        // .healthCheck must be a valid Tab case (compile-time proof via allCases)
        XCTAssertTrue(Tab.allCases.contains(.healthCheck))
    }

    func testReportsCaseExists() {
        XCTAssertTrue(Tab.allCases.contains(.reports))
    }

    func testWorkspaceCaseExists() {
        XCTAssertTrue(Tab.allCases.contains(.workspace))
    }

    func testHealthCheckLabel() {
        XCTAssertEqual(Tab.healthCheck.label, "Health Check")
    }

    func testReportsLabel() {
        XCTAssertEqual(Tab.reports.label, "Reports")
    }

    func testWorkspaceLabel() {
        XCTAssertEqual(Tab.workspace.label, "Workspace")
    }

    func testOldConfigCaseAbsent() {
        // .config, .customize, .sources, .backups are absorbed into .workspace
        let rawValues = Tab.allCases.map(\.rawValue)
        XCTAssertFalse(rawValues.contains("config"), ".config should no longer exist")
        XCTAssertFalse(rawValues.contains("customize"), ".customize should no longer exist")
        XCTAssertFalse(rawValues.contains("sources"), ".sources should no longer exist")
        XCTAssertFalse(rawValues.contains("backups"), ".backups should no longer exist")
    }

    func testOldAuditCaseAbsent() {
        // .audit was renamed to .healthCheck
        let rawValues = Tab.allCases.map(\.rawValue)
        XCTAssertFalse(rawValues.contains("audit"), ".audit should no longer exist")
    }

    func testHealthCheckSFSymbol() {
        XCTAssertEqual(Tab.healthCheck.sfSymbol, "shield.checkered")
    }

    func testWorkspaceSFSymbol() {
        XCTAssertEqual(Tab.workspace.sfSymbol, "wrench.and.screwdriver")
    }

    func testTotalTabCount() {
        // 11 sidebar items + onboarding (not in sidebar) = 12 total cases
        // overview, fleet, devices, deviceLookup, trends, healthCheck, reports,
        // schedules, runs, workspace, settings, onboarding
        XCTAssertEqual(Tab.allCases.count, 12)
    }
}
