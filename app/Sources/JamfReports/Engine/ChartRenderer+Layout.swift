import Foundation
import CoreGraphics
import CoreText

/// What a chart's y axis measures: whole Macs, or a share from 0 to 100.
enum ChartYAxis: Sendable { case count, percent }

/// One legend row entry: a swatch and its label.
struct ChartLegendEntry: Sendable {
    let label: String
    let color: CGColor
}

extension ChartRenderer {

    // MARK: - Style

    enum Style {
        static let titleFont: CGFloat = 16
        static let legendFont: CGFloat = 12
        static let axisFont: CGFloat = 11
        static let noteFont: CGFloat = 11
        static let valueFont: CGFloat = 11
        static let pad: CGFloat = 20
        static let legendRow: CGFloat = 22
        static let swatch: CGFloat = 12
        static let swatchGap: CGFloat = 6
        static let legendItemGap: CGFloat = 20
        static let rightMargin: CGFloat = 30
        /// Inset from both ends of the x axis, so the first and last points sit off the axes.
        static let plotInset: CGFloat = 18
        static let maxDateTicks = 7
    }

    // MARK: - Layout

    /// Where each part of a chart goes. Every draw function takes its coordinates from here,
    /// top to bottom: title, legend rows, y-axis title, plot, x labels, footnote. Nothing
    /// shares a band, so no text can sit on other text.
    struct Layout: Sendable {
        var title: CGRect?
        var legend: [CGRect]
        var axisTitle: CGRect?
        var plot: CGRect
        var xLabelRows: [CGRect]
        var footnote: CGRect?

        /// Every text and plot rect, for the overlap checks in tests.
        var allRects: [CGRect] {
            [title, axisTitle, footnote].compactMap { $0 } + legend + [plot] + xLabelRows
        }
    }

    static func layout(
        size: CGSize,
        title: String?,
        legend: [String],
        yLabel: String?,
        yTickLabels: [String],
        xLabelRowCount: Int,
        footnote: String?
    ) -> Layout {
        var y = Style.pad
        var titleRect: CGRect?
        if let title, !title.isEmpty {
            let h = lineHeight(Style.titleFont)
            let w = min(textWidth(title, fontSize: Style.titleFont, bold: true),
                        size.width - 2 * Style.pad)
            titleRect = CGRect(x: (size.width - w) / 2, y: y, width: w, height: h)
            y += h + 10
        }
        let tickWidth = yTickLabels.map { textWidth($0, fontSize: Style.axisFont) }.max() ?? 0
        let left = max(56, Style.pad + tickWidth + 10)
        let right = size.width - Style.rightMargin

        var legendRects: [CGRect] = []
        if !legend.isEmpty {
            var x = left
            var rowTop = y
            for label in legend {
                let labelWidth = min(textWidth(label, fontSize: Style.legendFont),
                                     right - left - Style.swatch - Style.swatchGap)
                let w = Style.swatch + Style.swatchGap + labelWidth
                if x > left, x + w > right {
                    x = left
                    rowTop += Style.legendRow
                }
                legendRects.append(CGRect(x: x, y: rowTop, width: w, height: lineHeight(Style.legendFont)))
                x += w + Style.legendItemGap
            }
            y = rowTop + Style.legendRow
        }

        var axisTitleRect: CGRect?
        if let yLabel, !yLabel.isEmpty {
            let h = lineHeight(Style.axisFont)
            axisTitleRect = CGRect(x: Style.pad, y: y,
                                   width: textWidth(yLabel, fontSize: Style.axisFont), height: h)
            y += h + 4
        }
        // Half a tick label above the plot top, so the top label stays inside its own band.
        y += lineHeight(Style.axisFont) / 2 + 2

        var bottom = size.height - Style.pad
        var footnoteRect: CGRect?
        if let footnote, !footnote.isEmpty {
            let h = lineHeight(Style.noteFont)
            let w = min(textWidth(footnote, fontSize: Style.noteFont), size.width - left - Style.pad)
            footnoteRect = CGRect(x: left, y: bottom - h, width: w, height: h)
            bottom -= h + 10
        }
        let rowHeight = lineHeight(Style.axisFont) + 4
        let plotBottom = bottom - CGFloat(xLabelRowCount) * rowHeight - 6
        let xRows = (0..<xLabelRowCount).map { i in
            CGRect(x: left, y: plotBottom + 6 + CGFloat(i) * rowHeight,
                   width: right - left, height: rowHeight)
        }
        let plot = CGRect(x: left, y: y, width: right - left, height: max(40, plotBottom - y))
        return Layout(title: titleRect, legend: legendRects, axisTitle: axisTitleRect,
                      plot: plot, xLabelRows: xRows, footnote: footnoteRect)
    }

    // MARK: - Y axis

    /// A y axis from 0 to `top` in steps of `step`, both round numbers.
    struct AxisScale: Equatable, Sendable {
        let top: Double
        let step: Double

        var ticks: [Double] {
            guard step > 0 else { return [0] }
            let n = Int((top / step).rounded())
            return (0...n).map { Double($0) * step }
        }
    }

    /// A count axis gets whole-number steps of 1, 2 or 5 times a power of ten and room above
    /// the largest value; a percent axis runs to 100 unless a value is above it. Never clips:
    /// the top is always at least `maxValue`.
    static func axisScale(maxValue: Double, kind: ChartYAxis) -> AxisScale {
        let value = max(maxValue, 0)
        if kind == .percent, value <= 100 { return AxisScale(top: 100, step: 20) }
        let target = value * 1.1
        guard target > 0 else { return AxisScale(top: 1, step: 1) }
        let raw = target / 5
        let magnitude = pow(10, floor(log10(raw)))
        let nice = [1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? 10 * magnitude
        let step = kind == .count ? max(1, nice.rounded(.up)) : nice
        let top = max((target / step).rounded(.up) * step, step)
        return AxisScale(top: top, step: step)
    }

    static func tickLabel(_ value: Double, kind: ChartYAxis) -> String {
        switch kind {
        case .percent:
            // A percent axis steps by 20 (or more past 100), so a whole number always fits.
            return PercentFormat.whole.text(value)
        case .count:
            let f = NumberFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.numberStyle = .decimal
            f.groupingSeparator = ","
            f.usesGroupingSeparator = true
            f.maximumFractionDigits = 0
            return f.string(from: NSNumber(value: value)) ?? "\(Int(value))"
        }
    }

    // MARK: - Dates

    /// The calendar every chart buckets days with: the one `SummaryJSONParser` and the
    /// snapshot stamps parse in (ISO 8601, this Mac's time zone), so a day's label is the
    /// day its summary names.
    static func chartCalendar() -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }

    /// Up to `maxTicks` labels on whole days from `start` to `end`, one step apart, never two
    /// for the same day.
    static func dateTicks(from start: Date, to end: Date, calendar: Calendar,
                          maxTicks: Int = Style.maxDateTicks) -> [Date] {
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        let days = calendar.dateComponents([.day], from: first, to: last).day ?? 0
        guard days > 0 else { return [first] }
        let step = max(1, Int((Double(days) / Double(max(maxTicks - 1, 1))).rounded(.up)))
        return stride(from: 0, through: days, by: step).compactMap {
            calendar.date(byAdding: .day, value: $0, to: first)
        }
    }

    static func dayLabel(_ date: Date, calendar: Calendar, withYear: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = withYear ? "MMM d, yyyy" : "MMM d"
        return f.string(from: date)
    }

    /// The x position of `day` on a plot that runs from `first` to `last`. One day sits in
    /// the middle.
    static func xPosition(_ day: Date, first: Date, last: Date, plot: CGRect) -> CGFloat {
        let span = last.timeIntervalSince(first)
        guard span > 0 else { return plot.midX }
        let frac = CGFloat(day.timeIntervalSince(first) / span)
        return plot.minX + Style.plotInset + frac * (plot.width - 2 * Style.plotInset)
    }

    static func yPosition(_ value: Double, scale: AxisScale, plot: CGRect) -> CGFloat {
        guard scale.top > 0 else { return plot.maxY }
        return plot.maxY - CGFloat(min(max(value, 0), scale.top) / scale.top) * plot.height
    }

    // MARK: - Text

    static func textWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        textWidth(text, fontSize: fontSize, bold: false)
    }

    static func textWidth(_ text: String, fontSize: CGFloat, bold: Bool) -> CGFloat {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString,
                                        fontSize, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font]
        guard let str = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)
        else { return 0 }
        return CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(str), []).width
    }

    /// The height of one line of Helvetica at `fontSize`: ascent plus descent.
    static func lineHeight(_ fontSize: CGFloat) -> CGFloat {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        return (CTFontGetAscent(font) + CTFontGetDescent(font)).rounded(.up)
    }

    /// `text`, cut with an ellipsis until it fits `maxWidth`.
    static func fitted(_ text: String, fontSize: CGFloat, maxWidth: CGFloat,
                       bold: Bool = false) -> String {
        guard textWidth(text, fontSize: fontSize, bold: bold) > maxWidth else { return text }
        var chars = Array(text)
        while !chars.isEmpty {
            chars.removeLast()
            let candidate = String(chars).trimmingCharacters(in: .whitespaces) + "…"
            if textWidth(candidate, fontSize: fontSize, bold: bold) <= maxWidth { return candidate }
        }
        return "…"
    }
}
