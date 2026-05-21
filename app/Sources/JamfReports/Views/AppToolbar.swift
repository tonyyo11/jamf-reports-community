import SwiftUI

struct AppToolbar: ToolbarContent {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.colorSchemeContrast) private var contrast

    let title: String
    var subtitle: String?

    @State private var breathing = false
    @State private var hoveringChip = false
    @State private var isShowingChipPopover = false
    @State private var isShowingAdminConfirmation = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            breadcrumbView
        }

        ToolbarItemGroup(placement: .primaryAction) {
            profileChip
            refreshButton
            demoModeToggle
        }
    }

    @ViewBuilder
    private var breadcrumbView: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(Theme.Fonts.bodyText.weight(.semibold))
                .foregroundStyle(Theme.Text.primary)

            if let subtitle {
                Text("/")
                    .font(Theme.Fonts.mono(10.5))
                    .tracking(0.6)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                Text(subtitle)
                    .font(Theme.Fonts.mono(10.5))
                    .tracking(0.6)
                    .foregroundStyle(Theme.Text.secondary)
            }
        }
    }

    private var profileChip: some View {
        let isWarn = workspace.jamfCLIPath == nil
        let dotColor = isWarn ? Theme.Colors.warn : Theme.Colors.ok

        return Button {
            isShowingChipPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: dotColor.opacity(0.6), radius: 3)
                    .scaleEffect(isWarn && breathing ? 1.0 : (isWarn ? 0.85 : 1.0))
                    .opacity(isWarn && breathing ? 1.0 : (isWarn ? 0.7 : 1.0))
                    .animation(
                        isWarn
                            ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                            : .default,
                        value: breathing
                    )
                    .onAppear {
                        if isWarn { breathing = true }
                    }
                    .onChange(of: isWarn) { _, newValue in
                        breathing = newValue
                    }
                Text(cliStatusText)
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Text.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.chipRadius, style: .continuous)
                    .fill(workspace.demoMode
                          ? Theme.Colors.gold.opacity(0.08)
                          : Theme.Surface.quiet)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.chipRadius, style: .continuous)
                            .strokeBorder(Theme.Hairline.standard, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("jamf-cli status — click for details")
        .popover(isPresented: $isShowingChipPopover, arrowEdge: .bottom) {
            chipPopover
        }
    }

    private var chipPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("JAMF-CLI PATH")
                    .font(Theme.Fonts.mono(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
                Text(workspace.jamfCLIPath ?? "not found on PATH")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Text.primary)
                    .textSelection(.enabled)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("ADMIN MODE")
                    .font(Theme.Fonts.mono(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Text.tertiary(contrast))

                HStack(spacing: 6) {
                    Button {
                        if !workspace.demoMode {
                            isShowingAdminConfirmation = true
                        }
                    } label: {
                        Text("Limited")
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(workspace.demoMode ? Theme.Text.primary : Theme.Text.tertiary(contrast))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(workspace.demoMode ? Theme.Surface.interactive : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(workspace.demoMode)

                    Button {
                        if workspace.demoMode {
                            isShowingAdminConfirmation = true
                        }
                    } label: {
                        Text("Full Admin")
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(!workspace.demoMode ? Theme.Text.primary : Theme.Text.tertiary(contrast))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(!workspace.demoMode ? Theme.Surface.interactive : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!workspace.demoMode)
                }
            }
        }
        .padding(10)
        .frame(minWidth: 220, alignment: .leading)
        .confirmationDialog(
            "Toggle Admin Mode",
            isPresented: $isShowingAdminConfirmation,
            titleVisibility: .visible
        ) {
            Button(workspace.demoMode ? "Enable Full Admin" : "Switch to Limited") {
                workspace.setDemoMode(!workspace.demoMode)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(workspace.demoMode
                 ? "Full admin mode allows live jamf-cli commands and configuration changes."
                 : "Limited mode shows demo data only. Your workspace remains unchanged.")
        }
    }

    private var refreshButton: some View {
        Button {
            NotificationCenter.default.post(name: .refreshActiveTab, object: nil)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(.borderedProminent)
        .help("Refresh current view")
        .accessibilityLabel("Refresh")
    }

    private var demoModeToggle: some View {
        Button {
            workspace.setDemoMode(!workspace.demoMode)
        } label: {
            Image(systemName: workspace.demoMode ? "eye.slash" : "eye")
                .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(.plain)
        .help(workspace.demoMode ? "Switch to live data" : "Switch to demo mode")
        .accessibilityLabel(workspace.demoMode ? "Switch to live data" : "Switch to demo mode")
    }

    private var cliStatusText: String {
        guard workspace.jamfCLIPath != nil else { return "jamf-cli missing" }
        let version = workspace.jamfCLIVersion ?? "unknown"
        return "jamf-cli \(version) · \(workspace.demoMode ? "demo" : "live")"
    }
}