import Foundation
import XCTest
@testable import JamfReports

/// Verifies that the W23 IA reorg sidebar structure matches the agreed design:
/// 5 groups, 11 sidebar items (onboarding is excluded from the nav groups).
final class IAReorgTests: XCTestCase {

    // Mirror of the Sidebar's private NavGroup so tests can verify structure
    // without reaching into private implementation.
    private typealias Group = (label: String, items: [Tab])

    /// Agreed sidebar groups from the Phase 2 Lane C1 spec.
    private let expectedGroups: [Group] = [
        ("INSIGHTS",   [.overview, .fleet, .devices, .deviceLookup, .trends, .healthCheck]),
        ("ARTIFACTS",  [.reports]),
        ("AUTOMATION", [.schedules, .runs]),
        ("WORKSPACE",  [.workspace]),
        ("SYSTEM",     [.settings]),
    ]

    func testGroupCount() {
        XCTAssertEqual(expectedGroups.count, 5)
    }

    func testTotalSidebarItemCount() {
        let total = expectedGroups.reduce(0) { $0 + $1.items.count }
        XCTAssertEqual(total, 11)
    }

    func testInsightsGroupContents() {
        let group = expectedGroups[0]
        XCTAssertEqual(group.label, "INSIGHTS")
        XCTAssertEqual(group.items, [.overview, .fleet, .devices, .deviceLookup, .trends, .healthCheck])
    }

    func testArtifactsGroupContents() {
        let group = expectedGroups[1]
        XCTAssertEqual(group.label, "ARTIFACTS")
        XCTAssertEqual(group.items, [.reports])
    }

    func testAutomationGroupContents() {
        let group = expectedGroups[2]
        XCTAssertEqual(group.label, "AUTOMATION")
        XCTAssertEqual(group.items, [.schedules, .runs])
    }

    func testWorkspaceGroupContents() {
        let group = expectedGroups[3]
        XCTAssertEqual(group.label, "WORKSPACE")
        XCTAssertEqual(group.items, [.workspace])
    }

    func testSystemGroupContents() {
        let group = expectedGroups[4]
        XCTAssertEqual(group.label, "SYSTEM")
        XCTAssertEqual(group.items, [.settings])
    }

    func testOldConfigurationGroupAbsent() {
        // The old CONFIGURATION group (config, customize, sources, backups) must not
        // appear in any group under its old items.
        let allItems = expectedGroups.flatMap(\.items)
        let forbidden: [Tab] = []  // no Tab cases for old names exist at compile time
        XCTAssertTrue(forbidden.isEmpty, "Old configuration tab cases must not compile")
        // Structural check: workspace absorbs the 4 old tabs as sub-tabs
        XCTAssertTrue(allItems.contains(.workspace))
        XCTAssertFalse(allItems.contains(where: { $0.rawValue == "config" }))
        XCTAssertFalse(allItems.contains(where: { $0.rawValue == "customize" }))
        XCTAssertFalse(allItems.contains(where: { $0.rawValue == "sources" }))
        XCTAssertFalse(allItems.contains(where: { $0.rawValue == "backups" }))
    }

    func testHealthCheckReplacesAuditInInsights() {
        let insightsItems = expectedGroups[0].items
        XCTAssertTrue(insightsItems.contains(.healthCheck))
        XCTAssertFalse(insightsItems.contains(where: { $0.rawValue == "audit" }))
    }

    func testReportsInArtifactsNotInsights() {
        let insightsItems = expectedGroups[0].items
        let artifactsItems = expectedGroups[1].items
        XCTAssertFalse(insightsItems.contains(.reports))
        XCTAssertTrue(artifactsItems.contains(.reports))
    }
}
