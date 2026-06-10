import SwiftUI
import Charts

struct OverviewView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage("defaultTrendRange") private var defaultTrendRangeRaw: String = TrendRange.w4.rawValue

    // WCAG 1.4.4: Dynamic Type scaling for KPI numerals
    @ScaledMetric(relativeTo: .title) private var summaryKPISize: CGFloat = 22
    @ScaledMetric(relativeTo: .title) private var deviceCountSize: CGFloat = 26
    @State private var bridge = CLIBridge()
    @State private var trendStore = TrendStore()
    @State private var isRunning = false
    /// True while the heavy-tier "Refresh now" prompt's collection is running.
    @State private var isRefreshingHeavyTiers = false
    /// True while the never-fetched banner's "Collect now" first collect runs (#181).
    @State private var isRunningFirstCollect = false
    /// When enabled, "Generate Report" runs a Health Audit before generating so
    /// audit-derived workbook content is current. Shared with GenerateSheet.
    @AppStorage("includeAuditInGenerate") private var includeAuditInGenerate = false
    /// T-13 fingerprints captured from the live generate log so the success
    /// toast can surface the first artifact's 12-char short hash. Cleared
    /// after each run completes. PR-15.
    @State private var generatedHashes: [String: String] = [:]
    @State private var activitySelection: DeviceInventoryRecord.ID? = nil
    @State private var navigationPath = NavigationPath()
    @State private var legacyWorkspaces: [String] = []
    @State private var legacySchedules: [String] = []

    private var defaultTrendRange: TrendRange {
        TrendRange(rawValue: defaultTrendRangeRaw) ?? .w4
    }

    /// Single source of truth for "fleet total" denominators used by
    /// security-agent cards, the failing-rules subtitle, and other
    /// coverage math on this screen.
    ///
    /// - Demo mode: the canonical demo fleet total (DemoData.totalDevices,
    ///   currently 524, derived from `totalDevicesTrend`).
    /// - Live mode: the most recent trend-summary total devices, or `0`
    ///   if no trend data has been collected yet. `0` signals "unknown"
    ///   to the helpers, which render a placeholder rather than
    ///   nonsensical math like "47 / 0".
    ///
    /// M-02 fix: replaces a hardcoded `502` literal that was internally
    /// inconsistent with the rest of demo mode (other tiles already use
    /// 524).
    private var overviewFleetCount: Int {
        if workspace.demoMode {
            return DemoData.totalDevices
        }
        return trendStore.filteredSummaries.last?.totalDevices ?? 0
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if !workspace.demoMode, !workspace.isWorkspaceInitialized {
                        workspaceInitBanner
                    }
                    migrationBanner
                    // PR-13: shared StaleDataBanner surfaces freshness above
                    // the KPI grid. Suppressed in demo mode (canonical demo
                    // dataset is intentionally static). Renders nothing when
                    // source is .fresh. #181: never-fetched gains a "Collect
                    // now" action that runs the full first collect.
                    if !workspace.demoMode {
                        StaleDataBanner(
                            source: trendStore.cacheSource,
                            onCollect: { runFirstCollect() },
                            isCollecting: isRunningFirstCollect
                        )
                    }
                    // v2.2.0: heavy-tier (per-device) data missing or older
                    // than a week. Never auto-collected — the button is the
                    // only trigger. Hidden while the never-fetched banner is
                    // up: its "Collect now" already runs every tier, so a
                    // second prompt would be a redundant warn surface.
                    if !workspace.demoMode, !workspace.staleHeavyTiers.isEmpty,
                       trendStore.cacheSource != .neverFetchedLive {
                        heavyTierStalePrompt
                    }
                    statRow
                    if workspace.demoMode {
                        osAndRules
                        securityAgents
                        recentActivity
                    } else {
                        liveWorkspaceState
                    }
                }
                .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                    leading: Theme.Metrics.pagePadH,
                                    bottom: Theme.Metrics.pagePadBottom,
                                    trailing: Theme.Metrics.pagePadH))
            }
            .navigationDestination(for: OverviewDrillDown.self) { destination in
                overviewDetail(destination)
            }
        }
        .tint(Theme.Colors.goldBright)
        .onAppear {
            if !workspace.demoMode {
                // `load` sets profile + range on first appear (required for initial state);
                // `reload` follows unconditionally so re-navigating to Overview picks up
                // any summary files written since the last load — e.g. a same-day
                // proxy→real mSCP upgrade or a background LaunchAgent run that completed
                // while the user was on another tab.
                trendStore.load(profile: workspace.profile, range: defaultTrendRange)
                trendStore.reload()
            }
        }
        .onChange(of: workspace.profile) { _, newValue in
            if !workspace.demoMode {
                trendStore.load(profile: newValue, range: defaultTrendRange)
            }
        }
        .onChange(of: defaultTrendRangeRaw) { _, _ in
            if !workspace.demoMode {
                trendStore.load(profile: workspace.profile, range: defaultTrendRange)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshActiveTab)) { _ in
            workspace.reloadFromDisk()
            if !workspace.demoMode {
                // Same as the Refresh button — `load(profile:range:)` would
                // short-circuit on unchanged profile and leave staleness stale.
                trendStore.reload()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .popToRootNavigation)) { _ in
            if !navigationPath.isEmpty {
                navigationPath = NavigationPath()
            }
        }
    }

    /// Prompt shown when .inventory / .scan data is older than a week.
    /// Mirrors StaleDataBanner's visual language but adds the action button —
    /// heavy collections only ever run when the operator asks.
    private var heavyTierStalePrompt: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(Theme.Colors.warn)
                .accessibilityHidden(true)
            Text(heavyTierStaleMessage)
                .font(.footnote)
                .foregroundStyle(Theme.Colors.warn)
            Spacer(minLength: 8)
            PNPButton(
                title: isRefreshingHeavyTiers ? "Refreshing…" : "Refresh now",
                icon: isRefreshingHeavyTiers ? "hourglass" : "arrow.clockwise"
            ) {
                guard !isRefreshingHeavyTiers else { return }
                Task {
                    isRefreshingHeavyTiers = true
                    defer { isRefreshingHeavyTiers = false }
                    await workspace.runHeavyTierRefresh()
                    trendStore.reload()
                }
            }
            .help("Run the per-device collections now. Can take several minutes on on-prem servers.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.Colors.warn.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.Colors.warn.opacity(0.35), lineWidth: 0.5)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heavyTierStaleMessage)
    }

    private var heavyTierStaleMessage: String {
        let names = workspace.staleHeavyTiers.map(\.displayName).joined(separator: " and ")
        return "\(names) data is missing or more than a week old — "
            + "Patch, Updates, and EA dashboards show stale values."
    }

    /// #181: the never-fetched banner's "Collect now". Full first collect via
    /// the workspace, then reload the trend store so the banner clears as soon
    /// as the first summary.json lands.
    private func runFirstCollect() {
        guard !isRunningFirstCollect else { return }
        Task {
            isRunningFirstCollect = true
            defer { isRunningFirstCollect = false }
            await workspace.runFirstCollect()
            trendStore.reload()
        }
    }

    /// Pops the current drill-down off the NavigationStack. Called by breadcrumb
    /// "Overview" links inside drill-down detail views. We can't use
    /// `@Environment(\.dismiss)` here because the property is read on the root
    /// `OverviewView`; closures captured at that scope dismiss the root, which
    /// on a top-level macOS window closes the window itself.
    private func popDrillDown() {
        guard !navigationPath.isEmpty else { return }
        navigationPath.removeLast()
    }

    private var workspaceInitBanner: some View {
        Card(padding: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Colors.gold)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Configuration incomplete")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.Colors.fg)
                    Text(workspace.workspaceInitMessage ?? workspaceInitDefaultMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if workspace.isInitializingWorkspace {
                    ProgressView().controlSize(.small)
                } else {
                    PNPButton(title: "Initialize", style: .gold, size: .sm) {
                        Task { await workspace.initializeWorkspace() }
                    }
                    .help("Create the workspace directory and seed it with a default config.yaml.")
                }
            }
        }
    }

    private var workspaceInitDefaultMessage: String {
        guard let url = ProfileService.workspaceURL(for: workspace.profile) else {
            return "Invalid workspace profile. Choose another profile or rename it in jamf-cli."
        }
        let config = url.appendingPathComponent("config.yaml")
        if FileManager.default.fileExists(atPath: url.path) {
            return "\(config.path) is missing. Initialize it to seed config.yaml and helper folders."
        }
        return "\(url.path) does not exist yet. Initialize it to seed config.yaml and helper folders."
    }

    private var migrationBanner: some View {
        MigrationBanner(
            legacyWorkspaces: legacyWorkspaces,
            legacySchedules: legacySchedules,
            onDismiss: {
                legacyWorkspaces = []
                legacySchedules = []
            }
        )
        .onAppear(perform: loadLegacyItems)
    }

    private func loadLegacyItems() {
        legacyWorkspaces = ProfileService.dottedLegacyWorkspaces()
        legacySchedules = LaunchAgentService.dottedLegacyAgents().map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
    }

    private var liveWorkspaceState: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Live Workspace")
                    Spacer()
                    Pill(text: workspace.profile, tone: .gold)
                }

                HStack(spacing: 12) {
                    liveStateTile(
                        label: "jamf-cli",
                        value: workspace.jamfCLIVersion ?? "Missing",
                        sub: workspace.jamfCLIPath ?? "Not found",
                        ok: workspace.jamfCLIPath != nil
                    )
                    liveStateTile(
                        label: "Trend summaries",
                        value: "\(trendStore.filteredSummaries.count)",
                        sub: "~/Jamf-Reports/\(workspace.profile)/",
                        ok: !trendStore.filteredSummaries.isEmpty
                    )
                }

                if trendStore.filteredSummaries.isEmpty {
                    Divider().background(Theme.Colors.hairline)
                    Text("No cached tenant summaries are available for this profile yet.")
                        .font(.footnote)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
        }
    }

    private func liveStateTile(label: String, value: String, sub: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Kicker(text: label, tone: ok ? .teal : .muted)
            Text(value)
                .font(Theme.Fonts.serif(summaryKPISize, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
                .lineLimit(2)
            Mono(text: sub, size: 10.5, color: Theme.Text.tertiary(contrast))
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(ok ? Theme.Colors.hairlineStrong : Theme.Colors.warn.opacity(0.45), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var header: some View {
        PageHeader(
            kicker: workspace.demoMode ? "Snapshot · Apr 25, 2026 · 09:14" : "Snapshot · \(trendStore.filteredSummaries.last?.date ?? "No Data")",
            title: "\(workspace.org.name) Fleet Overview",
            subtitle: workspace.demoMode ? "524 Macs across 8 departments · 3 sites · \(workspace.complianceBenchmarkLabel ?? "Compliance Benchmark") baseline" : "\(trendStore.filteredSummaries.last?.totalDevices ?? 0) Macs · \(workspace.complianceBenchmarkLabel ?? "Compliance Benchmark") baseline",
            lastModified: workspace.demoMode ? Calendar.current.date(from: DateComponents(year: 2026, month: 4, day: 25)) : trendStore.filteredSummaries.last?.parsedDate
        ) {
            AnyView(
                HStack(spacing: 8) {
                    PNPButton(title: "Refresh", icon: "arrow.clockwise") {
                        workspace.reloadFromDisk()
                        if !workspace.demoMode {
                            // `load(profile:range:)` short-circuits when the profile
                            // hasn't changed (the common case for an explicit Refresh
                            // click); `reload()` forces a fresh filesystem scan so
                            // the StaleDataBanner picks up any newly-written summaries.
                            trendStore.reload()
                        }
                    }
                    .help("Reload workspace state and trend snapshots from disk. Doesn't run jamf-cli.")
                    PNPButton(
                        title: isRunning ? "Running…" : "Generate Report",
                        icon: isRunning ? "hourglass" : "play.fill",
                        style: .gold
                    ) {
                        guard !isRunning else { return }
                        Task { await runGenerate() }
                    }
                }
            )
        }
    }

    private func runGenerate() async {
        guard ProfileService.isValid(workspace.profile) else {
            workspace.toast = Toast(message: "Invalid profile name — generate aborted", style: .danger)
            return
        }

        let profile = workspace.profile
        guard workspace.setRunInProgress(for: profile) else {
            workspace.toast = Toast(message: "Another run is already in progress for profile '\(profile)' — skipped", style: .danger)
            return
        }

        isRunning = true
        defer {
            workspace.clearRunInProgress(for: profile)
            isRunning = false
        }

        let freshnessDecision = await Task.detached(priority: .utility) {
            guard ProfileService.isValid(profile),
                  let dataDir = try? WorkspacePaths.dataDir(for: profile) else {
                return SnapshotFreshness.Decision.noSnapshots
            }
            return SnapshotFreshness.evaluate(dataDir: dataDir)
        }.value

        let shouldSkipCollect: Bool
        switch freshnessDecision {
        case .fresh:
            shouldSkipCollect = true
        case .stale, .noSnapshots:
            shouldSkipCollect = false
        }

        if shouldSkipCollect {
            workspace.globalStatus = "generate from cached snapshots · profile=\(profile)"
        } else {
            workspace.globalStatus = "collect + generate · profile=\(profile)"
        }

        // Status-bar race guard — see HealthCheckView.runAudit comment.
        do {
            // Opt-in audit-before-generate (v2.2.0): refresh Health Audit data
            // so audit-derived workbook content reflects this run, not the
            // last manual audit. Failures warn and continue — a stale audit
            // is preferable to no report.
            if includeAuditInGenerate && !workspace.demoMode {
                workspace.globalStatus = "health audit · profile=\(profile)"
                do {
                    _ = try await bridge.audit(profile: profile, category: nil) { [weak workspace] line in
                        Task { @MainActor in
                            guard let workspace, self.isRunning else { return }
                            workspace.globalStatus = line.text
                        }
                    }
                } catch {
                    AppLogger.cli.warning(
                        "Pre-generate audit failed; continuing with cached audit data: \(error.localizedDescription, privacy: .private)"
                    )
                }
            }

            let exit: Int32
            if shouldSkipCollect {
                // Emit a durable-intent message through the live log channel so the
                // skip reason is visible in globalStatus and any log viewer that reads
                // this stream. True Runs-log durability (writing to automation/logs/)
                // requires CLIBridge-side emit, which is outside this change's scope.
                let skipMessage: String
                if case .fresh(let ageMinutes) = freshnessDecision {
                    skipMessage = "[info] snapshots are fresh (\(ageMinutes)m old) — skipped collect;" +
                        " Trends will not gain a new data point this run"
                } else {
                    skipMessage = "[info] snapshots are fresh — skipped collect"
                }
                await MainActor.run { workspace.globalStatus = skipMessage }
                AppLogger.cli.info("\(skipMessage, privacy: .public)")

                exit = try await bridge.generate(profile: profile, csvPath: nil) { [weak workspace] line in
                    Task { @MainActor in
                        guard let workspace, self.isRunning else { return }
                        if let parsed = GenerateSheetState.parseSHA256LogLine(line.text) {
                            self.generatedHashes[parsed.filename] = parsed.hash
                        }
                        workspace.globalStatus = line.text
                    }
                }
            } else {
                exit = try await bridge.collectThenGenerate(profile: profile, csvPath: nil) { [weak workspace] line in
                    Task { @MainActor in
                        guard let workspace, self.isRunning else { return }
                        // PR-15: capture T-13 SHA-256 fingerprints from the live log
                        // so the success toast surfaces the same artifact-hash
                        // provenance the Generate sheet shows. Same `[ok] sha256:
                        // <64hex> <basename>` sentinel; parser reused from
                        // GenerateSheetState to avoid drift.
                        if let parsed = GenerateSheetState.parseSHA256LogLine(line.text) {
                            self.generatedHashes[parsed.filename] = parsed.hash
                        }
                        workspace.globalStatus = line.text
                    }
                }
            }
            workspace.globalStatus = nil

            if exit == 0 {
                let suffix = firstFingerprintSummary()
                let message = suffix.isEmpty
                    ? "Report generated successfully"
                    : "Report generated · \(suffix)"
                workspace.toast = Toast(message: message, style: .success)
                workspace.reloadFromDisk()
                generatedHashes.removeAll()
                if !workspace.demoMode {
                    trendStore.reload()
                }
            } else {
                workspace.toast = Toast(message: "Generate failed · exit \(exit)", style: .danger)
                generatedHashes.removeAll()
            }
        } catch {
            workspace.globalStatus = nil
            AppLogger.cli.error("collectThenGenerate failed: \(error, privacy: .private)")
            workspace.toast = Toast(message: "Generate failed — \(error.localizedDescription)", style: .danger)
            generatedHashes.removeAll()
        }
    }

    /// Format the first artifact's 12-char short fingerprint for the toast.
    /// Empty when no `[ok] sha256:` lines were captured (e.g., legacy engine
    /// path or an engine that doesn't emit the T-13 sentinel).
    private func firstFingerprintSummary() -> String {
        guard let first = generatedHashes.first else { return "" }
        let short = String(first.value.prefix(12))
        return "sha256: \(short)…"
    }

    private var statRow: some View {
        // Adaptive grid that collapses to fewer columns at narrow widths rather
        // than cramming tiles into unreadable strips.
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.adaptive(minimum: 220), spacing: 12),
                count: 1
            ),
            spacing: 12
        ) {
            ForEach(workspace.selectedScoreCards) { metric in
                let isDanger = scoreCardTrend(for: metric) == .down && metric != .stale
                NavigationLink(value: OverviewDrillDown.metric(metric.rawValue)) {
                    scoreCard(for: metric)
                        .modifier(StatTileHealthModifier(isDanger: isDanger))
                        .drillDownChrome()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(metric.displayLabel) details")
                .help("Open \(metric.displayLabel) details")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func scoreCardTrend(for metric: TrendSeries.Metric) -> StatTile.Trend {
        let values: [Double] = workspace.demoMode ?
            (metric == .activeDevices ? DemoData.totalDevicesTrend : (DemoData.trends[metric] ?? [])) :
            trendStore.values(metric: metric)
        guard let last = values.last else { return .flat }
        let prev = values.count > 1 ? values[values.count - 2] : last
        let diff = last - prev
        if diff == 0 { return .flat }
        if metric == .stale { return diff < 0 ? .up : .down }
        return diff > 0 ? .up : .down
    }

    private func scoreCard(for metric: TrendSeries.Metric) -> some View {
        let values: [Double] = workspace.demoMode ?
            (metric == .activeDevices ? DemoData.totalDevicesTrend : (DemoData.trends[metric] ?? [])) :
            trendStore.values(metric: metric)

        let lastValue = values.last
        let current = lastValue ?? 0
        let prev = values.count > 1 ? values[values.count - 2] : current
        let diff = current - prev

        let valueStr: String = {
            guard let val = lastValue else { return "--" }
            if metric.unit == "%" {
                return "\(String(format: "%.1f", val))%"
            } else {
                return "\(Int(val))"
            }
        }()

        let deltaStr: String = {
            guard lastValue != nil, values.count >= 2 else { return "No Data" }
            let absDiff = abs(diff)
            if metric.unit == "%" {
                return "\(diff >= 0 ? "+" : "−")\(String(format: "%.1f", absDiff))pp"
            } else {
                return "\(diff >= 0 ? "+" : "−")\(Int(absDiff))"
            }
        }()

        let trend: StatTile.Trend = {
            guard lastValue != nil else { return .flat }
            if diff == 0 { return .flat }
            if metric == .stale {
                return diff < 0 ? .up : .down // lower stale is good (up)
            }
            return diff > 0 ? .up : .down
        }()

        return StatTile(
            label: metric.displayLabel(
                benchmarkLabel: workspace.complianceBenchmarkLabel,
                edrAgentName: workspace.edrAgentName
            ),
            value: valueStr,
            delta: values.count >= 2 ? deltaStr : nil,
            deltaTrend: trend,
            sparkValues: values,
            sparkColor: Color(hex: metric.colorHex)
        )
    }

    // MARK: OS distribution donut + Top failing rules

    private var osAndRules: some View {
        HStack(alignment: .top, spacing: 12) {
            NavigationLink(value: OverviewDrillDown.osDistribution) {
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
                                            .font(.footnote)
                                            .foregroundStyle(o.current ? Theme.Colors.fg : Theme.Text.tertiary(contrast))
                                        Spacer(minLength: 0)
                                        Mono(text: "\(o.count)")
                                        Text("\(String(format: "%.1f", o.pct))%")
                                            .font(Theme.Fonts.mono(11, weight: .semibold))
                                            .foregroundStyle(Theme.Colors.fg)
                                            .frame(minWidth: 44, alignment: .trailing)
                                    }
                                }
                            }
                        }
                    }
                }
                .drillDownChrome()
            }
            .buttonStyle(.plain)
            .help("Open macOS distribution details")
            .frame(maxWidth: .infinity)

            NavigationLink(value: OverviewDrillDown.failingRules) {
                Card(padding: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                SectionHeader(title: "Top Failing Rules")
                                Text(failingRulesSubtitle(baseline: workspace.complianceBenchmarkLabel ?? "Compliance Benchmark", fleetCount: overviewFleetCount))
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.tertiary(contrast))
                            }
                            Spacer()
                            Pill(text: "View all 47", tone: .gold)
                        }
                        failingRulesBars
                    }
                }
                .drillDownChrome()
            }
            .buttonStyle(.plain)
            .help("Open failing rule details")
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
        .accessibilityLabel("macOS distribution donut chart: 73 percent of devices are on the current macOS release")
        .overlay(
            VStack(spacing: 2) {
                Text("73%")
                    .font(Theme.Fonts.serif(deviceCountSize, weight: .bold))
                    .foregroundStyle(Theme.Colors.fg)
                Kicker(text: "On Current")
            }
            .accessibilityHidden(true)
        )
        .accessibilityChartDescriptor(SectorChartDescriptor(
            title: "macOS Distribution",
            unit: "%",
            slices: DemoData.osDistribution.map { .init(label: $0.version, value: $0.pct) }
        ))
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
                        .frame(minWidth: 260, alignment: .leading)
                        .lineLimit(2)
                    GeometryReader { geo in
                        let w = CGFloat(r.fails) / CGFloat(maxFails) * geo.size.width
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(nsColor: NSColor.alternatingContentBackgroundColors[1]))
                                .frame(height: 10)
                            Capsule().fill(Theme.Colors.gold).frame(width: w, height: 10)
                        }
                    }
                    .frame(height: 10)
                    Text("\(r.fails)")
                        .font(Theme.Fonts.mono(11.5, weight: .semibold))
                        .foregroundStyle(Theme.Colors.fg)
                        .frame(minWidth: 36, alignment: .trailing)
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
                        NavigationLink(value: OverviewDrillDown.securityAgent(a.name)) {
                            agentCard(a)
                                .drillDownChrome()
                        }
                        .buttonStyle(.plain)
                        .help("Open \(a.name) details")
                    }
                }
            }
        }
    }

    private func agentCard(_ a: SecurityAgent) -> some View {
        AgentCardView(agent: a, fleetCount: overviewFleetCount)
    }

    // MARK: Recent activity table

    private var recentActivity: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    SectionHeader(title: "Recent Activity")
                    Spacer()
                    Pill(text: "8 of 524", tone: .muted)
                    NavigationLink(value: OverviewDrillDown.recentActivity) {
                        Text("View all")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.Colors.fg)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
                Divider().background(Theme.Colors.hairlineStrong)

                Table(DemoData.deviceSample, selection: $activitySelection) {
                    TableColumn("Device") { d in
                        Text(d.name).font(.callout.weight(.semibold))
                    }
                    TableColumn("Serial") { d in Mono(text: d.serial) }
                    TableColumn("macOS") { d in Mono(text: d.os) }
                    TableColumn("User") { d in
                        Text(d.user).font(.footnote).foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    TableColumn("Department") { d in Text(d.dept).font(.footnote) }
                    TableColumn("FV") { d in
                        Image(systemName: d.fileVault ? "checkmark" : "xmark")
                            .foregroundStyle(d.fileVault ? Theme.Colors.ok : Theme.Colors.danger)
                            .font(.system(size: 11, weight: .bold))
                    }
                    .width(40)
                    TableColumn("Failed Rules") { d in failurePill(d.fails) }
                    TableColumn("Last Seen") { d in
                        Mono(text: d.lastSeen,
                             color: d.lastSeen.contains("day") ? Theme.Colors.warn : Theme.Text.tertiary(contrast))
                    }
                }
                .frame(minHeight: 260)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: DeviceRow.ID.self) { selection in
                    if let id = selection.first, let device = DemoData.deviceSample.first(where: { $0.id == id }) {
                        Button("Copy Serial Number") {
                            SystemActions.copyToClipboard(device.serial)
                        }
                        Button("Copy User Email") {
                            SystemActions.copyToClipboard(device.user)
                        }
                        if let jamfID = device.numericJamfID,
                           let url = workspace.consoleURL(forComputerID: jamfID) {
                            Button("Open in Jamf Pro") {
                                SystemActions.open(url)
                            }
                        }
                    }
                }
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

    @ViewBuilder
    private func overviewDetail(_ destination: OverviewDrillDown) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch destination {
                case .metric(let raw):
                    if let metric = TrendSeries.Metric(rawValue: raw) {
                        metricDetail(metric)
                    }
                case .osDistribution:
                    osDistributionDetail
                case .failingRules:
                    failingRulesDetail
                case .securityAgent(let name):
                    if let agent = DemoData.securityAgents.first(where: { $0.name == name }) {
                        securityAgentDetail(agent)
                    }
                case .recentActivity:
                    recentActivityDetail
                }
            }
            .padding(EdgeInsets(top: Theme.Metrics.pagePadTop,
                                leading: Theme.Metrics.pagePadH,
                                bottom: Theme.Metrics.pagePadBottom,
                                trailing: Theme.Metrics.pagePadH))
        }
        .background(Theme.Colors.winBG)
        // Esc pops the drill-down. Hidden zero-size button with .cancelAction
        // is the canonical SwiftUI pattern — system back-chevron doesn't expose
        // a keyboard-shortcut surface, so we add our own.
        .background {
            Button("", action: popDrillDown)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private func metricDetail(_ metric: TrendSeries.Metric) -> some View {
        let values = metricValues(metric)
        let current = values.last ?? 0
        let first = values.first ?? current
        let previous = values.count > 1 ? values[values.count - 2] : current
        return VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                kicker: metric.displayLabel,
                breadcrumbs: [Breadcrumb(label: "Overview", action: { popDrillDown() })],
                title: metric.displayLabel,
                subtitle: "\(values.count) summaries · \(workspace.profile)"
            )
            HStack(spacing: 12) {
                StatTile(label: "Current", value: metricValueLabel(current, metric: metric))
                StatTile(label: "Previous", value: metricValueLabel(previous, metric: metric))
                StatTile(label: "Change", value: metricDeltaLabel(current - first, metric: metric),
                         sub: "Since first snapshot")
            }
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Snapshot Values")
                    if values.isEmpty {
                        Text("No trend summaries are available for this metric yet.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    } else {
                        Sparkline(values: values, color: Color(hex: metric.colorHex))
                            .frame(height: 90)
                        HStack {
                            Mono(text: "First \(metricValueLabel(first, metric: metric))")
                            Spacer()
                            Mono(text: "Latest \(metricValueLabel(current, metric: metric))",
                                 color: Theme.Colors.goldBright)
                        }
                    }
                    Divider().background(Theme.Colors.hairline)
                    HStack {
                        detailHint(for: metric)
                        Spacer()
                        ForEach(relatedTabs(for: metric), id: \.self) { tab in
                            PNPButton(title: tab.label, icon: tab.sfSymbol, size: .sm) {
                                navigate(to: tab)
                            }
                        }
                    }
                }
            }
        }
    }

    private var osDistributionDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                kicker: "macOS Distribution",
                breadcrumbs: [Breadcrumb(label: "Overview", action: { popDrillDown() })],
                title: "macOS Distribution",
                subtitle: "\(DemoData.osDistribution.reduce(0) { $0 + $1.count }) devices across \(DemoData.osDistribution.count) versions"
            )
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(DemoData.osDistribution) { item in
                        detailProgressRow(
                            label: item.version,
                            value: item.pct,
                            trailing: "\(item.count) · \(String(format: "%.1f", item.pct))%",
                            color: Color(hex: item.colorHex)
                        )
                    }
                    Divider().background(Theme.Colors.hairline)
                    HStack {
                        Text("Use Devices to inspect individual records and filter by OS version.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                        Spacer()
                        PNPButton(title: "Open Devices", icon: Tab.devices.sfSymbol, size: .sm) {
                            navigate(to: .devices)
                        }
                    }
                }
            }
        }
    }

    private var failingRulesDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                kicker: "Top Failing Rules",
                breadcrumbs: [Breadcrumb(label: "Overview", action: { popDrillDown() })],
                title: "Top Failing Rules",
                subtitle: "\(workspace.complianceBenchmarkLabel ?? "Compliance Benchmark") · highest failure counts"
            )
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(DemoData.topFailingRules) { rule in
                        detailProgressRow(
                            label: rule.ruleID,
                            value: Double(rule.fails),
                            maxValue: Double(DemoData.topFailingRules.map(\.fails).max() ?? 1),
                            trailing: "\(rule.fails) devices",
                            color: Theme.Colors.gold
                        )
                    }
                    Divider().background(Theme.Colors.hairline)
                    HStack {
                        Text("Open Health Audit for finding context and remediation guidance.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                        Spacer()
                        PNPButton(title: "Open Health Audit", icon: Tab.audit.sfSymbol, size: .sm) {
                            navigate(to: .audit)
                        }
                    }
                }
            }
        }
    }

    private func securityAgentDetail(_ agent: SecurityAgent) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                kicker: agent.name,
                breadcrumbs: [Breadcrumb(label: "Overview", action: { popDrillDown() })],
                title: agent.name,
                subtitle: "\(agent.installed) installed · mapped from \(agent.column)"
            )
            HStack(spacing: 12) {
                StatTile(label: "Coverage", value: "\(String(format: "%.1f", agent.pct))%")
                StatTile(label: "Installed", value: "\(agent.installed)", sub: overviewFleetCount > 0 ? "of \(overviewFleetCount) tracked devices" : "tracked devices")
                StatTile(label: "Trend", value: agent.trend.rawValue.capitalized)
            }
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    detailProgressRow(
                        label: agent.name,
                        value: agent.pct,
                        trailing: "\(String(format: "%.1f", agent.pct))%",
                        color: agent.pct > 90 ? Theme.Colors.ok : agent.pct > 80 ? Theme.Colors.gold : Theme.Colors.warn
                    )
                    Divider().background(Theme.Colors.hairline)
                    HStack {
                        Text("Open Devices for host-level status, or Config to adjust tracked agent columns.")
                            .font(.footnote)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                        Spacer()
                        PNPButton(title: "Devices", icon: Tab.devices.sfSymbol, size: .sm) {
                            navigate(to: .devices)
                        }
                        PNPButton(title: "Config", icon: Tab.config.sfSymbol, size: .sm) {
                            navigate(to: .config)
                        }
                    }
                }
            }
        }
    }

    private var recentActivityDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                kicker: "Recent Activity",
                breadcrumbs: [Breadcrumb(label: "Overview", action: { popDrillDown() })],
                title: "Recent Activity",
                subtitle: "\(DemoData.deviceSample.count) recent devices from the current snapshot"
            )
            Card(padding: 0) {
                Table(DemoData.deviceSample, selection: $activitySelection) {
                    TableColumn("Device") { d in
                        Text(d.name).font(.callout.weight(.semibold))
                    }
                    TableColumn("Serial") { d in Mono(text: d.serial) }
                    TableColumn("macOS") { d in Mono(text: d.os) }
                    TableColumn("User") { d in
                        Text(d.user).font(.footnote).foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    TableColumn("Failed Rules") { d in failurePill(d.fails) }
                    TableColumn("Last Seen") { d in
                        Mono(text: d.lastSeen,
                             color: d.lastSeen.contains("day") ? Theme.Colors.warn : Theme.Text.tertiary(contrast))
                    }
                }
                .frame(minHeight: 340)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: DeviceRow.ID.self) { selection in
                    if let id = selection.first, let device = DemoData.deviceSample.first(where: { $0.id == id }) {
                        Button("Copy Serial Number") {
                            SystemActions.copyToClipboard(device.serial)
                        }
                        Button("Copy User Email") {
                            SystemActions.copyToClipboard(device.user)
                        }
                        if let jamfID = device.numericJamfID,
                           let url = workspace.consoleURL(forComputerID: jamfID) {
                            Button("Open in Jamf Pro") {
                                SystemActions.open(url)
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                PNPButton(title: "Open Full Device Inventory", icon: Tab.devices.sfSymbol) {
                    navigate(to: .devices)
                }
            }
        }
    }

    private func detailProgressRow(
        label: String,
        value: Double,
        maxValue: Double = 100,
        trailing: String,
        color: Color
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.Colors.fg2)
                .lineLimit(2)
                .frame(minWidth: 260, alignment: .leading)
            GeometryReader { geo in
                let width = maxValue == 0 ? 0 : min(value / maxValue, 1) * geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule().fill(color).frame(width: width)
                }
            }
            .frame(height: 8)
            Mono(text: trailing, color: Theme.Colors.fg)
                .frame(minWidth: 112, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func detailHint(for metric: TrendSeries.Metric) -> some View {
        let latest = trendStore.filteredSummaries.last
        let text: String = switch metric {
        case .stability:
            // Reflect which components feed the index and whether compliance
            // is proxy-backed (4-control estimate vs. real mSCP EA data).
            TrendSeries.stabilityBasis(
                compliancePct: latest?.compliancePct,
                patchPct: latest?.patchPct,
                complianceIsProxy: latest?.complianceIsProxy
            ) ?? "Composite of compliance, patch posture, and stale-device pressure."
        case .activeDevices:
            "Open Devices to inspect records contributing to this count."
        case .compliance:
            latest?.complianceIsProxy == true
                ? "Control-gap proxy (FileVault/SIP/Firewall/Gatekeeper). Configure a Compliance EA for true mSCP banding."
                : "Open Health Audit for controls, findings, and recommendations."
        case .fileVault:
            "Open Devices to inspect FileVault state on individual Macs."
        case .osCurrent:
            "Open Devices to inspect macOS versions and filter inventory."
        case .edrAgent:
            "Open Devices or Config to review security-agent tracking."
        case .stale:
            "Open Devices to focus on stale inventory records."
        case .patch:
            "Open Devices to review devices with patch failures."
        case .securityScore:
            "Weighted composite from Security Posture. Open that tab to see the breakdown."
        case .mscpBandTrend:
            "Per-baseline mSCP compliance band trends over time. Open Compliance Posture for current distribution."
        }
        return Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.Text.tertiary(contrast))
    }

    private func relatedTabs(for metric: TrendSeries.Metric) -> [Tab] {
        switch metric {
        case .stability:
            return [.trends, .audit]
        case .activeDevices, .fileVault, .osCurrent, .stale, .patch:
            return [.devices]
        case .compliance, .securityScore, .mscpBandTrend:
            return [.securityPosture, .compliancePosture]
        case .edrAgent:
            return [.devices, .config]
        }
    }

    private func metricValues(_ metric: TrendSeries.Metric) -> [Double] {
        if workspace.demoMode {
            return metric == .activeDevices
                ? DemoData.totalDevicesTrend
                : (DemoData.trends[metric] ?? [])
        }
        return trendStore.values(metric: metric)
    }

    private func metricValueLabel(_ value: Double, metric: TrendSeries.Metric) -> String {
        metric.unit == "%"
            ? "\(String(format: "%.1f", value))%"
            : "\(Int(value.rounded()))"
    }

    private func metricDeltaLabel(_ value: Double, metric: TrendSeries.Metric) -> String {
        let prefix = value >= 0 ? "+" : "-"
        let absValue = abs(value)
        return metric.unit == "%"
            ? "\(prefix)\(String(format: "%.1f", absValue))pp"
            : "\(prefix)\(Int(absValue.rounded()))"
    }

    private func navigate(to tab: Tab) {
        NotificationCenter.default.post(
            name: .navigateToTab,
            object: nil,
            userInfo: ["tab": tab.rawValue]
        )
    }
}

private enum OverviewDrillDown: Hashable {
    case metric(String)
    case osDistribution
    case failingRules
    case securityAgent(String)
    case recentActivity
}

private extension View {
    func drillDownChrome() -> some View {
        modifier(DrillDownChromeModifier())
    }
}

private struct DrillDownChromeModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.Colors.goldBright)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(10)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .strokeBorder(
                        isHovering ? Theme.Colors.gold.opacity(0.4) : Theme.Colors.hairlineStrong,
                        lineWidth: 0.5
                    )
                    .allowsHitTesting(false)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
    }
}

private struct StatTileHealthModifier: ViewModifier {
    let isDanger: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .fill(isDanger ? Theme.Colors.danger.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .strokeBorder(
                        isDanger ? Theme.Colors.danger.opacity(0.35) : Color.clear,
                        lineWidth: 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
    }
}

struct AgentCardView: View {
    let agent: SecurityAgent
    let fleetCount: Int
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false

    // WCAG 1.4.4: Dynamic Type scaling for KPI numerals
    @ScaledMetric(relativeTo: .title) private var summaryKPISize: CGFloat = 22

    var body: some View {
        let pct = agent.pct
        let isAtRisk = pct < 80
        let barColor: Color = pct > 90 ? Theme.Colors.ok :
                              pct > 80 ? Theme.Colors.gold : Theme.Colors.warn
        let trackColor: Color = isAtRisk ? Theme.Colors.warn.opacity(0.15) : Color.white.opacity(0.05)
        let gap = max(0, fleetCount - agent.installed)

        return VStack(alignment: .leading, spacing: 4) {
            Text(agent.name).font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Colors.fg)
            Text("\(String(format: "%.1f", pct))%")
                .font(Theme.Fonts.serif(summaryKPISize, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
                .monospacedDigit()
            HStack(spacing: 6) {
                Mono(text: agentInstalledOverTotalLabel(installed: agent.installed, fleetCount: fleetCount), size: 10.5)
                if agent.trend == .up {
                    Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Colors.ok)
                        .accessibilityHidden(true)
                }
            }
            ZStack(alignment: .leading) {
                Capsule().fill(trackColor).frame(height: 4)
                GeometryReader { geo in
                    Capsule().fill(barColor).frame(width: geo.size.width * pct / 100, height: 4)
                }
                .frame(height: 4)
            }
            .padding(.top, 4)
            .accessibilityHidden(true)
            if isAtRisk {
                Mono(text: "\(gap) not installed", size: 10, color: Theme.Text.tertiary(contrast))
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.Colors.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(isHovering ? 0.25 : 0), radius: isHovering ? 8 : 0, y: isHovering ? 4 : 0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agentCardAccessibilityLabel(agent: agent, fleetCount: fleetCount))
    }
}

// MARK: - Pure helpers (testable; M-02 regression guard)
//
// AgentCardView previously hardcoded a fleet size of 502 in its progress
// labels, accessibility text, and the "Top Failing Rules" subtitle. The
// helpers below are the single source of truth for those strings and
// take the fleet count as an explicit parameter — a future hardcode
// would fail `OverviewViewFleetCountTests`.

/// Inline label rendered as "<installed> / <fleetCount>" beside an
/// agent's coverage percentage. `fleetCount <= 0` signals "fleet total
/// unknown" (e.g. live mode before any trend snapshot lands) — render
/// the count alone rather than nonsensical "47 / 0".
func agentInstalledOverTotalLabel(installed: Int, fleetCount: Int) -> String {
    guard fleetCount > 0 else { return "\(installed)" }
    return "\(installed) / \(fleetCount)"
}

/// Composite accessibility label announcing coverage and gap.
/// `fleetCount <= 0` omits the "of N installed" and gap clauses.
func agentCardAccessibilityLabel(agent: SecurityAgent, fleetCount: Int) -> String {
    var parts: [String] = [
        "\(agent.name): \(String(format: "%.1f", agent.pct))% coverage",
    ]
    if fleetCount > 0 {
        parts.append("\(agent.installed) of \(fleetCount) installed")
    } else {
        parts.append("\(agent.installed) installed")
    }
    if agent.trend == .up { parts.append("trending up") }
    let gap = max(0, fleetCount - agent.installed)
    if fleetCount > 0, gap > 0 { parts.append("\(gap) not installed") }
    return parts.joined(separator: ", ")
}

/// "Top Failing Rules" card subtitle — "<baseline> · across <N> active devices".
/// `fleetCount <= 0` falls back to the baseline alone rather than
/// "across 0 active devices".
func failingRulesSubtitle(baseline: String, fleetCount: Int) -> String {
    guard fleetCount > 0 else { return baseline }
    return "\(baseline) · across \(fleetCount) active devices"
}
