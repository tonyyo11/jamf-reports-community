import SwiftUI

/// Column and row math for `EqualHeightTileGrid`, kept apart from the `Layout`
/// so it can be tested without a view hierarchy.
enum TileGridMetrics {
    /// As many columns as fit at `minTileWidth` — the rule
    /// `GridItem(.adaptive(minimum:))` follows — but no more than there are
    /// tiles, so four tiles on a wide window stretch across the row instead
    /// of leaving empty columns beside them. Never fewer than one.
    static func columns(width: CGFloat, minTileWidth: CGFloat, spacing: CGFloat,
                        count: Int) -> Int {
        guard width.isFinite, width > 0, minTileWidth > 0 else { return 1 }
        let fit = max(1, Int((width + spacing) / (minTileWidth + spacing)))
        return min(fit, max(count, 1))
    }

    /// An equal share of `width` once the gutters between the columns are taken out.
    static func tileWidth(width: CGFloat, columns: Int, spacing: CGFloat) -> CGFloat {
        let count = max(columns, 1)
        return max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    /// The width to claim when the container proposes none: up to
    /// `idealColumns` tiles at their minimum width.
    static func idealWidth(
        count: Int, minTileWidth: CGFloat, spacing: CGFloat, idealColumns: Int
    ) -> CGFloat {
        let columns = max(1, min(count, idealColumns))
        return CGFloat(columns) * minTileWidth + spacing * CGFloat(columns - 1)
    }

    /// One height per row: the tallest tile in it.
    static func rowHeights(_ tileHeights: [CGFloat], columns: Int) -> [CGFloat] {
        let perRow = max(columns, 1)
        return stride(from: 0, to: tileHeights.count, by: perRow).map { start in
            tileHeights[start..<min(start + perRow, tileHeights.count)].max() ?? 0
        }
    }
}

/// Wrapping tile grid whose rows are as tall as their tallest tile.
///
/// `LazyVGrid` sizes each cell to its own content and centres it in the row, so
/// a tile carrying a caption, a sparkline or an extra "not installed" line sat
/// taller than its neighbours and the row's tops no longer lined up. Here every
/// tile in a row is offered the row's height and pinned to its top: a tile
/// that fills it (`StatTile(fillsHeight: true)`, or any view whose background
/// sits outside a `maxHeight: .infinity` frame) matches its neighbours, and
/// anything else keeps its own height without drifting down.
///
/// Columns follow `GridItem(.adaptive(minimum:))` — as many as fit at
/// `minTileWidth`, sharing the width equally — except that there are never
/// more columns than tiles.
struct EqualHeightTileGrid: Layout {
    var minTileWidth: CGFloat = 220
    var spacing: CGFloat = 12
    /// Column cap for an ideal-size query (no usable width proposed).
    var idealColumns: Int = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = resolvedWidth(proposal.width, count: subviews.count)
        let rows = rowHeights(subviews, width: width)
        let gaps = spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: rows.reduce(0, +) + gaps)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        let columns = TileGridMetrics.columns(
            width: bounds.width, minTileWidth: minTileWidth, spacing: spacing,
            count: subviews.count)
        let tileWidth = TileGridMetrics.tileWidth(
            width: bounds.width, columns: columns, spacing: spacing)
        let rows = rowHeights(subviews, width: bounds.width)
        var y = bounds.minY
        for (row, rowHeight) in rows.enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (tileWidth + spacing)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: tileWidth, height: rowHeight)
                )
            }
            y += rowHeight + spacing
        }
    }

    /// A zero, missing or infinite width is a sizing probe, not a real column
    /// width; measuring tiles at it would wrap every caption a letter per line.
    private func resolvedWidth(_ proposed: CGFloat?, count: Int) -> CGFloat {
        if let proposed, proposed.isFinite, proposed > 0 { return proposed }
        return TileGridMetrics.idealWidth(
            count: count, minTileWidth: minTileWidth, spacing: spacing,
            idealColumns: idealColumns)
    }

    private func rowHeights(_ subviews: Subviews, width: CGFloat) -> [CGFloat] {
        let columns = TileGridMetrics.columns(
            width: width, minTileWidth: minTileWidth, spacing: spacing, count: subviews.count)
        let tileWidth = TileGridMetrics.tileWidth(width: width, columns: columns, spacing: spacing)
        let heights = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: tileWidth, height: nil)).height
        }
        return TileGridMetrics.rowHeights(heights, columns: columns)
    }
}
