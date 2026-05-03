import SwiftUI
import Charts

/// Hero feature — historical trends across 26 weeks of archived snapshots.
/// Differentiator vs. JamfDash, which only shows live state.
struct TrendsView: View {
    @Environment(WorkspaceStore.self) private var workspaceStore
    @State private var trendStore = TrendStore()
    @State private var bridge = CLIBridge()
    @State private var metric: TrendSeries.Metric = .stability
    @State private var range: TrendRange = .w26
    @State private var selectedDate: Date? = nil
    @State private var isArchiving = false
    @State private var isExporting = false

    private var trendPoints: [TrendPoint] {
        workspaceStore.demoMode
            ? TrendDemoSeries.points(for: metric, range: range)
            : trendStore.points(metric: metric)
    }

    private var values: [Double] {
        trendPoints.map(\.value)
    }

    private var trendDates: [Date] {
        trendPoints.map(\.date)
    }

    private var chartDomain: ClosedRange<Date>? {
        if workspaceStore.demoMode {
            return TrendDemoSeries.chartDomain(for: metric, range: range)
        }
        return trendStore.chartDomain
    }

    private var selectedPoint: TrendPoint? {
        guard let selectedDate else { return nil }
        return trendPoints.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    private var displayVal: Double {
        selectedPoint?.value ?? trendPoints.last?.value ?? 0
    }

    private var displayDate: String {
        let d = selectedPoint?.date ?? trendPoints.last?.date ?? Date()
        return SummaryJSONParser.dateFormatter.string(from: d)
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
            selectedDate = nil
            if !workspaceStore.demoMode {
                withAnimation(.snappy) {
                    trendStore.load(profile: workspaceStore.profile, range: newValue)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            if !workspaceStore.demoMode {
                withAnimation(.snappy) {
                    trendStore.load(profile: workspaceStore.profile, range: range)
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
        PageHeader(
            kicker: "Trends · \(range.rawValue)",
            breadcrumbs: [Breadcrumb(label: "Overview", action: { navigateToOverview() })],
            title: "Historical Trends",
            subtitle: "Snapshot history from snapshots/summaries · \(trendDates.count) snapshots",
            lastModified: workspaceStore.demoMode ? Calendar.current.date(from: DateComponents(year: 2026, month: 4, day: 25)) : trendStore.filteredSummaries.last?.parsedDate
        ) {
            AnyView(
                HStack(spacing: 8) {
                    SegmentedControl(
                        selection: $range,
                        options: TrendRange.allCases.map { ($0, $0.rawValue, nil) }
                    )
                    PNPButton(title: isExporting ? "Exporting…" : "Export PNG", icon: "arrow.down.circle") {
                        Task { await exportChartPNG() }
                    }
                    .disabled(isExporting)
                }
            )
        }
    }

    private func navigateToOverview() {
        NotificationCenter.default.post(
            name: .navigateToTab,
            object: nil,
            userInfo: ["tab": Tab.overview.rawValue]
        )
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
        let series = points(for: m).map(\.value)
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
                            
                            if selectedPoint == nil {
                                HStack(spacing: 4) {
                                    Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("\(abs(Int(delta.rounded())))\(metric.unit) (\(String(format: "%.1f", pctDelta))%)")
                                }
                                .font(Theme.Fonts.mono(14, weight: .semibold))
                                .foregroundStyle(deltaIsPositive ? Theme.Colors.ok : Theme.Colors.danger)
                                Text("vs. \(SummaryJSONParser.dateFormatter.string(from: trendDates.first ?? Date()))")
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
                if let domain = chartDomain {
                    Chart {
                        ForEach(Array(trendPoints.enumerated()), id: \.offset) { _, point in
                            AreaMark(x: .value("Date", point.date),
                                     y: .value(metric.displayLabel, point.value))
                                .foregroundStyle(LinearGradient(
                                    colors: [Color(hex: metric.colorHex).opacity(0.35),
                                             Color(hex: metric.colorHex).opacity(0.0)],
                                    startPoint: .top, endPoint: .bottom
                                ))
                                .interpolationMethod(.catmullRom)
                            LineMark(x: .value("Date", point.date),
                                     y: .value(metric.displayLabel, point.value))
                                .foregroundStyle(Color(hex: metric.colorHex))
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.catmullRom)
                        }

                        if let selectedPoint {
                            RuleMark(x: .value("Selected", selectedPoint.date))
                                .foregroundStyle(Theme.Colors.hairlineStrong)
                                .offset(y: -10)
                                .zIndex(-1)

                            PointMark(x: .value("Selected", selectedPoint.date),
                                      y: .value(metric.displayLabel, selectedPoint.value))
                                .foregroundStyle(Color(hex: metric.colorHex))
                                .symbolSize(100)
                                .annotation(position: .top, spacing: 8) {
                                    Text("\(Int(selectedPoint.value.rounded()))\(metric.unit)")
                                        .font(Theme.Fonts.mono(12, weight: .bold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Theme.Colors.winBG2)
                                        .cornerRadius(4)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: metric.colorHex), lineWidth: 1))
                                }
                        } else if let lastPoint = trendPoints.last {
                            PointMark(x: .value("Date", lastPoint.date),
                                      y: .value(metric.displayLabel, lastPoint.value))
                                .foregroundStyle(Color(hex: metric.colorHex))
                                .symbolSize(60)
                        }
                    }
                    .chartXScale(domain: domain)
                    .chartXSelection(value: $selectedDate)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: range == .w4 ? 7 : 28)) { _ in
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
                } else {
                    Text("Calculating domain...")
                        .frame(height: 260)
                }

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
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                complianceBandCard
                securityPostureCard
            }
            VStack(spacing: 16) {
                complianceBandCard
                securityPostureCard
            }
        }
    }

    private var complianceBandCard: some View {
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
    }

    private var securityPostureCard: some View {
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
        let dates = trendDates
        let weeks = dates.enumerated().map { idx, date -> (date: Date, values: [Int]) in
            let t = Double(idx) / Double(max(dates.count - 1, 1))
            let base = 524.0
            let pass    = Int((base * (0.35 + 0.1 * t)).rounded())
            let low     = Int((base * (0.35 - 0.05 * t)).rounded())
            let medLow  = Int((base * (0.15 - 0.05 * t)).rounded())
            let med     = Int((base * (0.10 - 0.05 * t)).rounded())
            let high    = Int((base * (0.05 - 0.02 * t)).rounded())
            return (date: date, values: [pass, low, medLow, med, high])
        }

        return Group {
            if let domain = chartDomain {
                Chart {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { weekIdx, week in
                        ForEach(Array(DemoData.complianceBands.enumerated()), id: \.offset) { bandIdx, band in
                            BarMark(
                                x: .value("Date", week.date),
                                y: .value("Devices", week.values[bandIdx]),
                                stacking: .standard
                            )
                            .foregroundStyle(Color(hex: band.colorHex))
                        }
                    }
                }
                .chartXScale(domain: domain)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: range == .w4 ? 7 : 28)) { _ in
                        AxisValueLabel().font(Theme.Fonts.mono(10))
                            .foregroundStyle(Theme.Colors.fgMuted)
                    }
                }
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 200)
            } else {
                Text("No Data")
                    .frame(height: 200)
            }
        }
    }

    private var multilineComparisonChart: some View {
        Group {
            if let domain = chartDomain {
                Chart {
                    series("FileVault", color: Theme.Colors.ok, points: points(for: .fileVault))
                    series("NIST", color: Theme.Colors.gold, points: points(for: .compliance))
                    series("macOS Current", color: Theme.Colors.info, points: points(for: .osCurrent))
                }
                .chartXScale(domain: domain)
                .chartYScale(domain: 30...100)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: range == .w4 ? 7 : 56)) { _ in
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
            } else {
                Text("No Data")
                    .frame(height: 200)
            }
        }
    }

    private func points(for m: TrendSeries.Metric) -> [TrendPoint] {
        workspaceStore.demoMode
            ? TrendDemoSeries.points(for: m, range: range)
            : trendStore.points(metric: m)
    }

    @ChartContentBuilder
    private func series(_ name: String, color: Color, points: [TrendPoint]) -> some ChartContent {
        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
            LineMark(
                x: .value("Date", point.date),
                y: .value(name, point.value),
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
                            title: isArchiving ? "Archiving…" : "Archive now",
                            icon: isArchiving ? "hourglass" : "icloud.and.arrow.up",
                            style: .gold,
                            size: .sm
                        ) {
                            Task { await archiveNow() }
                        }
                        .disabled(isArchiving || workspaceStore.demoMode)
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
                            .help(SummaryJSONParser.dateFormatter.string(from: date))
                    }
                }
                .frame(height: 56)
                .padding(.vertical, 8)

                Divider().background(Theme.Colors.hairline)
                HStack {
                    Text(SummaryJSONParser.dateFormatter.string(from: trendDates.first ?? Date()))
                    Spacer()
                    Text(SummaryJSONParser.dateFormatter.string(from: trendDates[safe: trendDates.count / 2] ?? Date()))
                    Spacer()
                    Text("\(SummaryJSONParser.dateFormatter.string(from: trendDates.last ?? Date())) · latest")
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
        workspaceStore.globalStatus = "jrc collect + generate · profile=\(profile)"
        let exit = await bridge.collectThenGenerate(profile: profile, csvPath: nil) { line in
            Task { @MainActor in
                workspaceStore.globalStatus = "jrc · \(line.text)"
            }
        }
        isArchiving = false
        workspaceStore.globalStatus = nil
        if exit == 0 {
            workspaceStore.toast = Toast(message: "Archive generated successfully", style: .success)
            withAnimation(.snappy) {
                trendStore.load(profile: profile, range: range)
            }
        } else {
            workspaceStore.toast = Toast(message: "Archive failed · exit \(exit)", style: .danger)
        }
    }

    // MARK: Export PNG

    @MainActor
    private func exportChartPNG() async {
        isExporting = true
        defer { isExporting = false }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(metric.displayLabel.replacingOccurrences(of: " ", with: "-")).png"
        panel.title = "Export Chart as PNG"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let snapshot = ChartExportView(
            trendPoints: trendPoints,
            metric: metric,
            domain: chartDomain
        )
        let renderer = ImageRenderer(content: snapshot)
        renderer.scale = 2.0

        guard let image = renderer.nsImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        try? pngData.write(to: url)
    }
}


// MARK: - Helpers

extension Array {
    subscript(safe idx: Int) -> Element? { indices.contains(idx) ? self[idx] : nil }
}

enum TrendDemoSeries {
    static var dates: [Date] {
        DemoData.trendDates.compactMap { SummaryJSONParser.dateFormatter.date(from: $0) }
    }

    static func values(for metric: TrendSeries.Metric) -> [Double] {
        metric == .activeDevices ? DemoData.totalDevicesTrend : (DemoData.trends[metric] ?? [])
    }

    static func points(for metric: TrendSeries.Metric, range: TrendRange) -> [TrendPoint] {
        points(dates: dates, values: values(for: metric), range: range)
    }

    static func points(dates: [Date], values: [Double], range: TrendRange) -> [TrendPoint] {
        let count = min(dates.count, values.count)
        guard count > 0 else { return [] }

        let allPoints = (0..<count).map { idx in
            TrendPoint(date: dates[idx], value: values[idx])
        }
        guard let latest = allPoints.last?.date else { return [] }
        guard let start = startDate(for: range, latest: latest) else { return allPoints }
        return allPoints.filter { $0.date >= start }
    }

    static func chartDomain(for metric: TrendSeries.Metric, range: TrendRange) -> ClosedRange<Date>? {
        let points = points(for: metric, range: range)
        guard let latest = points.last?.date else { return nil }
        let start = startDate(for: range, latest: latest) ?? points.first?.date ?? latest
        return start...latest
    }

    private static func startDate(for range: TrendRange, latest: Date) -> Date? {
        let calendar = Calendar.current
        switch range {
        case .w4:  return calendar.date(byAdding: .weekOfYear, value: -4, to: latest)
        case .w12: return calendar.date(byAdding: .weekOfYear, value: -12, to: latest)
        case .w26: return calendar.date(byAdding: .weekOfYear, value: -26, to: latest)
        case .w52: return calendar.date(byAdding: .weekOfYear, value: -52, to: latest)
        case .all: return nil
        }
    }
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

// MARK: - Chart export snapshot view

/// Fixed-size view rendered to PNG by `ImageRenderer`. Stands alone — no
/// environment dependencies — so it renders correctly off-screen.
private struct ChartExportView: View {
    let trendPoints: [TrendPoint]
    let metric: TrendSeries.Metric
    let domain: ClosedRange<Date>?

    private struct ExportPoint: Identifiable {
        let index: Int
        let date: Date
        let value: Double

        var id: Int { index }
    }

    private var points: [ExportPoint] {
        trendPoints.enumerated().map { idx, point in
            ExportPoint(index: idx, date: point.date, value: point.value)
        }
    }

    private var isPercentMetric: Bool { metric.unit == "%" }
    private var firstPoint: ExportPoint? { points.first }
    private var lastPoint: ExportPoint? { points.last }
    private var values: [Double] { points.map(\.value) }
    private var minValue: Double { values.min() ?? 0 }
    private var maxValue: Double { values.max() ?? 0 }
    private var averageValue: Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
    private var delta: Double { (values.last ?? 0) - (values.first ?? 0) }

    private var yDomain: ClosedRange<Date> {
        domain ?? (Date().addingTimeInterval(-26*7*24*3600)...Date())
    }

    private var yValueDomain: ClosedRange<Double> {
        guard !values.isEmpty else { return 0...100 }
        if isPercentMetric {
            let lower = min(metric.minY, max(0, floor((minValue - 5) / 10) * 10))
            return lower...100
        }
        return 0...niceCeiling(max(maxValue * 1.18, 1))
    }

    private var tickDates: [Date] {
        guard !points.isEmpty else { return [] }
        let dates = points.map(\.date)
        if dates.count <= 5 { return dates }
        let last = dates.count - 1
        let indices = [0, last / 4, last / 2, (last * 3) / 4, last]
        return Array(Set(indices)).sorted().map { dates[$0] }
    }

    private var dateRangeText: String {
        guard let firstPoint, let lastPoint else { return "No snapshots" }
        let f = SummaryJSONParser.dateFormatter
        if firstPoint.date == lastPoint.date {
            return "\(f.string(from: firstPoint.date)) · 1 snapshot"
        }
        return "\(f.string(from: firstPoint.date)) → \(f.string(from: lastPoint.date)) · \(points.count) snapshots"
    }

    private var changeText: String {
        let sign = delta >= 0 ? "+" : "−"
        let absolute = abs(delta)
        if isPercentMetric {
            return "\(sign)\(String(format: "%.1f", absolute))pp"
        }
        return "\(sign)\(Int(absolute.rounded()))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(metric.displayLabel)
                        .font(.system(size: 30, weight: .bold, design: .serif))
                        .foregroundStyle(Color(hex: 0x111827))
                    Text(dateRangeText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x475569))
                }
                Spacer()
                if let lastPoint {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(formatValue(lastPoint.value))
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(hex: metric.colorHex))
                        Text("latest · \(SummaryJSONParser.dateFormatter.string(from: lastPoint.date))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x64748B))
                    }
                }
            }

            Chart {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value(metric.displayLabel, point.value)
                    )
                    .foregroundStyle(LinearGradient(
                        colors: [
                            Color(hex: metric.colorHex).opacity(0.26),
                            Color(hex: metric.colorHex).opacity(0.03)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Date", point.date),
                        y: .value(metric.displayLabel, point.value)
                    )
                    .foregroundStyle(Color(hex: metric.colorHex))
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", point.date),
                        y: .value(metric.displayLabel, point.value)
                    )
                    .foregroundStyle(Color.white)
                    .symbolSize(point.index == points.indices.last ? 82 : 46)
                    .annotation(position: .overlay) {
                        Circle()
                            .stroke(Color(hex: metric.colorHex), lineWidth: 2.2)
                            .frame(width: point.index == points.indices.last ? 11 : 8,
                                   height: point.index == points.indices.last ? 11 : 8)
                    }
                }

                if let lastPoint {
                    RuleMark(x: .value("Latest", lastPoint.date))
                        .foregroundStyle(Color(hex: 0x94A3B8).opacity(0.65))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))

                    PointMark(
                        x: .value("Latest", lastPoint.date),
                        y: .value(metric.displayLabel, lastPoint.value)
                    )
                    .foregroundStyle(Color(hex: metric.colorHex))
                    .symbolSize(130)
                    .annotation(position: .top, alignment: .trailing, spacing: 8) {
                        Text(formatValue(lastPoint.value))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(hex: 0x111827))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color(hex: metric.colorHex), lineWidth: 1)
                            )
                    }
                }
            }
            .chartXScale(domain: yDomain)
            .chartYScale(domain: yValueDomain)
            .chartXAxis {
                AxisMarks(values: tickDates) { value in
                    AxisGridLine()
                        .foregroundStyle(Color(hex: 0xE2E8F0))
                    AxisTick()
                        .foregroundStyle(Color(hex: 0x94A3B8))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(SummaryJSONParser.dateFormatter.string(from: date))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(hex: 0x475569))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                        .foregroundStyle(Color(hex: 0xE2E8F0))
                    AxisTick()
                        .foregroundStyle(Color(hex: 0x94A3B8))
                    AxisValueLabel {
                        if let y = value.as(Double.self) {
                            Text(formatAxisValue(y))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(hex: 0x475569))
                        }
                    }
                }
            }
            .chartXAxisLabel("Snapshot date", position: .bottom, alignment: .center)
            .chartYAxisLabel(metric.displayLabel, position: .leading, alignment: .center)
            .chartPlotStyle { plotArea in
                plotArea
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(hex: 0xE2E8F0), lineWidth: 1)
                    )
            }
            .frame(height: 278)

            HStack(spacing: 14) {
                exportStat("Start", firstPoint.map { formatValue($0.value) } ?? "—")
                exportStat("Latest", lastPoint.map { formatValue($0.value) } ?? "—")
                exportStat("Change", changeText)
                exportStat("Min / Max", "\(formatValue(minValue)) / \(formatValue(maxValue))")
                exportStat("Avg", formatValue(averageValue))
                Spacer()
                Text("Source: snapshots/summaries · Generated \(exportDateString())")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x64748B))
            }
        }
        .padding(24)
        .frame(width: 848, height: 448)
        .background(Color(hex: 0xF8FAFC))
    }


    private func exportStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(hex: 0x64748B))
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(hex: 0x111827))
        }
    }

    private func formatValue(_ value: Double) -> String {
        if isPercentMetric {
            return "\(String(format: "%.1f", value))%"
        }
        return "\(Int(value.rounded()))"
    }

    private func formatAxisValue(_ value: Double) -> String {
        if isPercentMetric {
            return "\(Int(value.rounded()))%"
        }
        return "\(Int(value.rounded()))"
    }

    private func niceCeiling(_ value: Double) -> Double {
        guard value > 0 else { return 10 }
        let magnitude = pow(10, floor(log10(value)))
        let normalized = value / magnitude
        let nice: Double
        if normalized <= 2 {
            nice = 2
        } else if normalized <= 5 {
            nice = 5
        } else {
            nice = 10
        }
        return nice * magnitude
    }

    private func exportDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}
