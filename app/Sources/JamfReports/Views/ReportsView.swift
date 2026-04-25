import SwiftUI

struct ReportsView: View {
    @State private var filter: String = "All"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Card(padding: 0) {
                    Table(DemoData.recentReports) {
                        TableColumn("Filename") { r in
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(Theme.Colors.gold)
                                    .font(.system(size: 11))
                                Mono(text: r.name, color: Theme.Colors.fg)
                            }
                        }
                        TableColumn("Source schedule") { r in Text(r.source).font(.system(size: 12.5)) }
                        TableColumn("Sheets") { r in Mono(text: "\(r.sheets)") }
                        TableColumn("Devices") { r in Mono(text: "\(r.devices)") }
                        TableColumn("Size") { r in Mono(text: r.size) }
                        TableColumn("Generated") { r in Mono(text: r.date) }
                    }
                    .frame(minHeight: 360)
                    .scrollContentBackground(.hidden)
                }
                summary
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
    }

    private var header: some View {
        PageHeader(
            kicker: "Generated Reports",
            title: "47 reports archived",
            subtitle: "~/Jamf-Reports/meridian-prod/Generated Reports/"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    SegmentedControl(
                        selection: $filter,
                        options: [("All", "All", nil), ("xlsx", "xlsx", nil), ("html", "html", nil), ("csv", "csv", nil)]
                    )
                    PNPButton(title: "Reveal in Finder", icon: "folder")
                }
            )
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            StatTile(label: "Total reports",       value: "47",     sub: "Last 6 months")
            StatTile(label: "Disk used",           value: "58 MB",  sub: "Avg 1.2 MB / report")
            StatTile(label: "Snapshots archived",  value: "312",    sub: "26 weeks · 12 families")
            StatTile(label: "Auto-archived",       value: "8",      sub: "Older runs moved to /archive")
        }
    }
}
