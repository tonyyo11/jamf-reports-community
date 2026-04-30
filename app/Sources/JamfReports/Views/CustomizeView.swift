import SwiftUI

struct CustomizeView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @State private var sheets: [SheetGroup] = []

    // Chart toggle state matches the order in the prototype
    @State private var chartOSAdoption: Bool = true
    @State private var chartComplianceTrend: Bool = true
    @State private var chartDeviceStateTrend: Bool = true
    @State private var chartPerMajor: Bool = true
    @State private var chartSavePNGs: Bool = false

    @State private var applySaved = false

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
    }

    private var header: some View {
        PageHeader(
            kicker: "Workbook Composition",
            title: "Customize Reports",
            subtitle: "Choose which sheets appear in the generated workbook · \(enabledCount) of \(totalCount) enabled"
        ) {
            AnyView(
                HStack(spacing: 8) {
                    PNPButton(title: "Preset: Executive") {
                        applyExecutivePreset()
                    }
                    PNPButton(
                        title: applySaved ? "Saved" : "Apply",
                        icon: applySaved ? "checkmark.circle" : "checkmark",
                        style: .gold
                    ) {
                        applyAndSave()
                    }
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
                    SectionHeader(title: group.wrappedValue.group, size: 13.5)
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
                SectionHeader(title: "Overview Score Cards", size: 13.5)
                    .padding(.bottom, 10)
                
                Text("Select up to 4 metrics for the dashboard.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Colors.fgMuted)
                    .padding(.bottom, 12)

                ForEach(TrendSeries.Metric.allCases) { metric in
                    let isOn = Binding<Bool>(
                        get: { workspace.selectedScoreCards.contains(metric) },
                        set: { newValue in
                            if newValue {
                                if workspace.selectedScoreCards.count < 4 {
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
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.Colors.fg)
                            Spacer()
                            PNPToggle(isOn: isOn)
                                .disabled(!isOn.wrappedValue && workspace.selectedScoreCards.count >= 4)
                                .opacity(!isOn.wrappedValue && workspace.selectedScoreCards.count >= 4 ? 0.5 : 1.0)
                        }
                        .padding(.vertical, 6)
                        if metric != TrendSeries.Metric.allCases.last {
                            Divider().background(Theme.Colors.hairline)
                        }
                    }
                }
            }
        }
    }

    private var workbookPreviewCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Workbook Preview", size: 13.5)

                let enabledSheets = sheets.flatMap(\.items).filter(\.on)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(enabledSheets.enumerated()), id: \.element.id) { idx, item in
                            HStack(spacing: 8) {
                                Mono(
                                    text: "\(idx + 1)",
                                    size: 10,
                                    color: Theme.Colors.fgMuted
                                )
                                .frame(width: 18, alignment: .trailing)
                                Image(systemName: "doc")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.Colors.gold)
                                Text(item.name)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.Colors.fg2)
                                Spacer()
                                Mono(text: item.req, size: 9.5, color: Theme.Colors.fgMuted)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 12)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .background(Theme.Colors.winBG3)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text("Estimated workbook · ~1.1 MB · \(enabledSheets.count) sheets · matplotlib charts embedded")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
        }
    }

    private var chartsCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Charts", size: 13.5)
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.fg)
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
                }
                Spacer()
                PNPToggle(isOn: isOn)
            }
            .padding(.vertical, 8)
            if hasDivider {
                Divider().background(Theme.Colors.hairline)
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

        Task {
            try? await workspace.saveConfig()
            applySaved = true
            try? await Task.sleep(for: .seconds(2))
            applySaved = false
        }
    }
}

// MARK: - SheetToggleCell

private struct SheetToggleCell: View {
    @Binding var item: SheetItem

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
                                    item.on ? Theme.Colors.gold.opacity(0.6) : Theme.Colors.hairlineStrong,
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
                    .font(.system(size: 12.5))
                    .foregroundStyle(item.on ? Theme.Colors.fg : Theme.Colors.fg2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)

                Mono(
                    text: item.req.uppercased(),
                    size: 9.5,
                    color: Theme.Colors.fgMuted
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
                            : Theme.Colors.hairline,
                        lineWidth: 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
