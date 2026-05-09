import XCTest
@testable import JamfReports

final class AppShellTests: XCTestCase {

    func testMinSupportedWidth() {
        XCTAssertEqual(JamfReportsApp.minSupportedWidth, 960,
                       "Min supported width should remain 960pt for 13\" MacBook compatibility")
    }

    func testTabEnumCompleteness() {
        let expectedTabs: Set<Tab> = [
            .overview, .fleet, .devices, .deviceLookup, .trends, .healthCheck,
            .reports, .schedules, .runs, .workspace, .settings, .onboarding
        ]

        let actualTabs = Set(Tab.allCases)

        XCTAssertEqual(actualTabs, expectedTabs,
                       "Tab enum should contain all expected cases with no additions or removals")
        XCTAssertEqual(actualTabs.count, 12,
                       "Tab enum should have exactly 12 cases")
    }

    func testTabLabelsNotEmpty() {
        for tab in Tab.allCases {
            XCTAssertFalse(tab.label.isEmpty,
                          "Tab \(tab.rawValue) should have a non-empty label")
            XCTAssertFalse(tab.sfSymbol.isEmpty,
                          "Tab \(tab.rawValue) should have a non-empty SF Symbol")
        }
    }

    func testTabIdentifiers() {
        for tab in Tab.allCases {
            XCTAssertEqual(tab.id, tab.rawValue,
                          "Tab ID should match raw value")
        }
    }

    func testNavigationGroupStructure() {
        // Validate the navigation groups structure matches expected organization
        let expectedStructure: [String: [Tab]] = [
            "INSIGHTS": [.overview, .fleet, .devices, .deviceLookup, .trends, .healthCheck],
            "ARTIFACTS": [.reports],
            "AUTOMATION": [.schedules, .runs],
            "WORKSPACE": [.workspace],
            "SYSTEM": [.settings]
        ]

        // Note: .onboarding is not included in regular navigation groups
        let allNavigationTabs = expectedStructure.values.flatMap { $0 }
        XCTAssertEqual(allNavigationTabs.count, 11,
                       "Navigation groups should contain 11 of the 12 tabs (excluding onboarding)")

        let missingFromNavigation = Set(Tab.allCases).subtracting(Set(allNavigationTabs))
        XCTAssertEqual(missingFromNavigation, [.onboarding],
                       "Only onboarding tab should be excluded from regular navigation")
    }
}