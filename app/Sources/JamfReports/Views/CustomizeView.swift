import SwiftUI

/// Report options that live outside the Config tab: the two chart settings the
/// workbook reads, and pointers to where the rest of a report's shape is chosen.
///
/// Before 2.8.1 this screen also had a grid of sheet toggles, an Executive preset,
/// a workbook preview and three more chart switches. None of them was saved or
/// read by any generate path, yet Apply then read "Saved" (#207 G9). The app
/// generates the Full Instance template; the command-line tool takes `--template`.
struct CustomizeView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast

    @State private var chartPerMajor: Bool = true
    @State private var chartSavePNGs: Bool = false
    @State private var chartsLoaded = false

    @State private var applySaved = false
    @State private var saveError: String?
    @State private var showGuide = false

    /// The smaller templates `jamf-reports generate --template` accepts; the CLI
    /// refuses `custom`, which needs a sheet list only a GUI could supply.
    private static let cliTemplates: [String] = TemplateResolver.allTemplates
        .map(\.identifier)
        .filter { $0 != FullInstanceTemplate().identifier && $0 != "custom" }

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
                    sheetsCard
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
            guard !chartsLoaded else { return }
            chartsLoaded = true
            loadChartOptions()
        }
    }

    /// Both options are config keys, so they come from config.yaml. Before 2.7.0
    /// they were never loaded or saved at all. Demo mode has no config.yaml to
    /// read, so it shows the defaults.
    private func loadChartOptions() {
        let charts = workspace.demoMode
            ? ChartsOptions.defaults : ChartsConfigLoader.load(profile: workspace.profile)
        chartSavePNGs = charts.savePNGs
        chartPerMajor = charts.perMajorCharts
    }

    private var header: some View {
        PageHeader(
            kicker: "Report Options",
            title: "Customize Reports",
            subtitle: "Chart options for generated workbooks, and where to change "
                + "what else a report shows"
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
                    // Apply writes the chart options into config.yaml, which in
                    // demo mode would create one under the demo profile's name.
                    PNPButton(
                        title: applySaved ? "Saved" : "Apply",
                        icon: applySaved ? "checkmark.circle" : "checkmark",
                        style: .gold
                    ) {
                        saveError = nil
                        applyAndSave()
                    }
                    .disabled(workspace.demoMode)
                    .help(workspace.demoMode ? DemoData.liveOnlyHelp : "")
                }
                .sheet(isPresented: $showGuide) {
                    CustomizeGuideSheet()
                }
            )
        }
    }

    // MARK: Left column — workbook sheets

    /// Which sheets a workbook has is set by its report template, not here.
    private var sheetsCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Workbook sheets", style: .body)
                Text("A workbook generated in the app has every sheet: the Full Instance "
                     + "report. For a shorter one, generate a smaller template with the "
                     + "command-line tool:")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Mono(
                    text: "jamf-reports generate --profile \(workspace.profile) "
                        + "--template executive",
                    size: 11,
                    color: Theme.Text.primary
                )
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                Text("Templates: \(Self.cliTemplates.joined(separator: ", ")).")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                PNPButton(title: "Command-line tool", icon: "terminal", size: .sm) {
                    NotificationCenter.default.post(
                        name: .navigateToTab,
                        object: nil,
                        userInfo: ["tab": Tab.settings.rawValue]
                    )
                }
                .help("Open Settings, where the command-line tool is installed.")
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Right rail

    private var rightRail: some View {
        VStack(spacing: 12) {
            scoreCardsCard
            chartsCard
        }
        .frame(width: 260)
    }

    /// The Overview's score cards and sections are chosen in one editor on the
    /// Overview itself, where it can say which ones this profile can fill.
    /// This card only points there; a second, availability-blind copy of the
    /// toggles would drift from it.
    private var scoreCardsCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Overview", style: .body)
                Text("Score cards and Overview sections — what shows, in what order — "
                     + "are chosen on the Overview. \(workspace.selectedScoreCards.count) "
                     + "score cards selected.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                PNPButton(title: "Customize Overview", icon: "slider.horizontal.3", size: .sm) {
                    workspace.overviewCustomizeRequested = true
                    NotificationCenter.default.post(
                        name: .navigateToTab,
                        object: nil,
                        userInfo: ["tab": Tab.overview.rawValue]
                    )
                }
                .help("Open the Overview with its Customize sheet.")
            }
        }
    }

    private var chartsCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Charts", style: .body)
                    .padding(.bottom, 10)

                chartToggleRow(
                    title: "Per-major macOS charts",
                    detail: "Majors found in the fleet",
                    isOn: $chartPerMajor,
                    hasDivider: true
                )
                chartToggleRow(
                    title: "Save PNGs alongside xlsx",
                    detail: "Charts/*.png",
                    isOn: $chartSavePNGs,
                    hasDivider: false
                )
                Text("The stale-device trend and the compliance bands are set under "
                     + "charts in config.yaml.")
                    .font(.caption)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
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

    private func applyAndSave() {
        guard !workspace.demoMode else { return }
        let chartOptions = ChartsOptions(
            savePNGs: chartSavePNGs, perMajorCharts: chartPerMajor
        )
        let profile = workspace.profile
        Task {
            do {
                // Only the chart options. This screen edits nothing else, so it
                // no longer saves the Config tab's unsaved edits along with them.
                try ChartsConfigWriter.save(chartOptions, profile: profile)
                applySaved = true
                try? await Task.sleep(for: .seconds(2))
                applySaved = false
            } catch {
                AppLogger.ui.warning(
                    "CustomizeView: save failed: \(error.localizedDescription, privacy: .private)"
                )
                saveError = error.localizedDescription
            }
        }
    }
}
