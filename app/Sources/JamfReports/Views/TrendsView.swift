import SwiftUI
import Charts

/// Hero feature — historical trends across 26 weeks of archived snapshots.
/// Differentiator vs. JamfDash, which only shows live state.
struct TrendsView: View {
    @Environment(WorkspaceStore.self) private var workspaceStore
    @State private var trendStore = TrendStore()
    @State private var bridge = CLIBridge()
    @State private var metric: TrendSeries.Metric = .compliance
    @State private var range: TrendRange = .w26
    @State private var selectedDate: String? = nil
    @State private var isArchiving = false

    private var values: [Double] {
        workspaceStore.demoMode ? (DemoData.trends[metric] ?? []) : trendStore.values(metric: metric)
    }

    private var trendDates: [String] {
        workspaceStore.demoMode ? DemoData.trendDates : trendStore.dates()
    }

    private var selectedIndex: Int? {
        guard let selectedDate else { return nil }
        return trendDates.firstIndex(of: selectedDate)
    }

    private var displayVal: Double {
        if let idx = selectedIndex, idx < values.count {
            return values[idx]
        }
        return values.last ?? 0
    }

    private var displayDate: String {
        selectedIndex != nil ? (selectedDate ?? "") : (trendDates.last ?? "")
    }

    private var startVal: Double { values.first ?? 0 }
    private var endVal: Double { values.last ?? 0 }
    private var delta: Double { endVal - startVal }
    private var pctDelta: Double { startVal == 0 ? 0 : (delta / startVal) * 100 }

    /// "good" trend for stale-devices is *down*; everything else is *up*.
    private var deltaIsPositive: Bool {
        metric == .stale ? delta < 0 : delta > 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !workspaceStore.demoMode && trendStore.isEmpty {
                    emptyState
                } else {
                    heroHeader
                    metricPicker
                    heroChart
                    comparisonRow
                    snapshotArchive
                }
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
        .onAppear {
            if !workspaceStore.demoMode {
                trendStore.load(profile: workspaceStore.profile, range: range)
            }
        }
        .onChange(of: workspaceStore.profile) { _, newValue in
            if !workspaceStore.demoMode {
                withAnimation(.snappy) {
                    trendStore.load(profile: newValue, range: range)
                }
            }
        }
        .onChange(of: range) { _, newValue in
            if !workspaceStore.demoMode {
                withAnimation(.snappy) {
                    trendStore.load(profile: workspaceStore.profile, range: newValue)
                }
            }
        }
    }

    // MARK: Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 100)
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 64))
                .foregroundStyle(Theme.Colors.hairlineStrong)
            
            VStack(spacing: 8) {
                Text("No trend data yet")
                    .font(Theme.Fonts.serif(24, weight: .bold))
                Text("Historical trends populate after 2+ scheduled runs.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
            
            Button {
                NotificationCenter.default.post(
                    name: .navigateToTab,
                    object: nil,
                    userInfo: ["tab": Tab.schedules.rawValue]
                )
            } label: {
                Text("Go to Schedules")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.Colors.gold)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Header

    private var heroHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Kicker(text: "Historical Trends · \(range.rawValue)", tone: .gold)
                Text("How the fleet has changed.")
                    .font(Theme.Fonts.serif(28, weight: .bold))
                    .foregroundStyle(Theme.Colors.fg)
                    .tracking(-0.5)
                HStack(spacing: 4) {
                    Text("Snapshot history from")
                    Text("snapshots/summaries/")
                        .font(Theme.Fonts.mono(12))
                        .foregroundStyle(Theme.Colors.goldBright)
                    Text("· \(trendDates.count) snapshots, oldest \(trendDates.first ?? "")")
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Colors.fgMuted)
            }
            Spacer()
            HStack(spacing: 8) {
                SegmentedControl(
                    selection: $range,
                    options: TrendRange.allCases.map { ($0, $0.rawValue, nil) }
                )
                PNPButton(title: "Export PNG", icon: "arrow.down.circle")
                    .disabled(true)
                    .help("PNG export is not yet available")
            }
        }
    }

    // MARK: Metric picker pills

    private var metricPicker: some View {
        FlowLayout(spacing: 8) {
            ForEach(TrendSeries.Metric.allCases) { m in
                metricPill(m)
            }
        }
    }

    private func metricPill(_ m: TrendSeries.Metric) -> some View {
        let series = workspaceStore.demoMode ? (DemoData.trends[m] ?? []) : trendStore.values(metric: m)
        let dl = (series.last ?? 0) - (series.first ?? 0)
        let goodTrend = m == .stale ? dl < 0 : dl > 0
        let isActive = metric == m
        let color = Color(hex: m.colorHex)

        return Button {
            withAnimation(.snappy(duration: 0.25)) { metric = m }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(m.displayLabel).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.fg)
                Text("\(dl >= 0 ? "+" : "")\(Int(dl.rounded()))\(m.unit)")
                    .font(Theme.Fonts.mono(10.5, weight: .semibold))
                    .foregroundStyle(goodTrend ? Theme.Colors.ok : Theme.Colors.danger)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? color.opacity(0.14) : Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isActive ? color : Theme.Colors.hairlineStrong, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Hero chart

    private var heroChart: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Kicker(text: metric.displayLabel)
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(Int(displayVal.rounded()))\(metric.unit)")
                                .font(Theme.Fonts.serif(44, weight: .bold))
                                .foregroundStyle(Theme.Colors.fg)
                                .monospacedDigit()
                            
                            if selectedIndex == nil {
                                HStack(spacing: 4) {
                                    Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("\(abs(Int(delta.rounded())))\(metric.unit) (\(String(format: "%.1f", pctDelta))%)")
                                }
                                .font(Theme.Fonts.mono(14, weight: .semibold))
                                .foregroundStyle(deltaIsPositive ? Theme.Colors.ok : Theme.Colors.danger)
                                Text("vs. \(trendDates.first ?? "")")
                                    .font(Theme.Fonts.mono(11))
                                    .foregroundStyle(Theme.Colors.fgMuted)
                            } else {
                                Text("at \(displayDate)")
                                    .font(Theme.Fonts.mono(14, weight: .semibold))
                                    .foregroundStyle(Theme.Colors.goldBright)
                            }
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Kicker(text: "Min · Max · Avg")
                        HStack(spacing: 14) {
                            Text("\(Int((values.min() ?? 0).rounded()))\(metric.unit)")
                            Text("\(Int((values.max() ?? 0).rounded()))\(metric.unit)")
                            Text("\(Int((values.reduce(0,+) / Double(max(values.count,1))).rounded()))\(metric.unit)")
                        }
                        .font(Theme.Fonts.mono(12))
                        .foregroundStyle(Theme.Colors.fg2)
                    }
                }

                // Swift Charts line + area mark
                Chart {
                    ForEach(Array(values.enumerated()), id: \.offset) { idx, v in
                        let date = trendDates[safe: idx] ?? ""
                        AreaMark(x: .value("Week", date),
                                 y: .value(metric.displayLabel, v))
                            .foregroundStyle(LinearGradient(
                                colors: [Color(hex: metric.colorHex).opacity(0.35),
                                         Color(hex: metric.colorHex).opacity(0.0)],
                                startPoint: .top, endPoint: .bottom
                            ))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Week", date),
                                 y: .value(metric.displayLabel, v))
                            .foregroundStyle(Color(hex: metric.colorHex))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.catmullRom)
                    }
                    
                    if let idx = selectedIndex, idx < values.count {
                        RuleMark(x: .value("Selected", trendDates[idx]))
                            .foregroundStyle(Theme.Colors.hairlineStrong)
                            .offset(y: -10)
                            .zIndex(-1)
                        
                        PointMark(x: .value("Selected", trendDates[idx]),
                                  y: .value(metric.displayLabel, values[idx]))
                            .foregroundStyle(Color(hex: metric.colorHex))
                            .symbolSize(100)
                            .annotation(position: .top, spacing: 8) {
                                Text("\(Int(values[idx].rounded()))\(metric.unit)")
                                    .font(Theme.Fonts.mono(12, weight: .bold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Theme.Colors.winBG2)
                                    .cornerRadius(4)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: metric.colorHex), lineWidth: 1))
                            }
                    } else if let last = values.indices.last {
                        let date = trendDates[safe: last] ?? ""
                        PointMark(x: .value("Week", date),
                                  y: .value(metric.displayLabel, values[last]))
                            .foregroundStyle(Color(hex: metric.colorHex))
                            .symbolSize(60)
                    }
                }
                .chartYScale(domain: metric.minY...metric.maxY)
                .chartXSelection(value: $selectedDate)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 28)) { _ in
                        AxisValueLabel().font(Theme.Fonts.mono(10))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine().foregroundStyle(Theme.Colors.hairline)
                        AxisValueLabel().font(Theme.Fonts.mono(10))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                }
                .frame(height: 260)
                .animation(.snappy(duration: 0.35), value: metric)

                Divider().background(Theme.Colors.hairline)

                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Rectangle().fill(Color(hex: metric.colorHex)).frame(width: 14, height: 2)
                        Text("Weekly snapshot").font(.system(size: 11.5))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").font(.system(size: 11))
                        Text("\(trendDates.count) archived summaries").font(.system(size: 11.5))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                    Spacer()
                    PNPButton(title: "Open in Finder", icon: "folder", style: .ghost, size: .sm) {
                        if let dir = WorkspacePaths.summariesDir(for: workspaceStore.profile) {
                            SystemActions.openFolder(dir)
                        }
                    }
                }
            }
        }
    }

    // MARK: Comparison row (stacked bands + multi-line)

    private var comparisonRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            SectionHeader(title: "Compliance Distribution Over Time")
                            Text("Devices grouped by failed-rule count, weekly")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.Colors.fgMuted)
                        }
                        Spacer()
                    }
                    if workspaceStore.demoMode {
                        stackedBandsChart
                        complianceBandLegend
                    } else {
                        complianceBandUnavailable
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionHeader(title: "Security Posture · Compared")
                        Text("FileVault vs. Compliance vs. macOS Current")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                    multilineComparisonChart
                    HStack(spacing: 14) {
                        legendDot(color: Theme.Colors.ok, label: "FileVault")
                        legendDot(color: Theme.Colors.gold, label: "NIST")
                        legendDot(color: Theme.Colors.info, label: "macOS")
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var complianceBandLegend: some View {
        HStack(spacing: 14) {
            ForEach(DemoData.complianceBands) { band in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(hex: band.colorHex))
                        .frame(width: 10, height: 10)
                    Text(band.label).font(.system(size: 11)).foregroundStyle(Theme.Colors.fg2)
                    Text(band.range).font(Theme.Fonts.mono(10.5)).foregroundStyle(Theme.Colors.fgMuted)
                }
            }
        }
    }

    private var complianceBandUnavailable: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 28))
                .foregroundStyle(Theme.Colors.hairlineStrong)
            Text("Compliance band history is not available for live data yet.")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.Colors.fg2)
            Text("The summary cache does not include per-band failed-rule counts.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Colors.fgMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background(Theme.Colors.codeBG)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(color).frame(width: 14, height: 2)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.Colors.fg2)
        }
    }

    private var stackedBandsChart: some View {
        // Demo data only. Live mode renders an empty state until summaries carry
        // real per-band failed-rule counts.
        let weeks = trendDates.enumerated().map { idx, date in
            let t = Double(idx) / Double(max(trendDates.count - 1, 1))
            let base = 524.0
            let pass    = Int((base * (0.35 + 0.1 * t)).rounded())
            let low     = Int((base * (0.35 - 0.05 * t)).rounded())
            let medLow  = Int((base * (0.15 - 0.05 * t)).rounded())
            let med     = Int((base * (0.10 - 0.05 * t)).rounded())
            let high    = Int((base * (0.05 - 0.02 * t)).rounded())
            return (date: date, values: [pass, low, medLow, med, high])
        }
        return Chart {
            ForEach(Array(weeks.enumerated()), id: \.offset) { weekIdx, week in
                ForEach(Array(DemoData.complianceBands.enumerated()), id: \.offset) { bandIdx, band in
                    BarMark(
                        x: .value("Week", week.date),
                        y: .value("Devices", week.values[bandIdx]),
                        stacking: .standard
                    )
                    .foregroundStyle(Color(hex: band.colorHex))
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 28)) { _ in
                AxisValueLabel().font(Theme.Fonts.mono(10))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
        }
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: 200)
    }

    private var multilineComparisonChart: some View {
        Chart {
            series("FileVault", color: Theme.Colors.ok, values: workspaceStore.demoMode ? (DemoData.trends[.fileVault] ?? []) : trendStore.values(metric: .fileVault))
            series("NIST", color: Theme.Colors.gold, values: workspaceStore.demoMode ? (DemoData.trends[.compliance] ?? []) : trendStore.values(metric: .compliance))
            series("macOS Current", color: Theme.Colors.info, values: workspaceStore.demoMode ? (DemoData.trends[.osCurrent] ?? []) : trendStore.values(metric: .osCurrent))
        }
        .chartYScale(domain: 30...100)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 56)) { _ in
                AxisValueLabel().font(Theme.Fonts.mono(10))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine().foregroundStyle(Theme.Colors.hairline)
                AxisValueLabel().font(Theme.Fonts.mono(10))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
        }
        .chartLegend(.hidden)
        .frame(height: 200)
    }

    @ChartContentBuilder
    private func series(_ name: String, color: Color, values: [Double]) -> some ChartContent {
        ForEach(Array(values.enumerated()), id: \.offset) { idx, v in
            LineMark(
                x: .value("Week", trendDates[safe: idx] ?? ""),
                y: .value(name, v),
                series: .value("Series", name)
            )
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)
        }
    }

    // MARK: Snapshot archive (timeline of weekly bars)

    private var snapshotArchive: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionHeader(title: "Snapshot Archive")
                        HStack(spacing: 4) {
                            Text("snapshots/summaries/")
                                .font(Theme.Fonts.mono(11.5))
                            Text("· \(trendDates.count) archived summaries · auto-archived from each ")
                            Text("generate")
                                .font(Theme.Fonts.mono(11))
                            Text(" run")
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        PNPButton(title: "Show in Finder", icon: "folder", size: .sm) {
                            if let dir = WorkspacePaths.summariesDir(for: workspaceStore.profile) {
                                SystemActions.openFolder(dir)
                            }
                        }
                        PNPButton(
                            title: isArchiving ? "Collecting…" : "Archive now",
                            icon: isArchiving ? "hourglass" : "icloud.and.arrow.up",
                            style: .gold,
                            size: .sm
                        ) {
                            guard !isArchiving else { return }
                            Task { await archiveNow() }
                        }
                    }
                }

                let currentMetricValues = values
                let lastIdx = currentMetricValues.indices.last
                HStack(spacing: 4) {
                    ForEach(Array(trendDates.enumerated()), id: \.offset) { idx, date in
                        let isLatest = idx == lastIdx
                        let v = currentMetricValues[safe: idx] ?? 0
                        let h = 4 + (v / 100) * 36
                        Rectangle()
                            .fill(isLatest ? Theme.Colors.gold : Theme.Colors.teal)
                            .opacity(isLatest ? 1 : 0.45)
                            .frame(height: h)
                            .frame(maxWidth: .infinity)
                            .help(date)
                    }
                }
                .frame(height: 56)
                .padding(.vertical, 8)

                Divider().background(Theme.Colors.hairline)
                HStack {
                    Text(trendDates.first ?? "")
                    Spacer()
                    Text(trendDates[safe: trendDates.count / 2] ?? "")
                    Spacer()
                    Text("\(trendDates.last ?? "") · latest")
                        .foregroundStyle(Theme.Colors.goldBright)
                }
                .font(Theme.Fonts.mono(10.5))
                .foregroundStyle(Theme.Colors.fgMuted)
            }
        }
    }
    // MARK: Archive

    private func archiveNow() async {
        let profile = workspaceStore.profile
        isArchiving = true
        _ = await bridge.collectThenGenerate(profile: profile, csvPath: nil) { _ in }
        isArchiving = false
        withAnimation(.snappy) {
            trendStore.load(profile: profile, range: range)
        }
    }
}


// MARK: - Helpers

extension Array {
    subscript(safe idx: Int) -> Element? { indices.contains(idx) ? self[idx] : nil }
}

/// Minimal flow layout for the metric pills row. SwiftUI 16+ has `Layout` but this
/// runs on macOS 14, so we lay out children into rows by hand.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if rowWidth + s.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
