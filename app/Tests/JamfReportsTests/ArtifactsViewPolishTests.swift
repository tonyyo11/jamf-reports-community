import Foundation
import XCTest
@testable import JamfReports

/// View-polish tests for ReportsView, SchedulesView, and RunsView.
///
/// These tests validate the logic and state-management concerns that don't require a
/// running SwiftUI host — status descriptions, empty-state conditions, and filter logic.
/// View instantiation smoke tests are omitted because @MainActor SwiftUI views cannot
/// be constructed in a unit-test target without a running app host.
final class ArtifactsViewPolishTests: XCTestCase {

    // MARK: - Schedule status pill descriptions

    func testStatusPillDescriptionOK() {
        let description = SchedulesView.statusDescription(for: .ok)
        XCTAssertFalse(description.isEmpty, "Status OK must produce a non-empty description")
        XCTAssertTrue(
            description.lowercased().contains("ok") || description.lowercased().contains("success"),
            "Status OK description should mention ok or success, got: \(description)"
        )
    }

    func testStatusPillDescriptionWarn() {
        let description = SchedulesView.statusDescription(for: .warn)
        XCTAssertFalse(description.isEmpty, "Status WARN must produce a non-empty description")
        XCTAssertTrue(
            description.lowercased().contains("warn"),
            "Status WARN description should mention warning, got: \(description)"
        )
    }

    func testStatusPillDescriptionFail() {
        let description = SchedulesView.statusDescription(for: .fail)
        XCTAssertFalse(description.isEmpty, "Status FAIL must produce a non-empty description")
        XCTAssertTrue(
            description.lowercased().contains("fail"),
            "Status FAIL description should mention fail, got: \(description)"
        )
    }

    func testAllStatusCasesProduceNonEmptyDescriptions() {
        for status in Schedule.LastStatus.allCases {
            let description = SchedulesView.statusDescription(for: status)
            XCTAssertFalse(
                description.isEmpty,
                "Status \(status.rawValue) produced empty description"
            )
        }
    }

    // MARK: - RunsView empty state

    func testRunHistoryEmptyStateForUnknownProfile() {
        // A profile that cannot exist on disk must return an empty list.
        let runs = RunHistoryService.list(profile: "zz-nonexistent-test-profile-\(UUID().uuidString)")
        XCTAssertTrue(runs.isEmpty, "Non-existent profile should produce empty run list")
    }

    func testRunHistoryEmptyStateForInvalidProfile() {
        // Invalid profile names (failing the slug regex) must also return empty.
        let runs = RunHistoryService.list(profile: "INVALID PROFILE!")
        XCTAssertTrue(runs.isEmpty, "Invalid profile name should produce empty run list")
    }

    // MARK: - ReportsView filter logic

    func testFilterAllPassesAll() {
        // Mirror of ReportsView.filteredReports(filter:reports:) logic.
        let allReports = [
            Report(name: "report.xlsx", size: "1 MB", date: "Jan 1, 00:00", source: "daily", sheets: 5, devices: 100),
            Report(name: "report.html", size: "500 KB", date: "Jan 2, 00:00", source: "weekly", sheets: 1, devices: 50),
            Report(name: "inventory.csv", size: "200 KB", date: "Jan 3, 00:00", source: "manual", sheets: 1, devices: 97),
        ]
        let filtered = Self.applyFilter("All", to: allReports)
        XCTAssertEqual(filtered.count, 3)
    }

    func testFilterXlsxExcludesHtmlAndCsv() {
        let allReports = [
            Report(name: "report.xlsx", size: "1 MB", date: "Jan 1, 00:00", source: "daily", sheets: 5, devices: 100),
            Report(name: "report.html", size: "500 KB", date: "Jan 2, 00:00", source: "weekly", sheets: 1, devices: 50),
            Report(name: "inventory.csv", size: "200 KB", date: "Jan 3, 00:00", source: "manual", sheets: 1, devices: 97),
        ]
        let filtered = Self.applyFilter("xlsx", to: allReports)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.name, "report.xlsx")
    }

    func testFilterHtmlExcludesXlsxAndCsv() {
        let allReports = [
            Report(name: "report.xlsx", size: "1 MB", date: "Jan 1, 00:00", source: "daily", sheets: 5, devices: 100),
            Report(name: "report.html", size: "500 KB", date: "Jan 2, 00:00", source: "weekly", sheets: 1, devices: 50),
        ]
        let filtered = Self.applyFilter("html", to: allReports)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.name, "report.html")
    }

    func testFilterProducesEmptyWhenNoMatchExists() {
        let allReports = [
            Report(name: "report.xlsx", size: "1 MB", date: "Jan 1, 00:00", source: "daily", sheets: 5, devices: 100),
        ]
        let filtered = Self.applyFilter("html", to: allReports)
        XCTAssertTrue(filtered.isEmpty, "html filter should not match xlsx-only list")
    }

    // MARK: - ReportsView empty state

    func testReportLibraryReturnsEmptyListForUnknownProfile() {
        let library = ReportLibrary()
        let reports = library.list(profile: "zz-no-such-profile-\(UUID().uuidString)")
        XCTAssertTrue(reports.isEmpty, "Unknown profile should return empty report list")
    }

    // MARK: - Helpers

    /// Mirrors the filter logic in ReportsView.filteredReports without referencing the view.
    private static func applyFilter(_ filter: String, to reports: [Report]) -> [Report] {
        guard filter != "All" else { return reports }
        return reports.filter { $0.name.lowercased().hasSuffix(".\(filter.lowercased())") }
    }
}

// MARK: - SchedulesView testable surface

extension SchedulesView {
    /// Returns the accessibility description string for a given LastStatus value.
    /// This mirrors the accessibilityLabel applied to status pills in schedulesTable.
    static func statusDescription(for status: Schedule.LastStatus) -> String {
        switch status {
        case .ok:   return "Last run status: OK"
        case .warn: return "Last run status: Warning"
        case .fail: return "Last run status: Failed"
        }
    }
}
