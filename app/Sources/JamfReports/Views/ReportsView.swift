import SwiftUI

struct ReportsView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var filter: String = "All"
    @State private var selectedReports = Set<Report.ID>()
    @State private var reports: [Report] = []
    @State private var reportStats = ReportLibrary.Stats(count: 0, totalBytes: 0, archivedCount: 0)
    @State private var snapshotFamilies: [SnapshotFamily] = []

    private var reportsDirectory: URL {
        let workspace = ProfileService.workspaceURL(for: workspace.profile)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Jamf-Reports")
        return workspace.appendingPathComponent("Generated Reports", isDirectory: true)
    }

    private var filteredReports: [Report] {
        guard filter != "All" else { return reports }
        return reports.filter { $0.name.lowercased().hasSuffix(".\(filter.lowercased())") }
    }

    private var snapshotCount: Int {
        snapshotFamilies.reduce(0) { $0 + $1.snapshotCount }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Card(padding: 0) {
                    if reports.isEmpty {
                        emptyState
                    } else if filteredReports.isEmpty {
                        noFilterMatches
                    } else {
                        Table(filteredReports, selection: $selectedReports) {
                            TableColumn("Filename") { r in
                                HStack(spacing: 8) {
                                    Image(systemName: icon(for: r.name))
                                        .foregroundStyle(Theme.Colors.gold)
                                        .font(.system(size: 11))
                                    Mono(text: r.name, color: Theme.Colors.fg)
                                }
                            }
                            TableColumn("Source schedule") { r in
                                Text(r.source).font(.system(size: 12.5))
                            }
                            TableColumn("Sheets") { r in Mono(text: "\(r.sheets)") }
                            TableColumn("Devices") { r in Mono(text: "\(r.devices)") }
                            TableColumn("Size") { r in Mono(text: r.size) }
                            TableColumn("Generated") { r in Mono(text: r.date) }
                        }
                        .frame(minHeight: 360)
                        .scrollContentBackground(.hidden)
                        .contextMenu(forSelectionType: Report.ID.self) { selection in
                            if let reportID = selection.first,
                               let url = ReportLibrary().url(
                                profile: workspace.profile,
                                reportName: reportID
                               ) {
                                Button("Reveal in Finder") {
                                    SystemActions.reveal(url)
                                }
                                Button("Open") {
                                    SystemActions.open(url)
                                }
                                Button("Copy path") {
                                    SystemActions.copyToClipboard(url.path)
                                }
                            }
                        }
                    }
                }
                summary
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
        .onAppear(perform: reload)
        .onChange(of: workspace.profile) { _, _ in reload() }
    }

    private var header: some View {
        PageHeader(
            kicker: "Generated Reports",
            title: "\(reports.count) reports archived",
            subtitle: "~/Jamf-Reports/\(workspace.profile)/Generated Reports/"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    SegmentedControl(
                        selection: $filter,
                        options: [
                            ("All", "All", nil),
                            ("xlsx", "xlsx", nil),
                            ("html", "html", nil),
                            ("csv", "csv", nil),
                        ]
                    )
                    PNPButton(title: "Reveal in Finder", icon: "folder") {
                        SystemActions.openFolder(reportsDirectory)
                    }
                }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(Theme.Colors.gold)
            Text("No reports yet — run Generate from Overview")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Colors.fg)
            PNPButton(title: "Go to Overview", icon: "house", style: .gold) {
                requestOverviewTab()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private var noFilterMatches: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 24))
                .foregroundStyle(Theme.Colors.fgMuted)
            Text("No \(filter) reports found")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Colors.fg)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private var summary: some View {
        HStack(spacing: 12) {
            StatTile(
                label: "Total reports",
                value: "\(reportStats.count)",
                sub: "Generated outputs"
            )
            StatTile(
                label: "Disk used",
                value: FileDisplay.size(reportStats.totalBytes),
                sub: "xlsx · html · csv"
            )
            StatTile(
                label: "Snapshots archived",
                value: "\(snapshotCount)",
                sub: "\(snapshotFamilies.count) families"
            )
            StatTile(
                label: "Auto-archived",
                value: "\(reportStats.archivedCount)",
                sub: "Moved to /archive"
            )
        }
    }

    private func reload() {
        let library = ReportLibrary()
        reports = library.list(profile: workspace.profile)
        reportStats = library.stats(profile: workspace.profile)
        snapshotFamilies = SnapshotArchiveService().families(profile: workspace.profile)
        selectedReports = selectedReports.intersection(Set(reports.map(\.id)))
    }

    private func icon(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "xlsx": "tablecells"
        case "html": "safari"
        case "csv": "doc.text"
        default: "doc"
        }
    }

    private func requestOverviewTab() {
        NotificationCenter.default.post(name: .requestOverviewTab, object: nil)
    }
}

extension Notification.Name {
    static let requestOverviewTab = Notification.Name("JamfReports.requestOverviewTab")
}
