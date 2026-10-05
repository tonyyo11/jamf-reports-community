import Testing
@testable import JamfReports

@MainActor
final class ReportsFilterTests {
    private let sampleReports = [
        Report(name: "jamf_report_main_2024-05-01.xlsx", size: "1.2 MB", date: "May 1, 09:15", source: "Weekly Executive", sheets: 15, devices: 247),
        Report(name: "report_main_2024-05-02.html", size: "850 KB", date: "May 2, 14:30", source: "Monthly Compliance", sheets: 0, devices: 247),
        Report(name: "inventory_export_2024-05-03.csv", size: "2.1 MB", date: "May 3, 08:45", source: "Inventory Export", sheets: 0, devices: 247),
        Report(name: "mobile_devices_2024-05-04.pdf", size: "650 KB", date: "May 4, 16:20", source: "Mobile Inventory", sheets: 0, devices: 82),
        Report(name: "school-report_edu_2024-05-05.xlsx", size: "900 KB", date: "May 5, 11:10", source: "Jamf School", sheets: 8, devices: 150)
    ]

    private func profile(_ filename: String) -> String? {
        ReportsView.profile(fromReportFilename: filename)
    }

    @Test func profileFromFilenameKeepsHyphensAndUnderscores() {
        #expect(profile("report_meridian-prod_2026-04-24_073305.xlsx") == "meridian-prod")
        #expect(profile("report_acme_east_2026-04-24_073305.html") == "acme_east")
        #expect(profile("jamf_report_main_2024-05-01.xlsx") == "main")
        #expect(profile("school-report_edu_2024-05-05.xlsx") == "edu")
        #expect(profile("report_prod.xlsx") == "prod")
    }

    @Test func profileFromFilenameRejectsDatesAndUnknownPrefixes() {
        #expect(profile("report_2026-04-24_073305.xlsx") == nil)
        #expect(profile("report_20260424.xlsx") == nil)
        #expect(profile("fleet-bands-prod-2026-04-24_073305.png") == nil)
        #expect(profile("devices-2026-04-24_073305.csv") == nil)
    }

    /// The prefixes are the ones the writers use (`ExportNaming.stem`), so every generated
    /// report reads back its profile and a name no writer makes reads as none.
    @Test func profileFromFilenameFollowsTheWritersNames() {
        for type in GenerateOutputType.allCases {
            for school in [false, true] {
                let stem = ExportNaming.stem(for: type, profile: "acme-dev", schoolMode: school)
                #expect(profile(stem + "_2026-10-04_120000.xlsx") == "acme-dev", "\(stem)")
            }
        }
        #expect(profile("compliance_main_2024-05-02.html") == nil)
        #expect(profile("mobile_devices_2024-05-04.pdf") == nil)
        #expect(profile("school_report_edu_2024-05-05.xlsx") == nil)
    }

    /// `ExportNaming` files saved into a reports folder: `<kind>-<profile>-<timestamp>`.
    @Test func profileFromExportNamingFiles() {
        #expect(profile("patch-compliance-prod-2026-04-24_073305.csv") == "prod")
        #expect(profile("devices-acme-dev-2026-09-29_120000.csv") == "acme-dev")
        #expect(profile("outreach-stale-devices-Acme-2026-09-29_120000.csv") == "Acme")
        #expect(profile("audit-findings-acme_east-2026-09-29_120000.csv") == "acme_east")
        #expect(profile("period-report-20260601-20260831-acme-2026-09-29_120000.xlsx") == "acme")
    }

    /// From 2.8.3 file names carry any jamf-cli name, encoded only where a file name can't hold
    /// it (`ProfileName.pathComponent`), so the name reads back exactly.
    @Test func profileFromFilenameDecodesAnyName() {
        #expect(profile("report_Acme Prod_2026-09-29_120000.xlsx") == "Acme Prod")
        #expect(profile("jamf_report_acme.prod_2026-09-29_120000.html") == "acme.prod")
        #expect(profile("report_Zürich_2026-09-29_120000.xlsx") == "Zürich")
        #expect(profile("report_a%2Fb_2026-09-29_120000.xlsx") == "a/b")
        #expect(profile("devices-R&D (EU)-2026-09-29_120000.csv") == "R&D (EU)")
        #expect(profile("report_2024_2026-09-29_120000.xlsx") == "2024", "an all-digit name")
        #expect(profile("report_x_2024-01-01_2026-09-29_120000.xlsx") == "x_2024-01-01",
                "the last date is the timestamp")
        #expect(profile("report_100%_2026-09-29_120000.xlsx") == nil, "no name encodes to 100%")
    }

    @Test func emptySearchReturnsAll() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "",
            profileFilter: []
        )
        #expect(filtered == sampleReports)
    }

    @Test func whitespaceSearchReturnsAll() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "   ",
            profileFilter: []
        )
        #expect(filtered == sampleReports)
    }

    @Test func searchByNameExactMatch() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "report_main_2024-05-02.html",
            profileFilter: []
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.name == "report_main_2024-05-02.html")
    }

    @Test func searchByNamePartialMatch() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "compliance",
            profileFilter: []
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.name == "report_main_2024-05-02.html")
    }

    @Test func searchCaseInsensitive() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "JAMF_REPORT",
            profileFilter: []
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.name == "jamf_report_main_2024-05-01.xlsx")
    }

    @Test func searchBySource() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "Weekly Executive",
            profileFilter: []
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.source == "Weekly Executive")
    }

    @Test func searchMultipleMatches() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "2024-05",
            profileFilter: []
        )
        #expect(filtered.count == 5)
    }

    @Test func searchNoMatches() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "nonexistent",
            profileFilter: []
        )
        #expect(filtered.isEmpty)
    }

    @Test func profileFilterExact() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "",
            profileFilter: ["main"]
        )
        #expect(filtered.count == 2)
        #expect(filtered.allSatisfy { $0.name.contains("main") })
    }

    /// jamf-cli profile names are case-sensitive, so `EDU` is another profile.
    @Test func profileFilterMatchesCaseExactly() {
        let upper = ReportsView.filteredReports(
            reports: sampleReports, searchText: "", profileFilter: ["EDU"]
        )
        #expect(upper.isEmpty)
        let lower = ReportsView.filteredReports(
            reports: sampleReports, searchText: "", profileFilter: ["edu"]
        )
        #expect(lower.map(\.name) == ["school-report_edu_2024-05-05.xlsx"])
    }

    /// Two jamf-cli profiles saving to one folder: `acme` must not take in `acme-dev`,
    /// and choosing both shows both.
    @Test func profileFilterKeepsProfilesSharingAPrefixApart() {
        let shared = [
            "report_acme_2026-09-29_120000.xlsx",
            "report_acme-dev_2026-09-29_120001.xlsx",
            "jamf_report_acme-dev_2026-09-29_120002.html",
            "devices-acme-2026-09-29_120003.csv",
            "period-report-20260601-20260831-acme-dev-2026-09-29_120004.xlsx",
        ].map { Report(name: $0, size: "1 KB", date: "", source: "", sheets: 0, devices: 0) }
        func names(_ profiles: Set<String>) -> [String] {
            ReportsView.filteredReports(reports: shared, searchText: "", profileFilter: profiles)
                .map(\.name)
        }
        #expect(names(["acme"]) == ["report_acme_2026-09-29_120000.xlsx",
                                   "devices-acme-2026-09-29_120003.csv"])
        #expect(names(["acme-dev"]).count == 3)
        #expect(names(["acme", "acme-dev"]).count == 5)
        #expect(names([]).count == 5)
    }

    @Test func profileFilterLabelNamesTheSelection() {
        #expect(ReportsView.profileFilterLabel([]) == "All Profiles")
        #expect(ReportsView.profileFilterLabel(["acme-dev"]) == "acme-dev")
        #expect(ReportsView.profileFilterLabel(["acme", "acme-dev"]) == "2 profiles")
    }

    @Test func profileFilterNoMatches() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "",
            profileFilter: ["nonexistent"]
        )
        #expect(filtered.isEmpty)
    }

    @Test func searchAndProfileFilterCombined() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "xlsx",
            profileFilter: ["main"]
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.name == "jamf_report_main_2024-05-01.xlsx")
    }

    @Test func searchAndProfileFilterNoMatches() {
        let filtered = ReportsView.filteredReports(
            reports: sampleReports,
            searchText: "xlsx",
            profileFilter: ["edu"]
        )
        #expect(filtered.count == 1)
        #expect(filtered.first?.name.contains("school-report_edu") == true)
    }
}