import SwiftUI
import Charts

struct OverviewView: View {
    @Environment(WorkspaceStore.self) private var workspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statRow
                osAndRules
                securityAgents
                recentActivity
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
    }

    private var header: some View {
        PageHeader(
            kicker: "Snapshot · Apr 25, 2026 · 09:14",
            title: "\(workspace.org.name) Fleet Overview",
            subtitle: "524 Macs across 8 departments · 3 sites · NIST 800-53r5 Moderate baseline"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    PNPButton(title: "Refresh", icon: "arrow.clockwise")
                    PNPButton(title: "Generate Report", icon: "play.fill", style: .gold)
                }
            )
        }
    }

    private var statRow: some View {
        HStack(spacing: 12) {
            StatTile(label: "Active Devices", value: "524",
                     delta: "+5 wk", deltaTrend: .up,
                     sparkValues: DemoData.totalDevicesTrend, sparkColor: Theme.Colors.gold)
            StatTile(label: "FileVault", value: "91.8%",
                     delta: "+1.4pp", deltaTrend: .up,
                     sparkValues: DemoData.trends[.fileVault], sparkColor: Theme.Colors.ok)
            StatTile(label: "NIST Compliance", value: "80.6%",
                     delta: "+3.2pp", deltaTrend: .up,
                     sparkValues: DemoData.trends[.compliance], sparkColor: Theme.Colors.gold)
            StatTile(label: "Stale (30d+)", value: "22",
                     delta: "−4 wk", deltaTrend: .up,
                     sparkValues: DemoData.trends[.stale], sparkColor: Theme.Colors.warn)
        }
    }

    // MARK: OS distribution donut + Top failing rules

    private var osAndRules: some View {
        HStack(alignment: .top, spacing: 12) {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        SectionHeader(title: "macOS Distribution")
                        Spacer()
                        Pill(text: "5 versions", tone: .muted)
                    }
                    HStack(alignment: .center, spacing: 18) {
                        donut
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(DemoData.osDistribution) { o in
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(Color(hex: o.colorHex))
                                        .frame(width: 8, height: 8)
                                    Text(o.version)
                                        .font(.system(size: 12))
                                        .foregroundStyle(o.current ? Theme.Colors.fg : Theme.Colors.fgMuted)
                                    Spacer(minLength: 0)
                                    Mono(text: "\(o.count)")
                                    Text("\(String(format: "%.1f", o.pct))%")
                                        .font(Theme.Fonts.mono(11, weight: .semibold))
                                        .foregroundStyle(Theme.Colors.fg)
                                        .frame(width: 44, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            SectionHeader(title: "Top Failing Rules")
                            Text("NIST 800-53r5 Moderate · across 502 active devices")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.Colors.fgMuted)
                        }
                        Spacer()
                        PNPButton(title: "View all 47", size: .sm)
                    }
                    failingRulesBars
                }
            }
            .frame(maxWidth: .infinity * 1.4)
        }
    }

    private var donut: some View {
        Chart(DemoData.osDistribution) { o in
            SectorMark(
                angle: .value("Devices", o.pct),
                innerRadius: .ratio(0.62),
                outerRadius: .ratio(0.95),
                angularInset: 1.2
            )
            .foregroundStyle(Color(hex: o.colorHex))
        }
        .chartLegend(.hidden)
        .frame(width: 160, height: 160)
        .overlay(
            VStack(spacing: 2) {
                Text("73%")
                    .font(Theme.Fonts.serif(26, weight: .bold))
                    .foregroundStyle(Theme.Colors.fg)
                Kicker(text: "On Current")
            }
        )
    }

    private var failingRulesBars: some View {
        let rules = DemoData.topFailingRules.prefix(6)
        let maxFails = rules.map(\.fails).max() ?? 1
        return VStack(spacing: 8) {
            ForEach(Array(rules)) { r in
                HStack(spacing: 8) {
                    Text(r.ruleID)
                        .font(Theme.Fonts.mono(11.5))
                        .foregroundStyle(Theme.Colors.fg2)
                        .frame(width: 260, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { geo in
                        let w = CGFloat(r.fails) / CGFloat(maxFails) * geo.size.width
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.04))
                                .frame(height: 10)
                            Capsule().fill(Theme.Colors.gold).frame(width: w, height: 10)
                        }
                    }
                    .frame(height: 10)
                    Text("\(r.fails)")
                        .font(Theme.Fonts.mono(11.5, weight: .semibold))
                        .foregroundStyle(Theme.Colors.fg)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Security agents

    private var securityAgents: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Security Agents")
                    Spacer()
                    Kicker(text: "5 tracked")
                }
                HStack(spacing: 10) {
                    ForEach(DemoData.securityAgents) { a in
                        agentCard(a)
                    }
                }
            }
        }
    }

    private func agentCard(_ a: SecurityAgent) -> some View {
        let barColor: Color = a.pct > 90 ? Theme.Colors.ok :
                              a.pct > 80 ? Theme.Colors.gold : Theme.Colors.warn
        return VStack(alignment: .leading, spacing: 4) {
            Text(a.name).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Colors.fg)
            Text("\(String(format: "%.1f", a.pct))%")
                .font(Theme.Fonts.serif(22, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
                .monospacedDigit()
            HStack(spacing: 6) {
                Mono(text: "\(a.installed) / 502", size: 10.5)
                if a.trend == .up {
                    Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Colors.ok)
                }
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.05)).frame(height: 4)
                GeometryReader { geo in
                    Capsule().fill(barColor).frame(width: geo.size.width * a.pct / 100, height: 4)
                }
                .frame(height: 4)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.Colors.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Recent activity table

    private var recentActivity: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    SectionHeader(title: "Recent Activity")
                    Spacer()
                    Pill(text: "8 of 524", tone: .muted)
                    PNPButton(title: "View all", size: .sm)
                }
                .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
                Divider().background(Theme.Colors.hairlineStrong)

                Table(DemoData.deviceSample) {
                    TableColumn("Device") { d in
                        Text(d.name).font(.system(size: 12.5, weight: .semibold))
                    }
                    TableColumn("Serial") { d in Mono(text: d.serial) }
                    TableColumn("macOS") { d in Mono(text: d.os) }
                    TableColumn("User") { d in
                        Text(d.user).font(.system(size: 12.5)).foregroundStyle(Theme.Colors.fgMuted)
                    }
                    TableColumn("Department") { d in Text(d.dept).font(.system(size: 12.5)) }
                    TableColumn("FV") { d in
                        Image(systemName: d.fileVault ? "checkmark" : "xmark")
                            .foregroundStyle(d.fileVault ? Theme.Colors.ok : Theme.Colors.danger)
                            .font(.system(size: 11, weight: .bold))
                    }
                    .width(40)
                    TableColumn("Failed Rules") { d in failurePill(d.fails) }
                    TableColumn("Last Seen") { d in
                        Mono(text: d.lastSeen,
                             color: d.lastSeen.contains("day") ? Theme.Colors.warn : Theme.Colors.fgMuted)
                    }
                }
                .frame(minHeight: 260)
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder
    private func failurePill(_ count: Int) -> some View {
        switch count {
        case 0:        Pill(text: "PASS", tone: .teal)
        case 1...10:   Pill(text: "\(count)", tone: .muted)
        case 11...30:  Pill(text: "\(count)", tone: .warn)
        default:       Pill(text: "\(count)", tone: .danger)
        }
    }
}
