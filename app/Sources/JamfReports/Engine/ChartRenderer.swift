import Foundation
import CoreGraphics
import CoreText
import ImageIO

// MARK: - Chart data types

struct ChartSeries: Sendable {
    let label: String
    let color: CGColor
    let points: [(date: Date, value: Double)]
}

struct BarChartData: Sendable {
    let categories: [String]
    let values: [Double]
    let colors: [CGColor]
    /// A second, grey line under each category label (for example "latest 26.7.3").
    var subLabels: [String]? = nil
    /// Text drawn on or above each bar (for example "2 Macs · 50%").
    var valueLabels: [String]? = nil
}

// MARK: - Chart renderer

/// Renders charts to PNG `Data` using CoreGraphics.
/// No WindowServer dependency — safe for LaunchAgent headless context.
enum ChartRenderer {

    /// Standard chart dimensions: 1200×600 pt, written at 2× (2400×1200 px).
    static let defaultSize = CGSize(width: 1200, height: 600)

    // MARK: - Public entry points

    /// A line chart over days. `yAxis` is required so a percentage never lands on a count
    /// axis. One day of history is drawn as points in the middle with a note saying so.
    static func lineChart(
        series: [ChartSeries],
        yAxis: ChartYAxis,
        size: CGSize = defaultSize,
        title: String? = nil,
        yLabel: String? = nil,
        footnote: String? = nil
    ) -> Data? {
        guard series.contains(where: { !$0.points.isEmpty }) else { return nil }
        return renderToPNG(size: size) { ctx in
            drawLineChart(ctx: ctx, series: series, yAxis: yAxis, size: size, title: title,
                          yLabel: yLabel, footnote: footnote)
        }
    }

    /// A stacked area chart of Mac counts over days. One day is drawn as a stacked column.
    static func stackedAreaChart(
        series: [ChartSeries],
        size: CGSize = defaultSize,
        title: String? = nil,
        yLabel: String? = nil,
        footnote: String? = nil
    ) -> Data? {
        guard series.contains(where: { !$0.points.isEmpty }) else { return nil }
        return renderToPNG(size: size) { ctx in
            drawStackedAreaChart(ctx: ctx, series: series, size: size, title: title,
                                 yLabel: yLabel, footnote: footnote)
        }
    }

    /// A vertical bar chart for one snapshot.
    static func barChart(
        data: BarChartData,
        yAxis: ChartYAxis,
        size: CGSize = defaultSize,
        title: String? = nil,
        yLabel: String? = nil,
        footnote: String? = nil
    ) -> Data? {
        guard !data.categories.isEmpty else { return nil }
        return renderToPNG(size: size) { ctx in
            drawBarChart(ctx: ctx, data: data, yAxis: yAxis, size: size, title: title,
                         yLabel: yLabel, footnote: footnote)
        }
    }

    // MARK: - Donut / ring chart

    /// A single slice in a donut chart.
    struct DonutSlice: Sendable, Identifiable {
        let label: String
        let count: Int
        let pct: Double
        let color: CGColor

        var id: String { label }
    }

    /// Render a donut (ring) chart with a right-side legend.
    ///
    /// Legend rows show `"<label>: N (P%)"` for each slice, top-to-bottom.
    static func donutChart(
        slices: [DonutSlice],
        title: String,
        footer: String? = nil,
        size: CGSize = CGSize(width: 900, height: 480)
    ) -> Data? {
        // Require at least one slice with a positive total to avoid divide-by-zero.
        let total = slices.reduce(0) { $0 + $1.count }
        guard !slices.isEmpty, total > 0 else { return nil }
        return renderToPNG(size: size) { ctx in
            drawDonutChart(ctx: ctx, slices: slices, title: title, footer: footer,
                           size: size, total: total)
        }
    }

    // MARK: - Colours

    static let ink = CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
    static let muted = CGColor(red: 0.38, green: 0.38, blue: 0.38, alpha: 1)
    static let gridColor = CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
    static let axisColor = CGColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1)
    static let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    // MARK: - Line chart drawing

    private static func drawLineChart(
        ctx: CGContext, series: [ChartSeries], yAxis: ChartYAxis, size: CGSize,
        title: String?, yLabel: String?, footnote: String?
    ) {
        let calendar = chartCalendar()
        let byDay = series.map { dailyValues($0, calendar: calendar) }
        let days = byDay.flatMap(\.keys)
        guard let first = days.min(), let last = days.max() else { return }
        let scale = axisScale(maxValue: byDay.flatMap(\.values).max() ?? 0, kind: yAxis)
        let ticks = scale.ticks.map { tickLabel($0, kind: yAxis) }
        let note = joinedNote(footnote, singleDayNote(first: first, last: last, calendar: calendar))
        let lay = layout(size: size, title: title, legend: series.map(\.label), yLabel: yLabel,
                         yTickLabels: ticks, xLabelRowCount: 1, footnote: note)

        drawYAxis(ctx: ctx, plot: lay.plot, scale: scale, labels: ticks)
        drawDateLabels(ctx: ctx, lay: lay, first: first, last: last, calendar: calendar)
        for (s, values) in zip(series, byDay) {
            let pts = values.keys.sorted().map { d in
                CGPoint(x: xPosition(d, first: first, last: last, plot: lay.plot),
                        y: yPosition(values[d] ?? 0, scale: scale, plot: lay.plot))
            }
            guard let start = pts.first else { continue }
            ctx.setStrokeColor(s.color)
            ctx.setLineWidth(2.5)
            if pts.count > 1 {
                ctx.move(to: start)
                for pt in pts.dropFirst() { ctx.addLine(to: pt) }
                ctx.strokePath()
            }
            ctx.setFillColor(s.color)
            let r: CGFloat = pts.count > 1 ? 3.5 : 6
            for pt in pts {
                ctx.fillEllipse(in: CGRect(x: pt.x - r, y: pt.y - r, width: 2 * r, height: 2 * r))
            }
        }
        drawChrome(ctx: ctx, lay: lay, title: title,
                   legend: series.map { ChartLegendEntry(label: $0.label, color: $0.color) },
                   yLabel: yLabel, footnote: note)
    }

    // MARK: - Stacked area chart drawing

    private static func drawStackedAreaChart(
        ctx: CGContext, series: [ChartSeries], size: CGSize,
        title: String?, yLabel: String?, footnote: String?
    ) {
        let calendar = chartCalendar()
        let byDay = series.map { dailyValues($0, calendar: calendar) }
        let days = Set(byDay.flatMap(\.keys)).sorted()
        guard let first = days.first, let last = days.last else { return }
        let totals = days.map { d in byDay.reduce(0) { $0 + ($1[d] ?? 0) } }
        let scale = axisScale(maxValue: totals.max() ?? 0, kind: .count)
        let ticks = scale.ticks.map { tickLabel($0, kind: .count) }
        let note = joinedNote(footnote, singleDayNote(first: first, last: last, calendar: calendar))
        let lay = layout(size: size, title: title, legend: series.map(\.label), yLabel: yLabel,
                         yTickLabels: ticks, xLabelRowCount: 1, footnote: note)

        drawYAxis(ctx: ctx, plot: lay.plot, scale: scale, labels: ticks)
        drawDateLabels(ctx: ctx, lay: lay, first: first, last: last, calendar: calendar)
        // Stacked from the last series up, as the band trend has always drawn it.
        var base = [Date: Double]()
        let columnWidth = min(140, lay.plot.width * 0.2)
        for (s, values) in zip(series, byDay).reversed() {
            ctx.setFillColor(s.color.copy(alpha: 0.75) ?? s.color)
            if days.count == 1 {
                let top = yPosition((base[first] ?? 0) + (values[first] ?? 0), scale: scale, plot: lay.plot)
                let bottom = yPosition(base[first] ?? 0, scale: scale, plot: lay.plot)
                ctx.fill(CGRect(x: lay.plot.midX - columnWidth / 2, y: top,
                                width: columnWidth, height: bottom - top))
            } else {
                let xs = days.map { xPosition($0, first: first, last: last, plot: lay.plot) }
                let tops = days.map {
                    yPosition((base[$0] ?? 0) + (values[$0] ?? 0), scale: scale, plot: lay.plot)
                }
                let bottoms = days.map { yPosition(base[$0] ?? 0, scale: scale, plot: lay.plot) }
                ctx.move(to: CGPoint(x: xs[0], y: tops[0]))
                for i in xs.indices.dropFirst() { ctx.addLine(to: CGPoint(x: xs[i], y: tops[i])) }
                for i in xs.indices.reversed() { ctx.addLine(to: CGPoint(x: xs[i], y: bottoms[i])) }
                ctx.closePath()
                ctx.fillPath()
            }
            for d in days { base[d, default: 0] += values[d] ?? 0 }
        }
        drawChrome(ctx: ctx, lay: lay, title: title,
                   legend: series.map { ChartLegendEntry(label: $0.label, color: $0.color) },
                   yLabel: yLabel, footnote: note)
    }

    // MARK: - Bar chart drawing

    private static func drawBarChart(
        ctx: CGContext, data: BarChartData, yAxis: ChartYAxis, size: CGSize,
        title: String?, yLabel: String?, footnote: String?
    ) {
        let scale = axisScale(maxValue: data.values.max() ?? 0, kind: yAxis)
        let ticks = scale.ticks.map { tickLabel($0, kind: yAxis) }
        let lay = layout(size: size, title: title, legend: [], yLabel: yLabel,
                         yTickLabels: ticks, xLabelRowCount: data.subLabels == nil ? 1 : 2,
                         footnote: footnote)
        drawYAxis(ctx: ctx, plot: lay.plot, scale: scale, labels: ticks)

        let slot = lay.plot.width / CGFloat(data.categories.count)
        let barWidth = min(slot * 0.6, 180)
        for idx in data.categories.indices {
            let centerX = lay.plot.minX + slot * (CGFloat(idx) + 0.5)
            let top = yPosition(data.values[idx], scale: scale, plot: lay.plot)
            ctx.setFillColor(data.colors[safe: idx] ?? ChartPalette.noDataColor)
            ctx.fill(CGRect(x: centerX - barWidth / 2, y: top, width: barWidth,
                            height: lay.plot.maxY - top))
            if let value = data.valueLabels?[safe: idx] {
                let text = fitted(value, fontSize: Style.valueFont, maxWidth: slot - 8, bold: true)
                // Above the bar when there is room, else just inside its top in white.
                let above = top - lineHeight(Style.valueFont) / 2 - 6
                let inside = above - lineHeight(Style.valueFont) / 2 < lay.plot.minY
                drawText(ctx: ctx, text: text,
                         at: CGPoint(x: centerX, y: inside ? top + lineHeight(Style.valueFont) : above),
                         fontSize: Style.valueFont, color: inside ? white : ink,
                         alignment: .center, bold: true)
            }
            if let row = lay.xLabelRows.first {
                drawText(ctx: ctx, text: fitted(data.categories[idx], fontSize: Style.axisFont,
                                               maxWidth: slot - 8, bold: true),
                         at: CGPoint(x: centerX, y: row.midY), fontSize: Style.axisFont,
                         color: ink, alignment: .center, bold: true)
            }
            if let sub = data.subLabels?[safe: idx], let row = lay.xLabelRows[safe: 1] {
                drawText(ctx: ctx, text: fitted(sub, fontSize: Style.axisFont, maxWidth: slot - 8),
                         at: CGPoint(x: centerX, y: row.midY),
                         fontSize: Style.axisFont, color: muted, alignment: .center)
            }
        }
        drawChrome(ctx: ctx, lay: lay, title: title, legend: [], yLabel: yLabel,
                   footnote: footnote)
    }

    // MARK: - Donut drawing

    private static func drawDonutChart(
        ctx: CGContext, slices: [DonutSlice], title: String, footer: String?,
        size: CGSize, total: Int
    ) {
        let legendWidth: CGFloat = 300
        let ringAreaWidth = size.width - legendWidth
        let centerX = ringAreaWidth / 2
        let titleHeight = lineHeight(Style.titleFont)
        let footerHeight = footer == nil ? 0 : lineHeight(Style.noteFont) + 12
        let ringTop = Style.pad + titleHeight + 16
        let ringBottom = size.height - Style.pad - footerHeight
        let outerR = min(ringAreaWidth - 2 * Style.pad, ringBottom - ringTop) / 2
        let innerR = outerR * 0.55
        let centerY = (ringTop + ringBottom) / 2
        let center = CGPoint(x: centerX, y: centerY)

        // Title and footer are centred on the ring, so they line up with it.
        drawText(ctx: ctx, text: fitted(title, fontSize: Style.titleFont,
                                        maxWidth: ringAreaWidth - 2 * Style.pad, bold: true),
                 at: CGPoint(x: centerX, y: Style.pad + titleHeight / 2),
                 fontSize: Style.titleFont, color: ink, alignment: .center, bold: true)

        var startAngle: CGFloat = -.pi / 2  // 12 o'clock
        for slice in slices {
            let fraction = Double(slice.count) / Double(total)
            let sweep = CGFloat(fraction * 2 * .pi)
            ctx.move(to: center)
            ctx.addArc(center: center, radius: outerR, startAngle: startAngle,
                       endAngle: startAngle + sweep, clockwise: false)
            ctx.closePath()
            ctx.setFillColor(slice.color)
            ctx.fillPath()
            // Thin white gap between slices.
            ctx.move(to: center)
            ctx.addArc(center: center, radius: outerR + 1, startAngle: startAngle - 0.005,
                       endAngle: startAngle + 0.005, clockwise: false)
            ctx.setFillColor(white)
            ctx.fillPath()
            if fraction > 0.07 {
                let mid = startAngle + sweep / 2
                let r = (outerR + innerR) / 2
                let label = slice.count >= 1000 ? "\(slice.count / 1000)k" : "\(slice.count)"
                drawText(ctx: ctx, text: label,
                         at: CGPoint(x: centerX + r * cos(mid), y: centerY + r * sin(mid)),
                         fontSize: 13, color: white, alignment: .center, bold: true)
            }
            startAngle += sweep
        }
        ctx.setFillColor(white)
        ctx.fillEllipse(in: CGRect(x: centerX - innerR, y: centerY - innerR,
                                   width: innerR * 2, height: innerR * 2))
        drawText(ctx: ctx, text: "Total", at: CGPoint(x: centerX, y: centerY - 12),
                 fontSize: 12, color: muted, alignment: .center)
        drawText(ctx: ctx, text: "\(total)", at: CGPoint(x: centerX, y: centerY + 10),
                 fontSize: 20, color: ink, alignment: .center, bold: true)

        drawDonutLegend(ctx: ctx, slices: slices, startX: ringAreaWidth + 10,
                        centerY: centerY, maxWidth: legendWidth - 30)
        if let footer {
            drawText(ctx: ctx, text: fitted(footer, fontSize: Style.noteFont,
                                            maxWidth: ringAreaWidth - 2 * Style.pad),
                     at: CGPoint(x: centerX,
                                 y: size.height - Style.pad - lineHeight(Style.noteFont) / 2),
                     fontSize: Style.noteFont, color: muted, alignment: .center)
        }
    }

    private static func drawDonutLegend(
        ctx: CGContext, slices: [DonutSlice], startX: CGFloat, centerY: CGFloat, maxWidth: CGFloat
    ) {
        let rowHeight: CGFloat = 26
        let top = centerY - CGFloat(slices.count) * rowHeight / 2
        let labelX = startX + Style.swatch + Style.swatchGap
        for (idx, slice) in slices.enumerated() {
            let y = top + (CGFloat(idx) + 0.5) * rowHeight
            ctx.setFillColor(slice.color)
            ctx.fill(CGRect(x: startX, y: y - Style.swatch / 2,
                            width: Style.swatch, height: Style.swatch))
            let text = "\(slice.label): \(slice.count) (\(PercentFormat.whole.text(slice.pct)))"
            drawText(ctx: ctx, text: fitted(text, fontSize: Style.legendFont,
                                            maxWidth: maxWidth - (labelX - startX)),
                     at: CGPoint(x: labelX, y: y), fontSize: Style.legendFont, color: ink,
                     alignment: .left)
        }
    }

    // MARK: - Shared drawing

    /// Title, legend, y-axis title and footnote, each in its own `Layout` band.
    private static func drawChrome(
        ctx: CGContext, lay: Layout, title: String?, legend: [ChartLegendEntry],
        yLabel: String?, footnote: String?
    ) {
        if let title, let rect = lay.title {
            drawText(ctx: ctx, text: fitted(title, fontSize: Style.titleFont,
                                            maxWidth: rect.width + 1, bold: true),
                     at: CGPoint(x: rect.midX, y: rect.midY), fontSize: Style.titleFont,
                     color: ink, alignment: .center, bold: true)
        }
        for (rect, entry) in zip(lay.legend, legend) {
            ctx.setFillColor(entry.color)
            ctx.fill(CGRect(x: rect.minX, y: rect.midY - Style.swatch / 2,
                            width: Style.swatch, height: Style.swatch))
            let labelX = rect.minX + Style.swatch + Style.swatchGap
            drawText(ctx: ctx, text: fitted(entry.label, fontSize: Style.legendFont,
                                            maxWidth: rect.maxX - labelX + 1),
                     at: CGPoint(x: labelX, y: rect.midY), fontSize: Style.legendFont,
                     color: ink, alignment: .left)
        }
        if let yLabel, let rect = lay.axisTitle {
            drawText(ctx: ctx, text: yLabel, at: CGPoint(x: rect.minX, y: rect.midY),
                     fontSize: Style.axisFont, color: muted, alignment: .left)
        }
        if let footnote, let rect = lay.footnote {
            drawText(ctx: ctx, text: fitted(footnote, fontSize: Style.noteFont,
                                            maxWidth: rect.width + 1),
                     at: CGPoint(x: rect.minX, y: rect.midY), fontSize: Style.noteFont,
                     color: muted, alignment: .left)
        }
    }

    private static func drawYAxis(ctx: CGContext, plot: CGRect, scale: AxisScale, labels: [String]) {
        ctx.setLineWidth(0.5)
        for (value, label) in zip(scale.ticks, labels) {
            let y = yPosition(value, scale: scale, plot: plot)
            ctx.setStrokeColor(gridColor)
            ctx.move(to: CGPoint(x: plot.minX, y: y))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: y))
            ctx.strokePath()
            drawText(ctx: ctx, text: label, at: CGPoint(x: plot.minX - 8, y: y),
                     fontSize: Style.axisFont, color: muted, alignment: .right)
        }
        ctx.setStrokeColor(axisColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: plot.minX, y: plot.minY))
        ctx.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        ctx.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        ctx.strokePath()
    }

    private static func drawDateLabels(
        ctx: CGContext, lay: Layout, first: Date, last: Date, calendar: Calendar
    ) {
        guard let row = lay.xLabelRows.first else { return }
        let withYear = calendar.component(.year, from: first) != calendar.component(.year, from: last)
        for tick in dateTicks(from: first, to: last, calendar: calendar) {
            let x = xPosition(tick, first: first, last: last, plot: lay.plot)
            drawText(ctx: ctx, text: dayLabel(tick, calendar: calendar, withYear: withYear),
                     at: CGPoint(x: x, y: row.midY), fontSize: Style.axisFont, color: muted,
                     alignment: .center)
        }
    }

    /// A series' values by calendar day; a later point on the same day replaces an earlier one.
    static func dailyValues(_ series: ChartSeries, calendar: Calendar) -> [Date: Double] {
        var out: [Date: Double] = [:]
        for p in series.points.sorted(by: { $0.date < $1.date }) {
            out[calendar.startOfDay(for: p.date)] = p.value
        }
        return out
    }

    static func singleDayNote(first: Date, last: Date, calendar: Calendar) -> String? {
        guard first == last else { return nil }
        let day = dayLabel(first, calendar: calendar, withYear: true)
        return "Only one day of history so far (\(day))."
    }

    private static func joinedNote(_ a: String?, _ b: String?) -> String? {
        let parts = [a, b].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    // MARK: - Core rendering

    private static func renderToPNG(size: CGSize, draw: (CGContext) -> Void) -> Data? {
        let scale: CGFloat = 2.0
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width * scale),
            height: Int(size.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(white)
        ctx.fill(CGRect(origin: .zero, size: size))
        draw(ctx)

        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Text rendering (CoreText)

    enum TextAlignment { case left, center, right }

    /// Draws one line of text whose vertical centre is `point.y`.
    static func drawText(
        ctx: CGContext,
        text: String,
        at point: CGPoint,
        fontSize: CGFloat,
        color: CGColor,
        alignment: TextAlignment = .left,
        bold: Bool = false
    ) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString,
                                        fontSize, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font,
                                      kCTForegroundColorAttributeName: color]
        guard let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)
        else { return }
        let line = CTLineCreateWithAttributedString(attrStr)
        let width = CTLineGetBoundsWithOptions(line, []).width
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)

        let x: CGFloat
        switch alignment {
        case .left: x = point.x
        case .center: x = point.x - width / 2
        case .right: x = point.x - width
        }
        // Baseline placed so the line's ascent-to-descent box is centred on point.y.
        let baseline = point.y + (ascent - descent) / 2
        ctx.saveGState()
        ctx.translateBy(x: x, y: baseline)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
