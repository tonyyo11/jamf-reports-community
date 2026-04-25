import SwiftUI

struct RunsView: View {
    private struct LogLine: Identifiable {
        let id = UUID()
        let time: String
        let level: CLIBridge.LogLevel
        let text: String
    }

    private struct RunRow: Identifiable {
        let id = UUID()
        let date: String
        let name: String
        let status: Schedule.LastStatus
        let duration: String
        let selected: Bool
    }

    private let runRows: [RunRow] = [
        .init(date: "Apr 25 06:00", name: "Daily Snapshot",     status: .ok,   duration: "2m 01s", selected: true),
        .init(date: "Apr 24 07:33", name: "Mobile Inventory",   status: .warn, duration: "1m 14s", selected: false),
        .init(date: "Apr 24 06:00", name: "Daily Snapshot",     status: .ok,   duration: "1m 58s", selected: false),
        .init(date: "Apr 23 06:00", name: "Daily Snapshot",     status: .ok,   duration: "2m 04s", selected: false),
        .init(date: "Apr 22 06:00", name: "Daily Snapshot",     status: .ok,   duration: "2m 11s", selected: false),
        .init(date: "Apr 21 06:00", name: "Daily Snapshot",     status: .ok,   duration: "1m 56s", selected: false),
        .init(date: "Apr 20 07:02", name: "Weekly Executive",   status: .ok,   duration: "4m 22s", selected: false),
        .init(date: "Apr 20 06:00", name: "Daily Snapshot",     status: .ok,   duration: "2m 03s", selected: false),
    ]

    private let logLines: [LogLine] = [
        .init(time: "06:00:14", level: .info, text: "[jrc] launchagent-run · profile=meridian-prod"),
        .init(time: "06:00:14", level: .info, text: "[jrc] config: ~/Jamf-Reports/meridian-prod/config.yaml"),
        .init(time: "06:00:15", level: .ok,   text: "[ok] jamf-cli 1.6.2 found · auth verified for profile meridian-prod"),
        .init(time: "06:00:18", level: .info, text: "[snapshot] pro overview → jamf-cli-data/pro_overview_2026-04-25_060015.json"),
        .init(time: "06:00:31", level: .info, text: "[snapshot] pro computers list (--section GENERAL HARDWARE OS USER_AND_LOCATION SECURITY) · 524 devices"),
        .init(time: "06:01:42", level: .info, text: "[snapshot] pro report ea-results --all · 187 EAs · 524 devices"),
        .init(time: "06:01:55", level: .warn, text: "[warn] pro report app-status · 3 devices reported MDM command timeout"),
        .init(time: "06:02:03", level: .info, text: "[snapshot] protect overview · enabled=true"),
        .init(time: "06:02:14", level: .ok,   text: "[ok] 14 snapshot files written · 18.2 MB total"),
        .init(time: "06:02:14", level: .info, text: "[archive] copied meridian_export.csv → snapshots/computers/computers_2026-04-25_060214.csv"),
        .init(time: "06:02:15", level: .ok,   text: "[ok] launchagent-run completed in 2m 01s"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                HStack(alignment: .top, spacing: 14) {
                    runsList
                        .frame(width: 260)
                    logViewer
                }
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
    }

    private var header: some View {
        PageHeader(
            kicker: "Run · 2026-04-25 06:00 · Daily Snapshot Collection",
            title: "Run History",
            subtitle: "Stdout/stderr captured per scheduled run · 142 entries"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    PNPButton(title: "Copy log", icon: "doc.on.doc")
                    PNPButton(title: "Export", icon: "arrow.down.circle")
                }
            )
        }
    }

    private var runsList: some View {
        Card(padding: 8) {
            VStack(spacing: 2) {
                ForEach(runRows) { row in
                    runListItem(row)
                }
            }
        }
    }

    private func runListItem(_ row: RunRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Mono(text: row.date, size: 10.5)
                Spacer()
                statusPill(for: row.status)
            }
            Text(row.name).font(.system(size: 12, weight: .medium))
                .foregroundStyle(row.selected ? Theme.Colors.fg : Theme.Colors.fg2)
            Mono(text: row.duration, size: 10)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(row.selected ? Theme.Colors.gold.opacity(0.12) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(row.selected ? Theme.Colors.gold.opacity(0.3) : .clear, lineWidth: 0.5)
        )
    }

    private func statusPill(for s: Schedule.LastStatus) -> some View {
        switch s {
        case .ok:   Pill(text: "OK",   tone: .teal)
        case .warn: Pill(text: "WARN", tone: .warn)
        case .fail: Pill(text: "FAIL", tone: .danger)
        }
    }

    private var logViewer: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(Theme.Colors.gold)
                        .font(.system(size: 13))
                    Mono(text: "~/Jamf-Reports/meridian-prod/automation/logs/2026-04-25_060014.log",
                         size: 12, color: Theme.Colors.fg2)
                    Spacer()
                    Pill(text: "EXIT 0", tone: .teal)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider().background(Theme.Colors.hairlineStrong)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(logLines) { line in
                        HStack(alignment: .top, spacing: 12) {
                            Text(line.time)
                                .foregroundStyle(Theme.Colors.fgMuted)
                            Text(line.text)
                                .foregroundStyle(color(for: line.level))
                        }
                        .font(Theme.Fonts.mono(11.5))
                    }
                    HStack(spacing: 0) {
                        Text("tony@meridian-jrc ~ %  ")
                            .foregroundStyle(Theme.Colors.goldBright)
                        Rectangle()
                            .fill(Theme.Colors.gold)
                            .frame(width: 6, height: 14)
                    }
                    .font(Theme.Fonts.mono(11.5))
                    .padding(.top, 6)
                }
                .padding(14)
            }
            .background(Theme.Colors.codeBG)
        }
    }

    private func color(for level: CLIBridge.LogLevel) -> Color {
        switch level {
        case .info: Theme.Colors.fg2
        case .ok:   Theme.Colors.ok
        case .warn: Theme.Colors.warn
        case .fail: Theme.Colors.danger
        }
    }
}
