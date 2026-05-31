import Testing
@testable import JamfReports

@MainActor
final class ReportsFilterTests {
    private let sampleReports = [
        Report(name: "jamf_report_main_2024-05-01.xlsx", size: "1.2 MB", date: "May 1, 09:15", source: "Weekly Executive", sheets: 15, devices: 247),
        Report(name: "compliance_main_2024-05-02.html", size: "850 KB", date: "May 2, 14:30", source: "Monthly Compliance", sheets: 0, devices: 247),
        Report(name: "inventory_export_2024-05-03.csv", size: "2.1 MB", date: "May 3, 08:45", source: "Inventory Export", sheets: 0, devices: 247),
        Report(name: "mobile_devices_2024-05-04.pdf", size: "650 KB", date: "May 4, 16:20", source: "Mobile Inventory", sheets: 0, devices: 82),
        Report(name: "school_report_edu_2024-05-05.xlsx", size: "900 KB", date: "May 5, 11:10", source: "Jamf School", sheets: 8, devices: 150)
    ]

    @Test func emptySearchReturnsAll() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "",
            profileFilter: nil
        )
        #expect(filtered == sampleReports)
    }

    @Test func whitespaceSearchReturnsAll() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "   ",
            profileFilter: nil
        )
        #expect(filtered == sampleReports)
    }

    @Test func searchByNameExactMatch() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "compliance_main_2024-05-02.html",
            profileFilter: nil
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.name == "compliance_main_2024-05-02.html")
    }

    @Test func searchByNamePartialMatch() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "compliance",
            profileFilter: nil
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.name == "compliance_main_2024-05-02.html")
    }

    @Test func searchCaseInsensitive() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "JAMF_REPORT",
            profileFilter: nil
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.name == "jamf_report_main_2024-05-01.xlsx")
    }

    @Test func searchBySource() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "Weekly Executive",
            profileFilter: nil
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.source == "Weekly Executive")
    }

    @Test func searchMultipleMatches() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "2024-05",
            profileFilter: nil
        )
        #expect(filtered.count == 5)
    }

    @Test func searchNoMatches() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "nonexistent",
            profileFilter: nil
        )
        #expect(filtered.isEmpty)
    }

    @Test func profileFilterExact() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "",
            profileFilter: "main"
        )
        #expect(filtered.count == 2)
        #expect(filtered.allSatisfy { $0.name.contains("main") })
    }

    @Test func profileFilterCaseInsensitive() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "",
            profileFilter: "EDU"
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.name.contains("edu") == true)
    }

    @Test func profileFilterNoMatches() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "",
            profileFilter: "nonexistent"
        )
        #expect(filtered.isEmpty)
    }

    @Test func searchAndProfileFilterCombined() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "xlsx",
            profileFilter: "main"
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.name == "jamf_report_main_2024-05-01.xlsx")
    }

    @Test func searchAndProfileFilterNoMatches() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "xlsx",
            profileFilter: "edu"
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.name.contains("school_report_edu") == true)
    }
}