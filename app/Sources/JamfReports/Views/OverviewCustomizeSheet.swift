import SwiftUI

/// Editor for the Overview: which sections show and in what order, and which
/// score cards fill the Score Cards section. Opened from the Overview header,
/// and from Customize Reports.
///
/// Availability is passed in rather than worked out here, so the sheet
/// describes exactly what the Overview behind it is showing.
struct OverviewCustomizeSheet: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var contrast

    /// Why a section has nothing to show on the active profile; nil when it has.
    let unavailable: (OverviewSection) -> OverviewUnavailable?
    /// Whether a score card has a value in the loaded summaries.
    let metricHasData: (TrendSeries.Metric) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.Hairline.standard)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionsCard
                    scoreCardsCard
                }
                .padding(16)
            }
            Divider().background(Theme.Hairline.standard)
            footer
        }
        .frame(minWidth: 520, idealWidth: 580, maxWidth: 680, minHeight: 480, idealHeight: 640)
        .background(Theme.Surface.base)
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.Colors.goldBright)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Customize Overview")
                    .font(.headline)
                    .foregroundStyle(Theme.Colors.fg)
                Text("Pick what the Overview shows and in what order. "
                     + "A section this profile can't fill says what it needs.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Text.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            PNPButton(title: "Reset to Defaults", icon: "arrow.counterclockwise",
                      style: .ghost, size: .sm) {
                workspace.overviewLayout = .standard
                workspace.selectedScoreCards = WorkspaceStore.defaultScoreCards
            }
            .help("Show every section in the standard order, with the four standard score cards.")
            Spacer()
            PNPButton(title: "Done", style: .gold) {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Sections

    /// The AI card is only listed where it can run, like the Overview itself.
    private var listedSections: [OverviewSection] {
        workspace.overviewLayout.order.filter {
            $0 != .aiInsight || ModelAvailability.platformSupported
        }
    }

    private var sectionsCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Sections", style: .body)
                Text("Shown top to bottom beneath the page header and any banners.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                let listed = listedSections
                ForEach(Array(listed.enumerated()), id: \.element) { index, section in
                    sectionRow(section, index: index, listed: listed)
                    if index < listed.count - 1 {
                        Divider().background(Theme.Hairline.standard)
                    }
                }
            }
        }
    }

    private func sectionRow(
        _ section: OverviewSection, index: Int, listed: [OverviewSection]
    ) -> some View {
        let isOn = Binding<Bool>(
            get: { workspace.overviewLayout.isVisible(section) },
            set: { workspace.overviewLayout.setVisible(section, $0) }
        )
        let isLeftOut = !section.availability(in: workspace.environmentComposition).isShown
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: section.sfSymbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.Colors.goldBright)
                .frame(width: 20)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg)
                Text(section.summary)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = section.availability(in: workspace.environmentComposition).reason {
                    leftOutNote(reason)
                } else if let why = unavailable(section) {
                    unavailableNote(why.reason)
                }
            }
            Spacer(minLength: 8)
            moveButtons(
                name: section.title,
                canMoveUp: index > 0,
                canMoveDown: index < listed.count - 1,
                up: { workspace.overviewLayout.swap(section, with: listed[index - 1]) },
                down: { workspace.overviewLayout.swap(section, with: listed[index + 1]) }
            )
            PNPToggle(isOn: isOn, label: "Show \(section.title)")
        }
        .padding(.vertical, 8)
        // The switch still saves the choice for when the environment has the devices.
        .opacity(isLeftOut ? 0.55 : 1)
    }

    // MARK: Score cards

    /// Selected cards in their display order, then the rest; a card the policy
    /// does not offer is left out of both.
    static func scoreCardRows(
        selected: [TrendSeries.Metric], policy: SecurityControlPolicy,
        agents: [TrendSeries.Metric] = [], mobile: [TrendSeries.Metric] = [],
        composition: EnvironmentComposition = .unknown
    ) -> [TrendSeries.Metric] {
        let all = TrendSeries.Metric.allCases + mobile + agents
        let rows = selected + all.filter { !selected.contains($0) }
        return rows.filter { metric in
            if case .agent = metric, !agents.contains(metric) { return false }
            return metric.isOffered(under: policy, in: composition)
        }
    }

    private var scoreCardsCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Score Cards", style: .body)
                Text("Tiles in the Score Cards section, left to right. Each shows the "
                     + "latest daily summary and its change since the one before.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                let rows = Self.scoreCardRows(
                    selected: workspace.selectedScoreCards,
                    policy: workspace.securityPolicy, agents: workspace.agentMetrics,
                    mobile: workspace.demoMode ? [] : TrendSeries.Metric.mobileMetrics,
                    composition: workspace.environmentComposition)
                ForEach(Array(rows.enumerated()), id: \.element) { index, metric in
                    scoreCardRow(metric)
                    if index < rows.count - 1 {
                        Divider().background(Theme.Hairline.standard)
                    }
                }
            }
        }
    }

    private func scoreCardRow(_ metric: TrendSeries.Metric) -> some View {
        // Positions follow the cards on the Overview; the selection keeps the hidden ones.
        let shown = workspace.shownScoreCards
        let position = shown.firstIndex(of: metric)
        let isLast = OverviewScoreCards.isLastOnMobileOnly(
            metric, shown: shown, composition: workspace.environmentComposition)
        let label = metric.displayLabel(
            benchmarkLabel: workspace.complianceBenchmarkLabel,
            edrAgentName: workspace.edrAgentName
        )
        let isOn = Binding<Bool>(
            get: { shown.contains(metric) },
            set: { workspace.setScoreCard(metric, shown: $0) }
        )
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.Colors.fg)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !metricHasData(metric) {
                    unavailableNote("No value in the loaded summaries. \(metric.dataRequirement)")
                }
                if isLast {
                    Text("To remove them, turn off Show Score Cards under Sections.")
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
            }
            Spacer(minLength: 8)
            if let position {
                moveButtons(
                    name: label,
                    canMoveUp: position > 0,
                    canMoveDown: position < shown.count - 1,
                    up: { moveScoreCard(metric, to: shown[safe: position - 1]) },
                    down: { moveScoreCard(metric, to: shown[safe: position + 1]) }
                )
            }
            PNPToggle(isOn: isOn, label: "Show \(label)")
                .disabled(isLast)
        }
        .padding(.vertical, 8)
    }

    private func moveScoreCard(_ metric: TrendSeries.Metric, to neighbour: TrendSeries.Metric?) {
        guard let neighbour else { return }
        workspace.moveScoreCard(metric, to: neighbour)
    }

    // MARK: Shared pieces

    /// A section this environment cannot fill: informational, not a warning.
    private func leftOutNote(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "minus.circle")
                .accessibilityHidden(true)
            Text("Left out: \(reason)")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(Theme.Text.tertiary(contrast))
    }

    private func unavailableNote(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.circle")
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(Theme.Colors.warn)
    }

    private func moveButtons(
        name: String,
        canMoveUp: Bool,
        canMoveDown: Bool,
        up: @escaping () -> Void,
        down: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 2) {
            moveButton(symbol: "chevron.up", label: "Move \(name) up",
                       enabled: canMoveUp, action: up)
            moveButton(symbol: "chevron.down", label: "Move \(name) down",
                       enabled: canMoveDown, action: down)
        }
    }

    private func moveButton(
        symbol: String, label: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.Colors.fg2)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(label)
        .help(label)
    }
}
