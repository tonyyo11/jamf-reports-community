import SwiftUI

/// Dismissible sheet shown on the first launch after an app version upgrade.
/// Not shown on fresh installs (where `AppVersionState.lastSeenVersion` is empty)
/// because those users see the post-onboarding customization prompt instead.
struct WhatsNewBanner: View {
    let onDismiss: () -> Void
    let onShowCustomize: () -> Void

    private let highlights: [(icon: String, text: String)] = [
        ("play.circle.fill",    "Generate XLSX, HTML, and PDF from one place — try the new \"Generate\u{2026}\" button"),
        ("arrow.up.arrow.down", "Drag to reorder report sheets in Customize \u{2192} Workbook Preview"),
        ("wand.and.sparkles",   "Personalize your reports with the new wizard (Customize \u{2192} Personalize\u{2026})"),
        ("chart.bar.fill",      "HTML reports now lead with a Compliance Posture tile + non-compliant device list"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.Hairline.strong)
            highlightsList
            Divider().background(Theme.Hairline.strong)
            footer
        }
        .frame(width: 480)
        .background(Theme.Surface.base)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.Colors.goldBright)
                .frame(width: 52, height: 52)
                .background(Theme.Colors.gold.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text("What's new in v\(AppVersionState.currentVersion)")
                    .font(Theme.Fonts.serif(20, weight: .bold))
                    .foregroundStyle(Theme.Text.primary)
                Text("Highlights from the latest release")
                    .font(Theme.Fonts.bodyText)
                    .foregroundStyle(Theme.Text.tertiary)
            }
        }
        .padding(20)
    }

    private var highlightsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(highlights.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.icon)
                        .font(Theme.Fonts.title)
                        .foregroundStyle(Theme.Colors.goldBright)
                        .frame(width: 22, alignment: .center)
                    Text(item.text)
                        .font(Theme.Fonts.bodyText)
                        .foregroundStyle(Theme.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            PNPButton(title: "Dismiss") {
                onDismiss()
            }
            .accessibilityLabel("Dismiss What's New banner")
            .help("Dismiss what's new")

            PNPButton(title: "Show me Customize", icon: "arrow.right", style: .gold) {
                onShowCustomize()
            }
            .accessibilityLabel("Go to Customize screen")
        }
        .padding(16)
    }
}
