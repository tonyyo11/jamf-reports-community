import SwiftUI

struct SourcesView: View {
    @Environment(WorkspaceStore.self) private var workspace

    private struct CSVFile: Identifiable {
        let id = UUID()
        let name: String
        let date: String
        let size: String
        let action: String
    }

    private struct CLICommand: Identifiable {
        let id = UUID()
        let label: String
        let status: String
    }

    private struct ArchiveFamily: Identifiable {
        let id = UUID()
        let family: String
        let glob: String
        let snapshots: Int
        let latest: String
        let storage: String
        let usedBy: String
    }

    private let cliCommands: [CLICommand] = [
        .init(label: "pro overview",                       status: "live"),
        .init(label: "pro computers list",                 status: "524 devices"),
        .init(label: "pro report ea-results --all",        status: "187 EAs"),
        .init(label: "pro report patch-compliance",        status: "live"),
        .init(label: "pro report app-status",              status: "live"),
        .init(label: "pro report update-status",           status: "live"),
        .init(label: "protect overview",                   status: "opt-in · disabled"),
    ]

    private let csvFiles: [CSVFile] = [
        .init(name: "meridian_export_2026-04-25.csv", date: "Apr 25 04:30", size: "2.4 MB", action: "pending"),
        .init(name: "mobile_export_2026-04-24.csv",   date: "Apr 24 04:30", size: "412 KB", action: "consumed"),
        .init(name: "meridian_export_2026-04-18.csv", date: "Apr 18 04:30", size: "2.3 MB", action: "archived"),
    ]

    private let families: [ArchiveFamily] = [
        .init(family: "computers",  glob: "*Computers*.csv",   snapshots: 26, latest: "Apr 25", storage: "24.1 MB", usedBy: "Trends · Compliance"),
        .init(family: "mobile",     glob: "*Mobile*.csv",      snapshots: 14, latest: "Apr 24", storage: "5.2 MB",  usedBy: "Mobile Inventory"),
        .init(family: "compliance", glob: "*NIST*.csv",        snapshots: 12, latest: "Apr 21", storage: "8.3 MB",  usedBy: "Future automation"),
        .init(family: "patching",   glob: "*Patch*.csv",       snapshots: 18, latest: "Apr 24", storage: "6.8 MB",  usedBy: "Archive only"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                HStack(alignment: .top, spacing: 14) {
                    cliCard
                    csvCard
                }
                familiesCard
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Kicker(text: "Inputs to the workbook", tone: .gold)
            Text("Data Sources")
                .font(Theme.Fonts.serif(26, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
            Text("Live API · cached snapshots · CSV inboxes · historical archives")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Colors.fgMuted)
        }
    }

    private var cliCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.fill").foregroundStyle(Theme.Colors.gold)
                        .font(.system(size: 16))
                    SectionHeader(title: "jamf-cli · live")
                    Spacer()
                    Pill(text: "Connected", tone: .teal)
                }
                HStack(spacing: 4) {
                    Text("jamf-cli 1.6.2 · profile")
                    Text("meridian-prod").foregroundStyle(Theme.Colors.goldBright)
                    Text("· auth verified 09:14")
                }
                .font(Theme.Fonts.mono(11.5))
                .foregroundStyle(Theme.Colors.fgMuted)

                VStack(spacing: 0) {
                    ForEach(Array(cliCommands.enumerated()), id: \.element.id) { idx, c in
                        HStack {
                            Mono(text: c.label, color: Theme.Colors.fg2)
                            Spacer()
                            Text(c.status).font(.system(size: 11)).foregroundStyle(Theme.Colors.fgMuted)
                        }
                        .padding(.vertical, 6)
                        if idx < cliCommands.count - 1 {
                            Divider().background(Theme.Colors.hairline)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var csvCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.Colors.tealBright)
                        .font(.system(size: 16))
                    SectionHeader(title: "CSV inbox")
                    Spacer()
                    Pill(text: "3 FILES", tone: .muted)
                }
                Mono(text: "~/Jamf-Reports/meridian-prod/csv-inbox/")

                VStack(spacing: 0) {
                    ForEach(Array(csvFiles.enumerated()), id: \.element.id) { idx, f in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(f.action == "pending" ? Theme.Colors.gold : Theme.Colors.fgMuted)
                                .font(.system(size: 12))
                            VStack(alignment: .leading, spacing: 1) {
                                Mono(text: f.name, color: Theme.Colors.fg2)
                                Mono(text: "\(f.date) · \(f.size)", size: 10.5)
                            }
                            Spacer()
                            Pill(text: f.action, tone: f.action == "pending" ? .gold : .muted)
                        }
                        .padding(.vertical, 8)
                        if idx < csvFiles.count - 1 {
                            Divider().background(Theme.Colors.hairline)
                        }
                    }
                }

                PNPButton(title: "Open in Finder", icon: "folder", size: .sm) {
                    let url = (ProfileService.workspaceURL(for: workspace.profile)
                                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Jamf-Reports"))
                        .appendingPathComponent("csv-inbox", isDirectory: true)
                    SystemActions.openFolder(url)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var familiesCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive").foregroundStyle(Theme.Colors.fgMuted)
                        .font(.system(size: 16))
                    SectionHeader(title: "Snapshot Archive Families")
                    Spacer()
                    PNPButton(title: "New family", icon: "plus", style: .gold, size: .sm)
                }
                Table(families) {
                    TableColumn("Family") { f in
                        Text(f.family)
                            .font(Theme.Fonts.mono(12, weight: .semibold))
                            .foregroundStyle(Theme.Colors.goldBright)
                    }
                    TableColumn("Globs") { f in Mono(text: f.glob) }
                    TableColumn("Snapshots") { f in Mono(text: "\(f.snapshots)") }
                    TableColumn("Latest") { f in Mono(text: f.latest) }
                    TableColumn("Storage") { f in Mono(text: f.storage) }
                    TableColumn("Used By") { f in
                        Text(f.usedBy).font(.system(size: 11.5)).foregroundStyle(Theme.Colors.fgMuted)
                    }
                }
                .frame(minHeight: 200)
                .scrollContentBackground(.hidden)
            }
        }
    }
}
