import SwiftUI

struct CustomizeView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var sheets: [SheetGroup] = []

    // Chart toggle state matches the order in the prototype
    @State private var chartOSAdoption: Bool = true
    @State private var chartComplianceTrend: Bool = true
    @State private var chartDeviceStateTrend: Bool = true
    @State private var chartPerMajor: Bool = true
    @State private var chartSavePNGs: Bool = false

    @State private var applySaved = false
    @State private var saveError: String?
    @State private var showGuide = false

    private static let executiveSheets: Set<String> = [
        "Fleet Overview", "Security Posture", "Compliance", "Patch Compliance",
    ]

    private var enabledCount: Int {
        sheets.flatMap(\.items).filter(\.on).count
    }

    private var totalCount: Int {
        sheets.flatMap(\.items).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let err = saveError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 13))
                        Text("Save failed: \(err)")
                            .font(.footnote)
                            .foregroundStyle(Theme.Text.primary)
                        Spacer()
                        Button {
                            saveError = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.Text.tertiary(contrast))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss error banner")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.red.opacity(0.3), lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                HStack(alignment: .top, spacing: 14) {
                    sheetGroupsList
                    rightRail
                }
            }
            .padding(EdgeInsets(
                top: Theme.Metrics.pagePadTop,
                leading: Theme.Metrics.pagePadH,
                bottom: Theme.Metrics.pagePadBottom,
                trailing: Theme.Metrics.pagePadH
            ))
        }
        .onAppear {
            if sheets.isEmpty { loadFromWorkspace() }
        }
    }

    private func loadFromWorkspace() {
        sheets = workspace.sheetCatalog
        let all = sheets.flatMap(\.items)
        chartOSAdoption = all.first(where: { $0.name == "OS Adoption" })?.on ?? true
        chartComplianceTrend = all.first(where: { $0.name == "Compliance Trend" })?.on ?? true
        chartDeviceStateTrend = all.first(where: { $0.name == "Device State Trend" })?.on ?? true
        // These two are config keys, not sheet toggles, so they come from
        // config.yaml rather than the sheet catalogue. Before 2.7.0 they were
        // never loaded or saved at all — the switches moved and nothing else did.
        let charts = ChartsConfigLoader.load(profile: workspace.profile)
        chartSavePNGs = charts.savePNGs
        chartPerMajor = charts.perMajorCharts
    }

    private var header: some View {
        PageHeader(
            kicker: "Workbook Composition",
            title: "Customize Reports",
            subtitle: "Choose which sheets appear in the generated workbook · \(enabledCount) of \(totalCount) enabled"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    PNPButton(
                        title: "How to customize",
                        icon: "questionmark.circle",
                        style: .ghost,
                        size: .sm
                    ) {
                        showGuide = true
                    }
                    PNPButton(title: "Preset: Executive") {
                        applyExecutivePreset()
                    }
                    PNPButton(
                        title: applySaved ? "Saved" : "Apply",
                        icon: applySaved ? "checkmark.circle" : "checkmark",
                        style: .gold
                    ) {
                        saveError = nil
                        applyAndSave()
                    }
                }
                .sheet(isPresented: $showGuide) {
                    CustomizeGuideSheet()
                }
            )
        }
    }

    // MARK: Left column — sheet groups

    private var sheetGroupsList: some View {
        VStack(spacing: 12) {
            ForEach($sheets) { $group in
                sheetGroupCard(group: $group)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func sheetGroupCard(group: Binding<SheetGroup>) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader(title: group.wrappedValue.group, style: .body)
                    Spacer()
                    Kicker(
                        text: "\(group.wrappedValue.items.filter(\.on).count)/\(group.wrappedValue.items.count)"
                    )
                }
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 6
                ) {
                    ForEach(group.items) { $item in
                        SheetToggleCell(item: $item)
                    }
                }
            }
        }
    }

    // MARK: Right rail

    private var rightRail: some View {
        VStack(spacing: 12) {
            workbookPreviewCard
            scoreCardsCard
            chartsCard
        }
        .frame(width: 260)
    }

    private var scoreCardsCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Overview Score Cards", style: .body)
                    .padding(.bottom, 10)
                
                Text("Choose the metrics to show on the Overview dashboard.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .padding(.bottom, 12)

                // No selection cap — the Overview grid is adaptive and wraps
                // to additional rows as more score cards are enabled.
                ForEach(TrendSeries.Metric.allCases) { metric in
                    let isOn = Binding<Bool>(
                        get: { workspace.selectedScoreCards.contains(metric) },
                        set: { newValue in
                            if newValue {
                                if !workspace.selectedScoreCards.contains(metric) {
                                    workspace.selectedScoreCards.append(metric)
                                }
                            } else {
                                workspace.selectedScoreCards.removeAll { $0 == metric }
                            }
                        }
                    )

                    VStack(spacing: 0) {
                        HStack {
                            Text(metric.displayLabel)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Theme.Text.primary)
                            Spacer()
                            PNPToggle(isOn: isOn)
                        }
                        .padding(.vertical, 6)
                        if metric != TrendSeries.Metric.allCases.last {
                            Divider().background(Theme.Hairline.standard)
                        }
                    }
                }
            }
        }
    }

    private var workbookPreviewCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Workbook Preview", style: .body)

                let enabledSheets = sheets.flatMap(\.items).filter(\.on)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(enabledSheets.enumerated()), id: \.element.id) { idx, item in
                            HStack(spacing: 8) {
                                Mono(
                                    text: "\(idx + 1)",
                                    size: 10,
                                    color: Theme.Text.tertiary(contrast)
                                )
                                .frame(width: 18, alignment: .trailing)
                                Image(systemName: "doc")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.Colors.gold)
                                Text(item.name)
                                    .font(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                                Spacer()
                                Mono(text: item.req, size: 9.5, color: Theme.Text.tertiary(contrast))
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 12)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .background(Theme.Surface.high)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text("Estimated workbook · \(enabledSheets.count) sheets · native charts embedded")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
        }
    }

    private var chartsCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Charts", style: .body)
                    .padding(.bottom, 10)

                chartToggleRow(
                    title: "OS Adoption",
                    detail: "Per-major-version charts",
                    isOn: $chartOSAdoption,
                    hasDivider: true
                )
                chartToggleRow(
                    title: "Compliance Trend",
                    detail: "Failed-rule bands over time",
                    isOn: $chartComplianceTrend,
                    hasDivider: true
                )
                chartToggleRow(
                    title: "Device State Trend",
                    detail: "jamf-cli history",
                    isOn: $chartDeviceStateTrend,
                    hasDivider: true
                )
                chartToggleRow(
                    title: "Per-major macOS charts",
                    detail: "10, 11, 12, 13, 14, 15",
                    isOn: $chartPerMajor,
                    hasDivider: true
                )
                chartToggleRow(
                    title: "Save PNGs alongside xlsx",
                    detail: "Charts/*.png",
                    isOn: $chartSavePNGs,
                    hasDivider: false
                )
            }
        }
    }

    private func chartToggleRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>,
        hasDivider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.Text.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
                Spacer()
                PNPToggle(isOn: isOn)
            }
            .padding(.vertical, 8)
            if hasDivider {
                Divider().background(Theme.Hairline.standard)
            }
        }
    }

    // MARK: Actions

    private func applyExecutivePreset() {
        sheets = sheets.map { group in
            var g = group
            g.items = g.items.map { item in
                var i = item
                i.on = Self.executiveSheets.contains(item.name)
                return i
            }
            return g
        }
        chartOSAdoption = false
        chartComplianceTrend = false
        chartDeviceStateTrend = false
    }

    private func applyAndSave() {
        var updatedSheets = sheets
        let chartNameToToggle: [String: Bool] = [
            "OS Adoption": chartOSAdoption,
            "Compliance Trend": chartComplianceTrend,
            "Device State Trend": chartDeviceStateTrend,
        ]
        for gi in updatedSheets.indices {
            for ii in updatedSheets[gi].items.indices {
                let name = updatedSheets[gi].items[ii].name
                if let toggle = chartNameToToggle[name] {
                    updatedSheets[gi].items[ii].on = toggle
                }
            }
        }
        workspace.sheetCatalog = updatedSheets
        sheets = updatedSheets

        let chartOptions = ChartsOptions(
            savePNGs: chartSavePNGs, perMajorCharts: chartPerMajor
        )
        let profile = workspace.profile
        Task {
            do {
                try await workspace.saveConfig()
                // Written separately: saveConfig round-trips the Config tab's
                // managed keys, which deliberately exclude charts.
                try ChartsConfigWriter.save(chartOptions, profile: profile)
                applySaved = true
                try? await Task.sleep(for: .seconds(2))
                applySaved = false
            } catch {
                AppLogger.ui.warning(
                    "CustomizeView: saveConfig failed: \(error.localizedDescription, privacy: .private)"
                )
                saveError = error.localizedDescription
            }
        }
    }
}

// MARK: - SheetToggleCell

private struct SheetToggleCell: View {
    @Binding var item: SheetItem
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button {
            item.on.toggle()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(item.on ? Theme.Colors.gold.opacity(0.25) : Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(
                                    item.on ? Theme.Colors.gold.opacity(0.6) : Theme.Hairline.strong,
                                    lineWidth: 0.5
                                )
                        )
                        .frame(width: 16, height: 16)
                    if item.on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.Colors.goldBright)
                    }
                }

                Text(item.name)
                    .font(.footnote)
                    .foregroundStyle(item.on ? Theme.Text.primary : Theme.Text.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)

                Mono(
                    text: item.req.uppercased(),
                    size: 9.5,
                    color: Theme.Text.tertiary(contrast)
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                item.on
                    ? Theme.Colors.gold.opacity(0.08)
                    : Color.white.opacity(0.025)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        item.on
                            ? Theme.Colors.gold.opacity(0.35)
                            : Theme.Hairline.standard,
                        lineWidth: 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
