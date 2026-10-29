import SwiftUI

/// The Overview's Mobile Devices section: the day's `MobileSummary` figures as tiles. The
/// caller wraps it in its drill-down button, so a click opens Mobile Devices.
struct MobileOverviewCard: View {
    let summary: MobileSummary
    /// "Daily summary 2026-10-28": which snapshot the figures come from.
    let subtitle: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader(title: "Mobile Devices")
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.Text.tertiary(contrast))
                }
                // Two columns fit a half-width card at the minimum window width.
                EqualHeightTileGrid(minTileWidth: 120, spacing: 10, idealColumns: 2) {
                    ForEach(summary.overviewTiles) { MobileOverviewTileView(tile: $0) }
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
