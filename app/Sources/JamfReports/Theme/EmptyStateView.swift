import SwiftUI

/// Reusable empty state component with optional icon, title, message, and action button.
/// Generalizes the pattern from CompliancePostureView and other screens with consistent
/// styling and accessibility support.
struct EmptyStateView: View {
    let icon: Image?
    let title: String
    let message: String
    let primaryAction: EmptyStateAction?

    init(
        icon: Image? = nil,
        title: String,
        message: String,
        primaryAction: EmptyStateAction? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.primaryAction = primaryAction
    }

    /// Convenience initializer for SF Symbol icons
    init(
        systemImage: String,
        title: String,
        message: String,
        primaryAction: EmptyStateAction? = nil
    ) {
        self.icon = Image(systemName: systemImage)
        self.title = title
        self.message = message
        self.primaryAction = primaryAction
    }

    var body: some View {
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Colors.fg)

            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Colors.fgMuted)

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(message)")
        .accessibilityHint(primaryAction != nil ? "Double-tap to \(primaryAction?.label ?? "")" : "")
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
            title: "No device inventory yet",
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