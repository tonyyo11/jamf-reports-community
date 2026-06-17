import SwiftUI
import Charts

/// Hero feature — historical trends across 26 weeks of archived snapshots.
/// Differentiator vs. JamfDash, which only shows live state.
struct TrendsView: View {
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("defaultTrendRange") private var defaultTrendRangeRaw: String = TrendRange.w4.rawValue

    // WCAG 1.4.4: Dynamic Type scaling for KPI numerals
    @ScaledMetric(relativeTo: .largeTitle) private var heroMetricSize: CGFloat = 44
    @State private var trendStore = TrendStore()
    @State private var bridge = CLIBridge()
    @State private var metric: TrendSeries.Metric = .stability
    @State private var range: TrendRange = .w4
    @State private var selectedDate: Date? = nil
    @State private var isArchiving = false
    @State private var isExporting = false
    /// Index of the snapshot bar currently hovered, for floating tooltip in archive timeline.
    @State private var hoveredArchiveIdx: Int? = nil
    /// Drives the pulsing "live" indicator on the latest snapshot bar.
    @State private var archivePulse: Bool = false
    /// Drives the danger wash pulse on negative-trend metric pills.
    @State private var pillPulse: Bool = false

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

    /// Y-axis domain that respects the metric's preferred "good frame" but
    /// always expands to fit actual data. Without this, a Stability Index of
    /// 0% disappears below `metric.minY = 40`, and a Stale count of 100+
    /// clips off the top of `metric.maxY = 60`. Floor at 0 — values are
    /// non-negative by construction (validated in the data layer).
    private var chartYDomain: ClosedRange<Double> {
        let dataMin = values.min()
        let dataMax = values.max()
        let lo = max(0, min(metric.minY, dataMin ?? metric.minY))
        let hi = max(metric.maxY, dataMax ?? metric.maxY)
        return lo...hi
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

    /// "Apr 1 → Apr 25 · 12 weeks" — used as the hero header date-range pill.
    private var rangeBadgeText: String {
        let f = SummaryJSONParser.dateFormatter
        guard let first = trendDates.first, let last = trendDates.last else {
            return "No snapshots"
        }
        if first == last {
            return f.string(from: first)
        }
        let weeks = max(
            1,
            Int((last.timeIntervalSince(first) / (7 * 24 * 3600)).rounded())
        )
        let suffix = weeks == 1 ? "1 week" : "\(weeks) weeks"
        return "\(f.string(from: first)) → \(f.string(from: last)) · \(suffix)"
    }

    var body: some View {
        PageScaffold(spacing: 16) {
            if !workspaceStore.demoMode && trendStore.isEmpty {
                emptyState
            } else {
                heroHeader
                // PR-13: shared StaleDataBanner surfaces freshness above
                // the hero chart. Suppressed in demo mode (the demo
                // dataset is intentionally static and not user-perceivably
                // "stale"). Renders nothing when source is .fresh.
                if !workspaceStore.demoMode {
                    CollectNowBanner(source: trendStore.cacheSource, tiers: [.refresh])
                    if let latest = trendStore.filteredSummaries.last {
                        ProvenanceBadge(asOf: latest.date, sources: latest.collectionSources)
                    }
                }
                metricPicker
                heroChart
                comparisonRow
                snapshotArchive
            }
        }
        .onAppear {
            if let preferred = TrendRange(rawValue: defaultTrendRangeRaw), preferred != range {
                range = preferred
            }
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
            defaultTrendRangeRaw = newValue.rawValue
            if !workspaceStore.demoMode {
                withAnimation(.snappy) {
                    trendStore.load(profile: workspaceStore.profile, range: newValue)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            if !workspaceStore.demoMode {
                withAnimation(.snappy) {
                    // `load(profile:range:)` short-circuits on unchanged profile;
                    // `reload()` forces a fresh filesystem scan so the
                    // StaleDataBanner picks up any newly-written summaries.
                    trendStore.reload()
                }
            }
        }
    }

    // MARK: Empty State

    private var emptyState: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "chart.line.uptrend.xyaxis",
                title: "No trend data yet",
                message: "Historical trends populate after 2+ scheduled runs.",
                primaryAction: EmptyStateAction(label: "Go to Schedules", icon: "calendar") {
                    NotificationCenter.default.post(
                        name: .navigateToTab,
                        object: nil,
                        userInfo: ["tab": Tab.schedules.rawValue]
                    )
                }
            )
        }
    }

    // MARK: Header

    private var heroHeader: some View {
        PageHeader(
            kicker: "Trends · \(range.rawValue)",
            breadcrumbs: [Breadcrumb(label: "Overview", action: { navigateToOverview() })],
            title: "Historical Trends",
            subtitle: "Snapshot history from snapshots/summaries · \(trendDates.count) snapshot\(trendDates.count == 1 ? "" : "s")",
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
                    .accessibilityLabel("Export \(metric.displayLabel) trend chart as PNG")
                    .help("Save the current trend chart as a PNG image")
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

    /// Get trend points for a specific metric.
    private func points(for m: TrendSeries.Metric) -> [TrendPoint] {
        workspaceStore.demoMode
            ? TrendDemoSeries.points(for: m, range: range)
            : trendStore.points(metric: m)
    }

    // MARK: Metric picker pills

    private var metricPicker: some View {
        FlowLayout(spacing: 8) {
            ForEach(availableMetrics) { m in
                metricPill(m)
            }
        }
    }

    /// Filter available metrics based on data availability.
    /// .mscpBandTrend only appears when mSCP band history exists.
    /// .securityScore only appears when security score data exists.
    private var availableMetrics: [TrendSeries.Metric] {
        TrendSeries.Metric.allCases.filter { metric in
            switch metric {
            case .mscpBandTrend:
                return trendStore.hasMSCPBandHistory
            case .securityScore:
                // Keep existing logic for security score availability
                return trendStore.points(metric: .securityScore).count > 0
            default:
                return true
            }
        }
    }

    private func metricPill(_ m: TrendSeries.Metric) -> some View {
        let series: [Double]
        let sparkValues: [Double]

        series = points(for: m).map(\.value)
        sparkValues = Array(series.suffix(8))

        let dl = (series.last ?? 0) - (series.first ?? 0)
        let deltaInt = Int(dl.rounded())
        let deltaState: DeltaState = deltaInt > 0 ? .positive : deltaInt < 0 ? .negative : .flat

        // For mSCP band trends, "good" trend is more devices with data (positive)
        let goodTrend = m == .stale ? deltaState == .negative : deltaState == .positive
        let isActive = metric == m
        let color = Color(hex: m.colorHex)
        let isBadTrend = deltaState == .negative && m != .stale && m != .mscpBandTrend

        return Button {
            withAnimation(.snappy(duration: 0.25)) { metric = m }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(m.displayLabel(
                    benchmarkLabel: workspaceStore.complianceBenchmarkLabel,
                    edrAgentName: workspaceStore.edrAgentName
                ))
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.Colors.fg)
                Text(deltaState == .flat ? "±0\(m.unit)" : "\(dl >= 0 ? "+" : "")\(deltaInt)\(m.unit)")
                    .font(Theme.Fonts.mono(10.5, weight: .semibold))
                    .foregroundStyle(
                        deltaState == .flat ? Theme.Text.tertiary(contrast)
                            : (goodTrend ? Theme.Colors.ok : Theme.Colors.danger)
                    )
                if sparkValues.count >= 2 {
                    Sparkline(
                        values: sparkValues,
                        color: deltaState == .flat ? Theme.Colors.gold
                            : (goodTrend ? Theme.Colors.ok : Theme.Colors.danger)
                    )
                    .frame(width: 40, height: 18)
                    .opacity(0.85)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive ? color.opacity(0.14) : Color.white.opacity(0.03))
                    if isBadTrend {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.Colors.danger.opacity(pillPulse ? 0.12 : 0.04))
                    }
                }
            )
            .overlay(alignment: .leading) {
                // Animated left-edge accent bar that slides in on selection.
                if isActive {
                    Rectangle()
                        .fill(color)
                        .frame(width: 2)
                        .padding(.vertical, 4)
                        .clipShape(RoundedRectangle(cornerRadius: 1, style: .continuous))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isActive ? color : Theme.Colors.hairlineStrong, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(metricPillAccessibilityLabel(m, delta: dl, goodTrend: goodTrend))
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .help("Show \(m.displayLabel) trend")
        .onAppear {
            guard !pillPulse, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pillPulse = true
            }
        }
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
                                .font(Theme.Fonts.serif(heroMetricSize, weight: .bold))
                                .foregroundStyle(Theme.Colors.fg)
                                .monospacedDigit()
                                .contentTransition(.numericText(countsDown: delta < 0))
                                .animation(.snappy(duration: 0.35), value: displayVal)

                            if selectedPoint == nil {
                                HStack(spacing: 4) {
                                    Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("\(abs(Int(delta.rounded())))\(metric.unit) (\(String(format: "%.1f", pctDelta))%)")
                                }
                                .font(Theme.Fonts.mono(14, weight: .semibold))
                                .foregroundStyle(deltaIsPositive ? Theme.Colors.ok : Theme.Colors.danger)
                                Pill(text: rangeBadgeText, tone: .muted)
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

                // Swift Charts line + area mark OR stacked area for mSCP bands
                if let domain = chartDomain {
                    Chart {
                        if metric == .mscpBandTrend {
                            // Stacked area chart for mSCP compliance bands
                            let stackedSeries = trendStore.mscpStackedSeries()
                            ForEach(stackedSeries.reversed(), id: \.label) { series in
                                ForEach(Array(series.points.enumerated()), id: \.offset) { _, point in
                                    AreaMark(
                                        x: .value("Date", point.date),
                                        y: .value("Count", point.value),
                                        stacking: .standard
                                    )
                                    .foregroundStyle(Color(cgColor: series.color))
                                    .accessibilityLabel("\(series.label): \(Int(point.value)) devices")
                                }
                            }
                        } else {
                            // Standard line + area chart for other metrics
                            ForEach(Array(trendPoints.enumerated()), id: \.offset) { _, point in
                                AreaMark(x: .value("Date", point.date),
                                         y: .value(metric.displayLabel, point.value))
                                    .foregroundStyle(LinearGradient(
                                        colors: [Color(hex: metric.colorHex).opacity(0.14),
                                                 Color(hex: metric.colorHex).opacity(0.0)],
                                        startPoint: .top, endPoint: .bottom
                                    ))
                                    .interpolationMethod(.monotone)
                                LineMark(x: .value("Date", point.date),
                                         y: .value(metric.displayLabel, point.value))
                                    .foregroundStyle(Color(hex: metric.colorHex))
                                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                    .interpolationMethod(.monotone)

                                // Always-visible data point dots
                                PointMark(x: .value("Date", point.date),
                                          y: .value(metric.displayLabel, point.value))
                                    .foregroundStyle(Color.white)
                                    .symbolSize(36)
                                    .annotation(position: .overlay) {
                                        Circle()
                                            .stroke(Color(hex: metric.colorHex), lineWidth: 2.2)
                                            .frame(width: 8, height: 8)
                                    }
                            }
                        }

                        // Selection indicator (only for non-mSCP metrics)
                        if metric != .mscpBandTrend {
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
                    }
                    .chartXScale(domain: domain)
                    .chartYScale(domain: chartYDomain)
                    .chartXSelection(value: $selectedDate)
                    .chartXAxis {
                        trendXAxisMarks(for: range)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) {
                            AxisGridLine().foregroundStyle(Theme.Colors.hairline)
                            // WCAG 1.4.4: .caption is a Dynamic Type style; scales with text size.
                            AxisValueLabel().font(.caption.monospaced())
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                        }
                    }
                    .frame(height: 260)
                    .animation(.snappy(duration: 0.35), value: metric)
                    .accessibilityLabel(Self.metricTrendChartLabel(metric.displayLabel))
                    .accessibilityChartDescriptor(TrendLineChartDescriptor(
                        title: "\(metric.displayLabel) Trend",
                        seriesName: metric.displayLabel,
                        dates: trendPoints.map(\.date),
                        values: trendPoints.map(\.value),
                        unit: metric.unit
                    ))
                } else {
                    ProgressView().frame(height: 260)
                }

                Divider().background(Theme.Colors.hairline)

                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Rectangle().fill(Color(hex: metric.colorHex)).frame(width: 14, height: 2)
                        Text("Weekly snapshot").font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").font(.system(size: 11))
                        Text("\(trendDates.count) archived summaries").font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    Spacer()
                    PNPButton(title: "Open in Finder", icon: "folder", style: .ghost, size: .sm) {
                        if let dir = try? WorkspacePaths.summariesDir(for: workspaceStore.profile) {
                            SystemActions.openFolder(dir)
                        }
                    }
                    .help("Open the summaries directory where archived summary.json snapshots live.")
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
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    Spacer()
                }
                if workspaceStore.demoMode {
                    stackedBandsChart
                    complianceBandLegend
                } else if trendStore.hasMSCPBandHistory {
                    liveBandsChart
                    liveBandsLegend
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
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
                multilineComparisonChart
                HStack(spacing: 14) {
                    legendDot(color: Theme.Colors.ok, label: "FileVault")
                    legendDot(color: Theme.Colors.gold, label: workspaceStore.complianceBenchmarkLabel ?? "Compliance")
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
                    Text(band.label).font(.caption).foregroundStyle(Theme.Colors.fg2)
                    Text(band.range).font(Theme.Fonts.mono(10.5)).foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
        }
    }

    private var complianceBandUnavailable: some View {
        Card(padding: 24) {
            EmptyStateView(
                systemImage: "chart.bar.doc.horizontal",
                title: "Compliance band history unavailable",
                message: "No ea-results snapshots or summary band data found. Run a collect to populate."
            )
        }
    }

    /// Live stacked-area chart built from `trendStore.mscpStackedSeries()`.
    /// Mirrors the hero chart's mSCP band rendering (AreaMark, stacking: .standard).
    private var liveBandsChart: some View {
        Group {
            if let domain = trendStore.bandChartDomain {
                let stackedSeries = trendStore.mscpStackedSeries()
                Chart {
                    ForEach(stackedSeries.reversed(), id: \.label) { series in
                        ForEach(Array(series.points.enumerated()), id: \.offset) { _, point in
                            AreaMark(
                                x: .value("Date", point.date),
                                y: .value("Count", point.value),
                                stacking: .standard
                            )
                            .foregroundStyle(Color(cgColor: series.color))
                            .accessibilityLabel("\(series.label): \(Int(point.value)) devices")
                        }
                    }
                }
                .chartXScale(domain: domain)
                .chartXAxis { trendXAxisMarks(for: range) }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine().foregroundStyle(Theme.Colors.hairline)
                        AxisValueLabel().font(.caption.monospaced())
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                }
                .frame(height: 200)
                .accessibilityLabel(Self.complianceTrendChartLabel)
            } else {
                complianceBandUnavailable
            }
        }
    }

    /// Band legend for the live stacked-area chart.
    private var liveBandsLegend: some View {
        let series = trendStore.mscpStackedSeries()
        return HStack(spacing: 14) {
            ForEach(series, id: \.label) { s in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(cgColor: s.color))
                        .frame(width: 10, height: 10)
                    Text(s.label).font(.caption).foregroundStyle(Theme.Colors.fg2)
                }
            }
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(color).frame(width: 14, height: 2)
            Text(label).font(.caption).foregroundStyle(Theme.Colors.fg2)
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
                    trendXAxisMarks(for: range)
                }
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 200)
                .accessibilityLabel(Self.complianceTrendChartLabel)
                .accessibilityChartDescriptor(StackedBarChartDescriptor(
                    title: "Compliance Distribution Over Time",
                    dateLabels: dates.map { SummaryJSONParser.dateFormatter.string(from: $0) },
                    bands: DemoData.complianceBands.enumerated().map { bandIdx, band in
                        StackedBarChartDescriptor.Band(
                            name: band.label,
                            dateLabels: dates.map { SummaryJSONParser.dateFormatter.string(from: $0) },
                            values: weeks.map { $0.values[bandIdx] }
                        )
                    }
                ))
            } else {
                ProgressView().frame(height: 200)
            }
        }
    }

    private var multilineComparisonChart: some View {
        Group {
            if let domain = chartDomain {
                Chart {
                    series("FileVault", color: Theme.Colors.ok, points: points(for: .fileVault))
                    series(workspaceStore.complianceBenchmarkLabel ?? "Compliance", color: Theme.Colors.gold, points: points(for: .compliance))
                    series("macOS Current", color: Theme.Colors.info, points: points(for: .osCurrent))
                }
                .chartXScale(domain: domain)
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    trendXAxisMarks(for: range)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine().foregroundStyle(Theme.Colors.hairline)
                        AxisValueLabel().font(.caption.monospaced())
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 200)
                .accessibilityLabel(Self.multilineComparisonChartLabel)
                .accessibilityChartDescriptor(MultiLineChartDescriptor(
                    title: "Security Posture Comparison",
                    seriesList: [
                        .init(name: "FileVault",
                              dates: points(for: .fileVault).map(\.date),
                              values: points(for: .fileVault).map(\.value)),
                        .init(name: workspaceStore.complianceBenchmarkLabel ?? "Compliance",
                              dates: points(for: .compliance).map(\.date),
                              values: points(for: .compliance).map(\.value)),
                        .init(name: "macOS Current",
                              dates: points(for: .osCurrent).map(\.date),
                              values: points(for: .osCurrent).map(\.value)),
                    ]
                ))
            } else {
                ProgressView().frame(height: 200)
            }
        }
    }

    private func metricPillAccessibilityLabel(
        _ m: TrendSeries.Metric,
        delta: Double,
        goodTrend: Bool
    ) -> String {
        let direction = goodTrend ? "improving" : (delta == 0 ? "unchanged" : "declining")
        let deltaStr = "\(delta >= 0 ? "+" : "")\(Int(delta.rounded()))\(m.unit)"
        return "\(m.displayLabel), \(direction), \(deltaStr) change"
    }

    /// X-axis label stride (in days) per range. Holds ~6–13 labels regardless
    /// of how wide the visible window is, so labels don't collide.
    /// `.all` returns 0 as a sentinel — the builder switches to `.automatic`
    /// because the visible span depends on how much history exists.
    private func xAxisStrideDays(for range: TrendRange) -> Int {
        switch range {
        case .w4:  return 7
        case .w12: return 14
        case .w26: return 28
        case .w52: return 56
        case .all: return 0
        }
    }

    /// Date format that scales with range width.
    /// - .w4/.w12: "Apr 1" — month + day
    /// - .w26/.w52: "Apr '26" — month + 2-digit year
    /// - .all: "2026" — year only
    private func xAxisDateFormat(for range: TrendRange) -> Date.FormatStyle {
        switch range {
        case .w4, .w12:
            return .dateTime.month(.abbreviated).day()
        case .w26, .w52:
            return .dateTime.month(.abbreviated).year(.twoDigits)
        case .all:
            return .dateTime.year()
        }
    }

    /// Shared X-axis marks for all three trend charts. Stride scales with
    /// range; `.all` defers to Swift Charts' automatic spacing with a
    /// desired-count hint so multi-year data stays readable.
    @AxisContentBuilder
    private func trendXAxisMarks(for range: TrendRange) -> some AxisContent {
        let format = xAxisDateFormat(for: range)
        // WCAG 1.4.4: .caption.monospaced() is a Dynamic Type style; scales with text size.
        if range == .all {
            AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                AxisValueLabel(format: format)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
        } else {
            AxisMarks(values: .stride(by: .day, count: xAxisStrideDays(for: range))) { _ in
                AxisValueLabel(format: format)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
        }
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

            PointMark(
                x: .value("Date", point.date),
                y: .value(name, point.value)
            )
            .foregroundStyle(Color.white)
            .symbolSize(24)
            .annotation(position: .overlay) {
                Circle()
                    .stroke(color, lineWidth: 1.8)
                    .frame(width: 6, height: 6)
            }
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
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        PNPButton(title: "Show in Finder", icon: "folder", size: .sm) {
                            if let dir = try? WorkspacePaths.summariesDir(for: workspaceStore.profile) {
                                SystemActions.openFolder(dir)
                            }
                        }
                        .help("Open the archived summaries folder so you can inspect or copy snapshot JSON.")
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
                let rangeMax = max(currentMetricValues.max() ?? 1.0, 1.0)
                HStack(spacing: 4) {
                    ForEach(Array(trendDates.enumerated()), id: \.offset) { idx, date in
                        let isLatest = idx == lastIdx
                        let v = currentMetricValues[safe: idx] ?? 0
                        let h = 4 + (v / rangeMax) * 36
                        archiveBar(
                            idx: idx,
                            date: date,
                            value: v,
                            height: h,
                            isLatest: isLatest
                        )
                    }
                }
                .frame(height: 56)
                .padding(.vertical, 8)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: metric)

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
                .foregroundStyle(Theme.Text.tertiary(contrast))
            }
        }
    }
    /// Single archive timeline bar with hover tooltip and (for `isLatest`) a pulsing dot.
    private func archiveBar(
        idx: Int,
        date: Date,
        value: Double,
        height: CGFloat,
        isLatest: Bool
    ) -> some View {
        let isHovered = hoveredArchiveIdx == idx
        return Rectangle()
            .fill(isLatest ? Theme.Colors.gold : Theme.Colors.tealBright)
            .opacity(isLatest ? 1 : 0.6)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) {
                if isLatest {
                    Circle()
                        .fill(Theme.Colors.goldBright)
                        .frame(width: 6, height: 6)
                        .scaleEffect(reduceMotion ? 1.0 : (archivePulse ? 1.4 : 1.0))
                        .opacity(reduceMotion ? 0.9 : (archivePulse ? 0.0 : 0.9))
                        .offset(y: -3)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if isHovered {
                    Text("\(SummaryJSONParser.dateFormatter.string(from: date)) · \(Int(value.rounded()))\(metric.unit)")
                        .font(Theme.Fonts.mono(10))
                        .foregroundStyle(Theme.Colors.fg)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.Colors.winBG2, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
                        )
                        .fixedSize()
                        .offset(y: -28)
                        .zIndex(1)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .onHover { inside in
                hoveredArchiveIdx = inside ? idx : (hoveredArchiveIdx == idx ? nil : hoveredArchiveIdx)
            }
            .onAppear {
                guard isLatest, !archivePulse, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                    archivePulse = true
                }
            }
            .accessibilityLabel(archiveBarLabel(date: date, value: value, isLatest: isLatest))
    }

    private func archiveBarLabel(date: Date, value: Double, isLatest: Bool) -> String {
        let dateStr = SummaryJSONParser.dateFormatter.string(from: date)
        let valueStr = "\(Int(value.rounded()))\(metric.unit)"
        return isLatest
            ? "\(dateStr): \(valueStr), latest snapshot"
            : "\(dateStr): \(valueStr)"
    }

    // MARK: Archive

    private func archiveNow() async {
        let profile = workspaceStore.profile
        isArchiving = true
        workspaceStore.globalStatus = "collect + generate · profile=\(profile)"
        // Status-bar race guard — see AuditView.runAudit comment.
        do {
            let exit = try await bridge.collectThenGenerate(profile: profile, csvPath: nil) { [weak workspaceStore] line in
                Task { @MainActor in
                    guard let workspaceStore, self.isArchiving else { return }
                    workspaceStore.globalStatus = line.text
                }
            }
            isArchiving = false
            workspaceStore.globalStatus = nil
            if exit == 0 {
                workspaceStore.toast = Toast(message: "Archive generated successfully", style: .success)
                withAnimation(.snappy) {
                    // Archive just wrote new files on the same profile — `load`
                    // would short-circuit and leave the chart stale. `reload()`
                    // forces the re-scan.
                    trendStore.reload()
                }
            } else {
                workspaceStore.toast = Toast(message: "Archive failed · exit \(exit)", style: .danger)
            }
        } catch {
            isArchiving = false
            workspaceStore.globalStatus = nil
            AppLogger.cli.error("collectThenGenerate failed: \(error, privacy: .private)")
            workspaceStore.toast = Toast(message: "Archive failed — \(error.localizedDescription)", style: .danger)
        }
    }

    // MARK: Export PNG

    @MainActor
    private func exportChartPNG() async {
        isExporting = true
        defer { isExporting = false }

        let pts = trendPoints
        let m = metric
        let dom = chartDomain

        var subtitle: String?
        if let first = pts.first, let last = pts.last {
            let f = SummaryJSONParser.dateFormatter
            subtitle = first.date == last.date
                ? "\(f.string(from: first.date)) · 1 snapshot"
                : "\(f.string(from: first.date)) → \(f.string(from: last.date)) · \(pts.count) snapshots"
        }

        let exportResult = DashboardChartExport.run(
            title: m.displayLabel,
            subtitle: subtitle,
            suggestedFilename: DashboardChartExport.filename(for: m.displayLabel, profile: workspaceStore.profile)
        ) { ChartExportView(trendPoints: pts, metric: m, domain: dom) }

        if case .failure(let error) = exportResult {
            workspaceStore.toast = Toast(message: error.userMessage, style: .danger)
        }
    }

    // MARK: - Chart accessibility labels (WCAG 1.1.1 / 4.1.2)

    /// VoiceOver container label for the hero metric trend chart. `nonisolated`
    /// so unit tests can call it without inheriting View `@MainActor` isolation.
    nonisolated static func metricTrendChartLabel(_ displayLabel: String) -> String {
        "\(displayLabel) trend over time"
    }

    /// VoiceOver container label for the stacked compliance-band chart.
    nonisolated static let complianceTrendChartLabel = "Compliance trend"

    /// VoiceOver container label for the multi-metric comparison chart.
    /// Static — cannot read workspace config; uses generic label.
    nonisolated static let multilineComparisonChartLabel =
        "Multi-metric comparison: FileVault, Compliance, macOS currency"
}


// MARK: - Helpers

private enum DeltaState { case positive, negative, flat }

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

/// Minimal flow layout for the metric pills row. Uses the `Layout` protocol
/// introduced in macOS 14 (SwiftUI 4), which is the app's minimum deployment target.
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

// MARK: - Chart export content view

/// Chart-only content view used as the body of DashboardChartExport.run.
/// DashboardExportCanvas owns the outer frame, background, title, and footnote.
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
        trendPoints.enumerated().map { idx, pt in ExportPoint(index: idx, date: pt.date, value: pt.value) }
    }

    private var isPercentMetric: Bool { metric.unit == "%" }
    private var lastPoint: ExportPoint? { points.last }
    private var values: [Double] { points.map(\.value) }
    private var minValue: Double { values.min() ?? 0 }
    private var maxValue: Double { values.max() ?? 0 }

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

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    y: .value(metric.displayLabel, point.value)
                )
                .foregroundStyle(LinearGradient(
                    colors: [Color(hex: metric.colorHex).opacity(0.12),
                             Color(hex: metric.colorHex).opacity(0.0)],
                    startPoint: .top, endPoint: .bottom
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
                    .foregroundStyle(Theme.Chart.gridLines.opacity(0.65))
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
                        .foregroundStyle(Theme.Chart.textPrimary)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(hex: metric.colorHex), lineWidth: 1))
                }
            }
        }
        .chartXScale(domain: yDomain)
        .chartYScale(domain: yValueDomain)
        .chartXAxis {
            AxisMarks(values: tickDates) { value in
                AxisGridLine().foregroundStyle(Theme.Chart.borders)
                AxisTick().foregroundStyle(Theme.Chart.gridLines)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(SummaryJSONParser.dateFormatter.string(from: date))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.Chart.textSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Theme.Chart.borders)
                AxisTick().foregroundStyle(Theme.Chart.gridLines)
                AxisValueLabel {
                    if let y = value.as(Double.self) {
                        Text(formatAxisValue(y))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.Chart.textSecondary)
                    }
                }
            }
        }
        .chartXAxisLabel("Snapshot date", position: .bottom, alignment: .center)
        .chartYAxisLabel(metric.displayLabel, position: .leading, alignment: .center)
        .chartPlotStyle { plotArea in
            plotArea.background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Chart.borders, lineWidth: 1))
        }
        .accessibilityHidden(true)
    }

    private func formatValue(_ value: Double) -> String {
        isPercentMetric ? "\(String(format: "%.1f", value))%" : "\(Int(value.rounded()))"
    }

    private func formatAxisValue(_ value: Double) -> String {
        isPercentMetric ? "\(Int(value.rounded()))%" : "\(Int(value.rounded()))"
    }

    private func niceCeiling(_ value: Double) -> Double {
        guard value > 0 else { return 10 }
        let magnitude = pow(10, floor(log10(value)))
        let normalized = value / magnitude
        if normalized <= 2 { return 2 * magnitude }
        if normalized <= 5 { return 5 * magnitude }
        return 10 * magnitude
    }
}
