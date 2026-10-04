import SwiftUI

/// Line breaking for `WrappingRow`, kept apart from the `Layout` so it can be tested
/// without a view hierarchy.
enum WrappingRowMetrics {
    /// The items on each line, as index ranges, filling a line until the next item would
    /// pass `maxWidth`. An item wider than `maxWidth` gets a line to itself rather than
    /// being dropped, and an infinite `maxWidth` is one line.
    static func lines(widths: [CGFloat], spacing: CGFloat, maxWidth: CGFloat) -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var start = 0
        var lineWidth: CGFloat = 0
        for (index, width) in widths.enumerated() {
            let next = index == start ? width : lineWidth + spacing + width
            if index > start, next > maxWidth {
                lines.append(start..<index)
                start = index
                lineWidth = width
            } else {
                lineWidth = next
            }
        }
        if start < widths.count { lines.append(start..<widths.count) }
        return lines
    }
}

/// A row of fixed-size controls that wraps onto further lines when the proposed width is too
/// narrow, and reports the width it uses. With no width proposed it is one line at its natural
/// width, which is what lets `ViewThatFits` (see `PageHeader`) ask whether the controls fit
/// beside a title before it falls back to this layout under the title.
struct WrappingRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let lines = WrappingRowMetrics.lines(
            widths: sizes.map(\.width), spacing: spacing, maxWidth: proposal.width ?? .infinity)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for line in lines {
            let items = sizes[line]
            width = max(width, items.map(\.width).reduce(0, +)
                + spacing * CGFloat(items.count - 1))
            height += items.map(\.height).max() ?? 0
        }
        return CGSize(width: width, height: height + lineSpacing * CGFloat(lines.count - 1))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let lines = WrappingRowMetrics.lines(
            widths: sizes.map(\.width), spacing: spacing, maxWidth: bounds.width)
        var y = bounds.minY
        for line in lines {
            let lineHeight = sizes[line].map(\.height).max() ?? 0
            var x = bounds.minX
            for index in line {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (lineHeight - sizes[index].height) / 2),
                    proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + spacing
            }
            y += lineHeight + lineSpacing
        }
    }
}
