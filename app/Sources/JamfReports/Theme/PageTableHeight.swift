import SwiftUI

/// Height arithmetic for a `Table` inside a scrolling page, kept apart from the modifier so it
/// can be tested without a view hierarchy.
enum PageTableMetrics {
    /// A table's column header, and a row at the default text size. Larger text makes rows
    /// taller than this, and the table then scrolls a little sooner.
    static let headerHeight: CGFloat = 32
    static let rowHeight: CGFloat = 28
    /// What a page keeps back from the viewport for the card's title and the page's padding, so
    /// a table at its limit still ends above the bottom edge.
    static let reserved: CGFloat = 120

    /// The table's own height when every row is shown, never less than one row's.
    static func contentHeight(rows: Int, rowHeight: CGFloat = rowHeight) -> CGFloat {
        headerHeight + CGFloat(max(rows, 1)) * rowHeight
    }

    /// Every row when they fit in the viewport, otherwise one screenful that scrolls inside.
    /// A table in a `ScrollView` is not offered the page's height, so with a fixed
    /// `minHeight` it showed seven rows and left the rest of a tall window empty; stopping at
    /// the rows it has keeps a short list from drawing empty striped rows.
    static func height(
        rows: Int, rowHeight: CGFloat = rowHeight, viewport: CGFloat
    ) -> CGFloat {
        let content = contentHeight(rows: rows, rowHeight: rowHeight)
        guard viewport.isFinite, viewport > 0 else { return content }
        let screenful = max(viewport - reserved, headerHeight + 3 * rowHeight)
        return min(content, screenful)
    }
}

extension View {
    /// Sizes a `Table` in a `PageScaffold` to its rows, up to the visible height of the page.
    func pageTableHeight(rows: Int, rowHeight: CGFloat = PageTableMetrics.rowHeight) -> some View {
        containerRelativeFrame(.vertical, alignment: .top) { viewport, _ in
            PageTableMetrics.height(rows: rows, rowHeight: rowHeight, viewport: viewport)
        }
    }
}
