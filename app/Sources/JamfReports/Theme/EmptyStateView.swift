import SwiftUI

/// Reusable empty state component with optional icon, title, message, and action button.
/// Generalizes the pattern from CompliancePostureView and other screens with consistent
/// styling and accessibility support.
struct EmptyStateView: View {
    let icon: Image?
    let title: String
    let message: String
    let commands: [String]
    let primaryAction: EmptyStateAction?

    @Environment(\.colorSchemeContrast) private var contrast

    /// The combined label of the title and message. Commands are their own elements, so
    /// each can be read, selected and copied.
    internal var accessibilityLabelText: String {
        [title, message].filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// `jamf-reports collect` for the tiers that collect `kinds` (no `--tiers` when none
    /// maps). `collect` has no default profile, so the profile is always named.
    nonisolated static func collectCommand(profile: String, kinds: [String]) -> String {
        let tiers = Set(kinds.compactMap(CollectionTier.tier(forReport:)))
        let command = "jamf-reports collect \(ProfileName.profileOption(profile))"
        guard !tiers.isEmpty else { return command }
        let list = CollectionTier.allCases.filter(tiers.contains).map(\.rawValue)
        return command + " --tiers " + list.joined(separator: ",")
    }

    init(
        icon: Image? = nil,
        title: String,
        message: String,
        commands: [String] = [],
        primaryAction: EmptyStateAction? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.commands = commands
        self.primaryAction = primaryAction
    }

    /// Convenience initializer for SF Symbol icons
    init(
        systemImage: String,
        title: String,
        message: String,
        commands: [String] = [],
        primaryAction: EmptyStateAction? = nil
    ) {
        self.icon = Image(systemName: systemImage)
        self.title = title
        self.message = message
        self.commands = commands
        self.primaryAction = primaryAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Only the text is one element; the button stays reachable on its own.
            VStack(alignment: .leading, spacing: 8) {
                if let icon = icon {
                    HStack {
                        icon
                            .font(.system(size: 28))
                            .foregroundStyle(Theme.Colors.fgMuted)
                            .accessibilityHidden(true)
                        Spacer()
                    }
                }

                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.Colors.fg)

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.Text.tertiary(contrast))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabelText)

            if !commands.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(commands, id: \.self) { command in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(command)
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.Colors.fgMuted)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                SystemActions.copyToClipboard(command)
                            } label: {
                                Image(systemName: "doc.on.doc").font(.system(size: 11))
                                    .foregroundStyle(Theme.Colors.fgMuted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Copy command")
                            .help("Copy to clipboard")
                        }
                    }
                }
                .padding(.top, 4)
            }

            if let primaryAction = primaryAction {
                HStack {
                    PNPButton(
                        title: primaryAction.label,
                        icon: primaryAction.icon,
                        style: .gold,
                        action: primaryAction.action
                    )
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
    }
}

/// Action configuration for empty state primary button
struct EmptyStateAction {
    let label: String
    let icon: String?
    let action: @MainActor () -> Void

    init(label: String, icon: String? = nil, action: @MainActor @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.action = action
    }
}

#Preview("Basic empty state") {
    Card(padding: 24) {
        EmptyStateView(
            title: "No compliance snapshot yet",
            message: "Run `jamf-cli pro report security` to populate this screen."
        )
    }
    .frame(width: 400)
    .padding()
    .background(Theme.Colors.winBG)
}

#Preview("Empty state with icon") {
    Card(padding: 32) {
        EmptyStateView(
            systemImage: "desktopcomputer.and.arrow.down",
            title: "No computer inventory yet",
            message: "run Generate Report to populate"
        )
    }
    .frame(width: 400)
    .padding()
    .background(Theme.Colors.winBG)
}

#Preview("Empty state with action") {
    Card(padding: 18) {
        EmptyStateView(
            systemImage: "doc.badge.plus",
            title: "No reports yet",
            message: "run Generate from Overview",
            primaryAction: EmptyStateAction(
                label: "Go to Overview",
                icon: "house",
                action: { print("Navigate to Overview") }
            )
        )
    }
    .frame(width: 400)
    .padding()
    .background(Theme.Colors.winBG)
}