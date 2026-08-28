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
                        Text("Not included unless you choose them. Values come from your own "
                             + "scripts and may identify individual devices.")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(eaMetrics) { metricRow($0, advisory: advisory(for: $0)) }
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

    /// Names an attribute whose values are near-unique per device, which is the
    /// shape of a serial or hostname rather than a status.
    private func advisory(for metric: PeriodMetric) -> String? {
        guard case .extensionAttribute(let name, let match) = metric.source, match == nil
        else { return nil }
        let c = PeriodReportService.cardinality(profile: workspace.profile, ea: name)
        guard PeriodMetricCatalog.looksLikeIdentifier(distinct: c.distinct, devices: c.devices)
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
