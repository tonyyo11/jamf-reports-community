import Charts
import SwiftUI

/// The cross-platform overview (`PlatformOverview`): one card per platform with its counts, OS
/// breakdown and version adoption over time, and the button that opens its device list. Jamf
/// Pro opens Computers or Mobile Devices; Jamf School opens School Devices for every platform.
/// Draws nothing when the newest summary has no OS map.
struct PlatformOverviewSection: View {
    let overview: PlatformOverview
    let isSchool: Bool

    var body: some View {
        if !overview.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(overview.platforms, id: \.name) { platform in
                    PlatformOverviewCard(platform: platform, opens: tab(for: platform))
                }
                if overview.mobileOSCurrent != nil || overview.mobileJailbroken != nil {
                    MobileFiguresCard(osCurrent: overview.mobileOSCurrent,
                                      jailbroken: overview.mobileJailbroken)
                }
            }
        }
    }

    private func tab(for platform: PlatformOverview.Platform) -> Tab {
        if isSchool { return .schoolDevices }
        return platform.isMac ? .devices : .mobileFleet
    }
}

private struct PlatformOverviewCard: View {
    let platform: PlatformOverview.Platform
    let opens: Tab
    @Environment(\.percentFormat) private var percentFormat
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                header
                tiles
                Text("OS versions")
                    .font(.headline)
                PlatformVersionBars(versions: platform.versions)
                Text("Version adoption over time")
                    .font(.headline)
                PlatformAdoptionChart(platform: platform)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack {
            SectionHeader(title: platform.name)
            Spacer(minLength: 8)
            PNPButton(title: L("View all \(platform.name) devices"), icon: opens.sfSymbol,
                      size: .sm) {
                NotificationCenter.default.post(
                    name: .navigateToTab, object: nil, userInfo: ["tab": opens.rawValue])
            }
            .help(L("Open \(opens.label)"))
        }
    }

    private var tiles: some View {
        EqualHeightTileGrid(minTileWidth: 140) {
            StatTile(label: L("Devices"), value: "\(platform.devices)",
                     sub: L("Reporting an OS version"), fillsHeight: true, labelLineLimit: 2)
            if let families = platform.modelFamilies {
                StatTile(label: L("Model families"), value: "\(families)",
                         sub: L("MacBook Air, Mac mini and so on"), fillsHeight: true, labelLineLimit: 2)
            }
            if let current = platform.onCurrentRelease {
                StatTile(label: L("Current release"), value: percentFormat.text(current),
                         sub: L("Latest release of their major version"), fillsHeight: true, labelLineLimit: 2)
            }
            if let gaps = platform.securityGaps {
                StatTile(label: L("Security gaps"), value: "\(gaps)",
                         sub: L("FileVault / SIP / Firewall gaps"),
                         fillsHeight: true, labelLineLimit: 2)
            }
        }
    }

    private var caption: String {
        let weeks = PlatformOverview.windowWeeks
        let base = L("Shares of the devices reporting an OS version, over the last \(weeks) weeks of daily summaries.")
        guard platform.versionsPooled > 0 else { return base }
        let drawn = platform.versionsSeen - platform.versionsPooled
        return base + " " + L("\(drawn) of \(platform.versionsSeen) versions are drawn; the older ones are pooled as Other.")
    }
}

/// The newest day's majors as rows: version, a bar of its share of the platform, then count and
/// share. The majors the adoption chart pools as Other end in one "N or older" bar.
private struct PlatformVersionBars: View {
    let versions: [PlatformOverview.Platform.Version]
    @Environment(\.percentFormat) private var percentFormat

    private func label(_ version: PlatformOverview.Platform.Version) -> String {
        version.orOlder.map { L("\($0) or older") } ?? version.key
    }

    var body: some View {
        let colors = Theme.ChartColors.colors(forVersions: versions.map(\.key))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(versions.enumerated()), id: \.element.key) { index, version in
                HStack(spacing: 10) {
                    Text(verbatim: label(version))
                        .font(.callout)
                        .foregroundStyle(Theme.Colors.fg2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: 150, alignment: .leading)
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(colors[index])
                            .frame(width: max(2, geometry.size.width * version.percent / 100))
                    }
                    .frame(height: 10)
                    Text(verbatim: "\(version.count) · \(percentFormat.text(version.percent))")
                        .font(Theme.Fonts.mono(11, weight: .semibold))
                        .foregroundStyle(Theme.Colors.fg)
                        .lineLimit(1)
                        .frame(minWidth: 96, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("\(label(version)): \(version.count) devices, \(percentFormat.text(version.percent))"))
            }
        }
    }
}

/// A line per drawn major (and Other), share per day on 0 to 100. Linear lines: a curve
/// overshoots below 0 where a new major sits at 0 before it rises. Point marks keep a one-day
/// series visible.
private struct PlatformAdoptionChart: View {
    let platform: PlatformOverview.Platform
    @Environment(\.percentFormat) private var percentFormat
    @Environment(\.colorSchemeContrast) private var contrast

    private func label(_ key: String) -> String {
        guard key == PlatformOverview.otherKey else { return key }
        return platform.versionsPooled == 1
            ? L("Other (1 version)") : L("Other (\(platform.versionsPooled) versions)")
    }

    var body: some View {
        let series = platform.adoption
        let colors = Theme.ChartColors.colors(forVersions: series.map(\.key))
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(Array(series.enumerated()), id: \.element.key) { index, line in
                    ForEach(line.points, id: \.date) { point in
                        LineMark(x: .value("Date", point.date),
                                 y: .value("Share", point.percent),
                                 series: .value("Version", line.key))
                            .foregroundStyle(colors[index])
                            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .interpolationMethod(.linear)
                        PointMark(x: .value("Date", point.date),
                                  y: .value("Share", point.percent))
                            .foregroundStyle(colors[index])
                            .symbolSize(14)
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(Theme.Colors.hairline)
                    AxisValueLabel {
                        if let share = value.as(Double.self) {
                            Text(PercentFormat.whole.text(share))
                        }
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
            .chartLegend(.hidden)
            .frame(height: 180)
            .accessibilityChartDescriptor(MultiLineChartDescriptor(
                title: L("\(platform.name) version adoption over time"),
                seriesList: series.map {
                    .init(name: label($0.key), dates: $0.points.map(\.date),
                          values: $0.points.map(\.percent))
                },
                percentFormat: percentFormat))
            WrappingRow(spacing: 14) {
                ForEach(Array(series.enumerated()), id: \.element.key) { index, line in
                    HStack(spacing: 6) {
                        Circle().fill(colors[index]).frame(width: 8, height: 8)
                        Text(label(line.key))
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.fg2)
                    }
                }
            }
        }
    }
}

/// `MobileSummary` figures cover every non-Mac device together, so they sit apart from the
/// per-platform cards.
private struct MobileFiguresCard: View {
    let osCurrent: MobileSummary.Share?
    let jailbroken: Int?
    @Environment(\.percentFormat) private var percentFormat
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader(title: L("All mobile devices"))
                    Text("The daily summary holds these for mobile devices together, not per platform.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
                EqualHeightTileGrid(minTileWidth: 140) {
                    if let osCurrent {
                        StatTile(label: L("Current release"),
                                 value: percentFormat.text(osCurrent.met, of: osCurrent.of),
                                 sub: L("\(osCurrent.met) of \(osCurrent.of) iOS and iPadOS devices"),
                                 fillsHeight: true, labelLineLimit: 2)
                    }
                    if let jailbroken {
                        StatTile(label: L("Jailbroken"), value: "\(jailbroken)",
                                 sub: L("Mobile devices of every type"), fillsHeight: true)
                    }
                }
            }
        }
    }
}
