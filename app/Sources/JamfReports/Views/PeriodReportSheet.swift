import SwiftUI

/// Builds a period report: choose a window, choose what goes in it, generate.
/// Extension attributes start unselected — their values can identify a device.
struct PeriodReportSheet: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    @State private var rangeChoice: RangeChoice = .lastFullQuarter
    @State private var customStart = Calendar.current.date(
        byAdding: .month, value: -3, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var catalog: [PeriodMetric] = []
    @State private var selected: Set<String> = []
    @State private var isGenerating = false
    @State private var errorText: String?
    @State private var resultPath: String?

    // Resolving the period and the cardinality advisory both read snapshot
    // files from disk (and the config, for the synced-folder check). On a
    // large EA set this is expensive enough that it must be resolved once
    // per period-selection change — see `refreshPeriodDependentState()` —
    // never recomputed from `body`. The resolved period itself is only an
    // intermediate value on the way to `eaAdvisories`, so it stays a local
    // in that function rather than another stored property nothing reads.
    @State private var syncedProvider: CloudStorage.Provider?
    @State private var eaAdvisories: [String: String] = [:]

    private enum RangeChoice: String, CaseIterable, Identifiable {
        case w4 = "4 weeks", w12 = "12 weeks", w26 = "26 weeks", w52 = "52 weeks"
        case lastFullMonth = "Last full month"
        case lastFullQuarter = "Last full quarter"
        case custom = "Custom dates"
        var id: String { rawValue }

        func kind(start: Date, end: Date) -> ReportPeriod.Kind {
            switch self {
            case .w4:  .rolling(weeks: 4)
            case .w12: .rolling(weeks: 12)
            case .w26: .rolling(weeks: 26)
            case .w52: .rolling(weeks: 52)
            case .lastFullMonth: .lastFullMonth
            case .lastFullQuarter: .lastFullQuarter
            case .custom: .explicit(start: start, end: end)
            }
        }
    }

    private var fleetMetrics: [PeriodMetric] { catalog.filter { $0.source == .fleet } }
    private var eaMetrics: [PeriodMetric] {
        catalog.filter { if case .extensionAttribute = $0.source { return true }; return false }
    }

    /// Built from cached `syncedProvider` state — no disk access here, so
    /// this stays a plain computed property safe to read from `body`.
    private var eaSectionCaption: String {
        var text = "Not included unless you choose them. Values come from your own "
                  + "scripts and may identify individual devices."
        if let provider = syncedProvider {
            text += " This report will be written to \(provider.displayName), a synced folder."
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Period report")
                .font(Theme.Fonts.title)
                .foregroundStyle(Theme.Colors.fg)
            Text("Fleet numbers for a window, with a start, an end and the change. "
                 + "Each figure carries the date it came from.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.fgMuted)
                .fixedSize(horizontal: false, vertical: true)

            periodPicker
            Divider().background(Theme.Hairline.standard)
            metricPicker
            if let errorText {
                Text(errorText)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let resultPath {
                Text("Saved to \(resultPath)")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.ok)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 560)
        .background(Theme.Colors.winBG)
        .onAppear(perform: loadCatalog)
        .onChange(of: rangeChoice) { _, _ in refreshPeriodDependentState() }
        .onChange(of: customStart) { _, _ in refreshPeriodDependentState() }
        .onChange(of: customEnd) { _, _ in refreshPeriodDependentState() }
    }

    private var periodPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PERIOD").font(Theme.Fonts.kicker).foregroundStyle(Theme.Colors.fgMuted)
            Picker("", selection: $rangeChoice) {
                ForEach(RangeChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            if rangeChoice == .custom {
                HStack(spacing: 12) {
                    DatePicker("From", selection: $customStart, displayedComponents: .date)
                    DatePicker("To", selection: $customEnd, displayedComponents: .date)
                }
                .font(Theme.Fonts.caption)
            }
        }
    }

    private var metricPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("INCLUDE").font(Theme.Fonts.kicker).foregroundStyle(Theme.Colors.fgMuted)
                Spacer()
                Text("\(selected.count) selected")
                    .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.fgMuted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(fleetMetrics) { metricRow($0, advisory: nil) }
                    if !eaMetrics.isEmpty {
                        Text("EXTENSION ATTRIBUTES")
                            .font(Theme.Fonts.kicker)
                            .foregroundStyle(Theme.Colors.fgMuted)
                            .padding(.top, 8)
                        Text(eaSectionCaption)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(eaMetrics) { metricRow($0, advisory: eaAdvisories[$0.id]) }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    private func metricRow(_ metric: PeriodMetric, advisory: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { selected.contains(metric.id) },
                set: { on in
                    if on { selected.insert(metric.id) } else { selected.remove(metric.id) }
                }
            )) {
                Text(metric.label).font(Theme.Fonts.body()).lineLimit(1)
            }
            .toggleStyle(.checkbox)
            if let advisory {
                Text(advisory)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.gold)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
    }

    private var footer: some View {
        HStack {
            PNPButton(title: "Cancel", style: .ghost) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            PNPButton(
                title: isGenerating ? "Generating..." : "Generate",
                icon: "calendar.badge.clock",
                style: .gold
            ) { generate() }
            .disabled(isGenerating || selected.isEmpty || workspace.demoMode)
            .help(workspace.demoMode ? "Available in live mode only" : "Write the workbook")
        }
    }

    /// The EA name for a metric that is an UNCONFIGURED extension attribute
    /// (no `match` value) — the only kind the identifier advisory applies to.
    private func unconfiguredEAName(of metric: PeriodMetric) -> String? {
        guard case .extensionAttribute(let name, let match) = metric.source, match == nil
        else { return nil }
        return name
    }

    /// Names an attribute whose values are near-unique per device, which is
    /// the shape of a serial or hostname rather than a status. Pure — takes
    /// an already-computed reading rather than reading disk itself, so a row
    /// per EA never triggers its own decode.
    private func advisoryText(for cardinality: (devices: Int, distinct: Int)) -> String? {
        guard PeriodMetricCatalog.looksLikeIdentifier(
            distinct: cardinality.distinct, devices: cardinality.devices)
        else { return nil }
        return "Nearly one value per device — this looks like an identifier, "
             + "so including it puts per-device data in the workbook."
    }

    private func loadCatalog() {
        let profile = workspace.profile
        let found = PeriodReportService.catalog(profile: profile)
        catalog = found
        if selected.isEmpty {
            selected = Set(PeriodReportService.defaultSelection(from: found))
        } else {
            selected = Set(PeriodReportService.pruneSelection(Array(selected), available: found))
        }
        refreshPeriodDependentState()
    }

    /// Resolves the period, the synced-output provider and every EA's
    /// advisory once, from the current picker choice — the only place any of
    /// this touches disk. Called on load and whenever the period selection
    /// changes; `body` only ever reads the cached results.
    ///
    /// Advisories go through `cardinalityBatch`, which loads the period's two
    /// boundary snapshots (or the newest one, with no period) ONCE and shares
    /// them across every attribute — not one pair of loads per attribute.
    private func refreshPeriodDependentState() {
        let profile = workspace.profile
        let kind = rangeChoice.kind(start: customStart, end: customEnd)
        let period = PeriodReportService.resolvedPeriod(profile: profile, kind: kind)
        let outputDir = try? WorkspacePaths.outputDir(for: profile)
        syncedProvider = outputDir.flatMap { CloudStorage.provider(for: $0) }

        let metrics = eaMetrics
        let names = metrics.compactMap { unconfiguredEAName(of: $0) }
        let batch = PeriodReportService.cardinalityBatch(
            profile: profile, eas: names, period: period)
        eaAdvisories = metrics.reduce(into: [:]) { result, metric in
            guard let name = unconfiguredEAName(of: metric), let c = batch[name] else { return }
            result[metric.id] = advisoryText(for: c)
        }
    }

    private func generate() {
        isGenerating = true
        errorText = nil
        resultPath = nil
        let profile = workspace.profile
        let kind = rangeChoice.kind(start: customStart, end: customEnd)
        let ids = Array(selected)
        Task {
            do {
                let url = try PeriodReportService.generate(
                    profile: profile, kind: kind, metricIDs: ids)
                resultPath = url.lastPathComponent
            } catch {
                errorText = error.localizedDescription
            }
            isGenerating = false
        }
    }
}
