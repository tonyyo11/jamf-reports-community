import SwiftUI

/// The Overview's Mobile Devices section: the day's `MobileSummary` as four lines. The header
/// button opens Mobile Devices; the Needs attention line opens the Health Audit.
struct MobileOverviewCard: View {
    let summary: MobileSummary
    /// "Daily summary 2026-10-28": which snapshot the figures come from.
    let subtitle: String
    let onOpen: () -> Void
    let onOpenAudit: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionHeader(title: "Mobile Devices")
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Theme.Text.tertiary(contrast))
                    }
                    Spacer(minLength: 8)
                    PNPButton(title: "Open", icon: "chevron.right", size: .sm, action: onOpen)
                        .help("Open Mobile Devices")
                        .accessibilityLabel("Open Mobile Devices")
                }
                // Two columns fit a half-width card at the minimum window width.
                EqualHeightTileGrid(minTileWidth: 120, spacing: 10, idealColumns: 2) {
                    ForEach(summary.overviewTiles) { tile in
                        if tile.opensAudit {
                            MobileAttentionButton(tile: tile, action: onOpenAudit)
                        } else {
                            MobileOverviewTileView(tile: tile)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct MobileOverviewTileView: View {
    let tile: MobileOverviewTile
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .title) private var valueSize: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tile.label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.Colors.fg)
            Text(tile.value)
                .font(Theme.Fonts.serif(valueSize, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
                .monospacedDigit()
            Mono(text: tile.caption, size: 10.5, color: Theme.Text.tertiary(contrast))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.Colors.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            tile.value == MobileOverviewTile.dash
                ? "\(tile.label): \(tile.caption)"
                : "\(tile.label): \(tile.value), \(tile.caption)")
    }
}

/// The Needs attention line as a button: it shows a gold outline on hover and on keyboard
/// focus, as the Overview's other drill-downs do.
private struct MobileAttentionButton: View {
    let tile: MobileOverviewTile
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            MobileAttentionLabel(tile: tile, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withMotionSafeAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
        .help("Open Health Audit")
        .accessibilityHint("Opens Health Audit")
        .accessibilityAddTraits(.isButton)
    }
}

/// The button's label, a view of its own because `isFocused` is the focus of the view's
/// nearest focusable ancestor, here the button.
private struct MobileAttentionLabel: View {
    let tile: MobileOverviewTile
    let isHovering: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        MobileOverviewTileView(tile: tile)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.Colors.gold.opacity(0.6), lineWidth: 1)
                    .opacity(isHovering || isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            )
    }
}
