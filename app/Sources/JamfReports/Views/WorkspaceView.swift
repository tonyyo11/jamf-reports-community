import SwiftUI

/// Top-level Workspace screen — consolidates Config, Customize, Sources, and Backups
/// into a single tabbed container. A workspace-wide Compliance Framework picker lives
/// above the sub-tab bar so it is always visible regardless of the active sub-tab.
struct WorkspaceView: View {

    // MARK: - Sub-tab

    enum Subtab: String, CaseIterable, Identifiable {
        case data       = "data"
        case workbook   = "workbook"
        case sources    = "sources"
        case backups    = "backups"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .data:     "Config"
            case .workbook: "Customize"
            case .sources:  "Sources"
            case .backups:  "Backups"
            }
        }

        var icon: String {
            switch self {
            case .data:     "wrench.and.screwdriver"
            case .workbook: "sparkles"
            case .sources:  "externaldrive"
            case .backups:  "externaldrive.badge.timemachine"
            }
        }
    }

    // MARK: - State

    @State private var subtab: Subtab = .data
    @Environment(WorkspaceStore.self) private var workspace

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            frameworkBar
            subtabPicker
            Divider().background(Theme.Hairline.standard)
            subtabContent
        }
    }

    // MARK: - Compliance Framework bar

    /// Workspace-wide compliance framework selector. Appears above the sub-tab picker
    /// so it is always visible regardless of the active sub-tab. Writes to
    /// `configState.baselineLabel` which is persisted via ConfigService.
    private var frameworkBar: some View {
        @Bindable var ws = workspace
        return HStack(spacing: 10) {
            Text("Compliance Framework")
                .font(Theme.Fonts.mono(11, weight: .semibold))
                .foregroundStyle(Theme.Text.tertiary)
            Menu {
                ForEach(knownFrameworks, id: \.self) { fw in
                    Button {
                        ws.configState.baselineLabel = fw
                        Task { try? await workspace.saveConfig() }
                    } label: {
                        HStack {
                            Text(fw)
                            if ws.configState.baselineLabel == fw {
                                Image(systemName: "checkmark").accessibilityHidden(true)
                            }
                        }
                    }
                    .accessibilityLabel("Select \(fw) framework")
                }
                Divider()
                Button("Custom…") {
                    // Custom entry: user edits via the Config > Thresholds tab
                }
                .disabled(true)
            } label: {
                HStack(spacing: 4) {
                    Text(ws.configState.baselineLabel.isEmpty
                         ? "Not set" : ws.configState.baselineLabel)
                        .font(Theme.Fonts.label)
                        .foregroundStyle(Theme.Text.primary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                        .fill(Theme.Surface.input)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                                .strokeBorder(Theme.Hairline.strong, lineWidth: 0.5)
                        )
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Compliance framework: \(ws.configState.baselineLabel.isEmpty ? "Not set" : ws.configState.baselineLabel)")
            .help("Select compliance framework for thresholds and baselines")
            Spacer()
        }
        .padding(.horizontal, Theme.Metrics.pagePadH)
        .padding(.vertical, 8)
        .background(Theme.Surface.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Hairline.standard).frame(height: 0.5)
        }
    }

    // MARK: - Sub-tab picker

    private var subtabPicker: some View {
        HStack(spacing: 0) {
            ForEach(Subtab.allCases) { tab in
                subtabButton(tab)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Metrics.pagePadH)
        .padding(.top, 6)
        .background(Theme.Surface.raised)
    }

    @ViewBuilder
    private func subtabButton(_ tab: Subtab) -> some View {
        let isActive = subtab == tab
        Button {
            subtab = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(Theme.Fonts.label.weight(.medium))
                    .foregroundStyle(isActive ? Theme.Colors.gold : Theme.Text.tertiary)
                    .accessibilityHidden(true)
                Text(tab.label)
                    .font(Theme.Fonts.label.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Theme.Text.primary : Theme.Text.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                    .fill(isActive ? Theme.Colors.gold.opacity(0.12) : .clear)
            )
            .overlay(alignment: .bottom) {
                if isActive {
                    Rectangle()
                        .fill(Theme.Colors.gold)
                        .frame(height: 2)
                        .offset(y: 3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch to \(tab.label)")
        .help("View \(tab.label.lowercased()) configuration")
    }

    // MARK: - Sub-tab content

    @ViewBuilder
    private var subtabContent: some View {
        switch subtab {
        case .data:     ConfigView()
        case .workbook: CustomizeView()
        case .sources:  SourcesView()
        case .backups:  BackupsView()
        }
    }

    // MARK: - Framework options

    private let knownFrameworks: [String] = [
        "NIST 800-53 Moderate",
        "NIST 800-53 High",
        "DISA STIG",
        "CIS Benchmark",
        "ISO 27001",
    ]
}
