import Foundation
import CoreGraphics
import ImageIO
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Color palette

/// Chart color palette matching the Python matplotlib palette used in ChartGenerator.
enum ChartPalette {
    /// OS version adoption colors — keyed by major version number string.
    static let majorVersionColors: [String: CGColor] = [
        "15": CGColor(red: 0.200, green: 0.620, blue: 0.965, alpha: 1),
        "14": CGColor(red: 0.230, green: 0.541, blue: 0.816, alpha: 1),
        "13": CGColor(red: 0.184, green: 0.459, blue: 0.710, alpha: 1),
        "12": CGColor(red: 0.122, green: 0.471, blue: 0.706, alpha: 1),
        "11": CGColor(red: 0.529, green: 0.808, blue: 0.922, alpha: 1),
        "10": CGColor(red: 0.302, green: 0.686, blue: 0.290, alpha: 1),
        "26": CGColor(red: 0.125, green: 0.694, blue: 0.667, alpha: 1),
    ]

    /// Default series color cycle (6 colors, wraps).
    static let seriesColors: [CGColor] = [
        CGColor(red: 0.267, green: 0.447, blue: 0.769, alpha: 1), // #4472C4
        CGColor(red: 0.906, green: 0.298, blue: 0.235, alpha: 1), // #E74C3C
        CGColor(red: 0.180, green: 0.620, blue: 0.341, alpha: 1), // #2E9E57
        CGColor(red: 0.945, green: 0.769, blue: 0.188, alpha: 1), // #F1C430
        CGColor(red: 0.608, green: 0.349, blue: 0.714, alpha: 1), // #9B59B6
        CGColor(red: 0.204, green: 0.596, blue: 0.859, alpha: 1), // #3498DB
    ]

    /// Compliance band colors, matching `DEFAULT_CONFIG["charts"]["compliance_trend"]["bands"]`.
    /// Order: Pass, Low, Med-Low, Medium, High (5 entries — no No-Data here).
    static let complianceBandColors: [CGColor] = [
        CGColor(red: 0.267, green: 0.447, blue: 0.769, alpha: 1), // Pass  — blue
        CGColor(red: 0.180, green: 0.620, blue: 0.341, alpha: 1), // Low   — green
        CGColor(red: 1.000, green: 0.792, blue: 0.188, alpha: 1), // Med-Low — gold
        CGColor(red: 0.941, green: 0.486, blue: 0.129, alpha: 1), // Medium — orange
        CGColor(red: 0.753, green: 0.224, blue: 0.169, alpha: 1), // High  — red
    ]

    /// Grey for "No Data" slices in the compliance donut.
    static let noDataColor: CGColor = CGColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1)

    /// Compliance band colors extended with No-Data grey (6 entries for donut use).
    /// Order: Pass, Low, Med-Low, Medium, High, No-Data.
    static var complianceBandColorsWithNoData: [CGColor] {
        complianceBandColors + [noDataColor]
    }

    static func color(for index: Int) -> CGColor {
        let count = seriesColors.count
        let normalized = ((index % count) + count) % count
        return seriesColors[normalized]
    }

    static func colorForMajorVersion(_ version: String) -> CGColor {
        majorVersionColors[version] ?? color(for: version.hashValue)
    }
}

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
}

// MARK: - Chart renderer

/// Renders charts to PNG `Data` using CoreGraphics.
/// No WindowServer dependency — safe for LaunchAgent headless context.
enum ChartRenderer {

    /// Standard chart dimensions: 1200×600 px at 144 DPI (2× retina).
    static let defaultSize = CGSize(width: 1200, height: 600)

    // MARK: - Line chart

    /// Render a multi-series line chart with a date X-axis.
    ///
    /// - Parameters:
    ///   - series: One entry per line. Each point is `(date, value)`.
    ///   - size: Output size in points.
    ///   - title: Optional chart title.
    ///   - yLabel: Y-axis label.
    /// - Returns: PNG `Data`, or nil on rendering failure.
    static func lineChart(
        series: [ChartSeries],
        size: CGSize = defaultSize,
        title: String? = nil,
        yLabel: String? = nil
    ) -> Data? {
        guard !series.isEmpty else { return nil }
        return renderToPNG(size: size) { ctx in
            drawLineChart(ctx: ctx, series: series, size: size, title: title, yLabel: yLabel)
        }
    }

    /// Render a stacked area chart with a date X-axis.
    ///
    /// - Parameters:
    ///   - series: Ordered bottom-to-top. Each series is one stacked band.
    ///   - size: Output size in points.
    ///   - title: Optional chart title.
    /// - Returns: PNG `Data`, or nil on rendering failure.
    static func stackedAreaChart(
        series: [ChartSeries],
        size: CGSize = defaultSize,
        title: String? = nil
    ) -> Data? {
        guard !series.isEmpty else { return nil }
        return renderToPNG(size: size) { ctx in
            drawStackedAreaChart(ctx: ctx, series: series, size: size, title: title)
        }
    }

    /// Render a horizontal bar chart for single-point snapshots.
    ///
    /// - Parameters:
    ///   - data: Category labels, values, and per-bar colors.
    ///   - size: Output size in points.
    ///   - title: Optional chart title.
    /// - Returns: PNG `Data`, or nil on rendering failure.
    static func barChart(
        data: BarChartData,
        size: CGSize = defaultSize,
        title: String? = nil
    ) -> Data? {
        guard !data.categories.isEmpty else { return nil }
        return renderToPNG(size: size) { ctx in
            drawBarChart(ctx: ctx, data: data, size: size, title: title)
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
    ///
    /// - Parameters:
    ///   - slices: Ordered slices (non-zero at render time; caller filters zeros).
    ///   - title: Chart title rendered above the ring.
    ///   - footer: Optional footer below the ring (e.g. "Total systems: N").
    ///   - size: Output dimensions in points.
    /// - Returns: PNG `Data`, or nil on rendering failure.
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

    // MARK: - Donut drawing

    private static func drawDonutChart(
        ctx: CGContext,
        slices: [DonutSlice],
        title: String,
        footer: String?,
        size: CGSize,
        total: Int
    ) {
        let legendWidth: CGFloat = 260
        let ringAreaWidth = size.width - legendWidth
        let centerX = ringAreaWidth / 2
        let centerY = size.height / 2 + 10
        let outerR: CGFloat = min(ringAreaWidth, size.height) * 0.38
        let innerR = outerR * 0.55

        // Title
        drawTitle(ctx: ctx, title: title, size: CGSize(width: ringAreaWidth, height: size.height))

        // Draw slices
        var startAngle: CGFloat = -.pi / 2  // Start at top (12 o'clock)
        for slice in slices {
            let fraction = Double(slice.count) / Double(total)
            let sweep = CGFloat(fraction * 2 * .pi)
            let endAngle = startAngle + sweep
            let mid = startAngle + sweep / 2

            ctx.move(to: CGPoint(x: centerX, y: centerY))
            ctx.addArc(center: CGPoint(x: centerX, y: centerY),
                       radius: outerR, startAngle: startAngle, endAngle: endAngle,
                       clockwise: false)
            ctx.closePath()
            ctx.setFillColor(slice.color)
            ctx.fillPath()

            // Separate each slice with a thin white gap
            ctx.move(to: CGPoint(x: centerX, y: centerY))
            ctx.addArc(center: CGPoint(x: centerX, y: centerY),
                       radius: outerR + 1, startAngle: startAngle - 0.005,
                       endAngle: startAngle + 0.005, clockwise: false)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillPath()

            // Slice value label (only when slice is large enough)
            if fraction > 0.07 {
                let lx = centerX + (outerR + innerR) / 2 * cos(mid)
                let ly = centerY + (outerR + innerR) / 2 * sin(mid)
                let labelStr = slice.count >= 1000
                    ? "\(slice.count / 1000)k"
                    : "\(slice.count)"
                drawText(ctx: ctx, text: labelStr,
                         at: CGPoint(x: lx, y: ly),
                         fontSize: 9,
                         color: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                         alignment: .center)
            }
            startAngle = endAngle
        }

        // Punch out inner circle (donut hole)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(
            x: centerX - innerR, y: centerY - innerR,
            width: innerR * 2, height: innerR * 2
        ))

        // Center text: total
        drawText(ctx: ctx, text: "Total",
                 at: CGPoint(x: centerX, y: centerY - 8),
                 fontSize: 10,
                 color: CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1),
                 alignment: .center)
        drawText(ctx: ctx, text: "\(total)",
                 at: CGPoint(x: centerX, y: centerY + 8),
                 fontSize: 14,
                 color: CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
                 alignment: .center, bold: true)

        // Legend on the right
        drawDonutLegend(ctx: ctx, slices: slices, total: total,
                        startX: ringAreaWidth + 16, startY: 60, maxWidth: legendWidth - 20)

        // Footer
        if let footer {
            drawText(ctx: ctx, text: footer,
                     at: CGPoint(x: size.width / 2, y: size.height - 10),
                     fontSize: 9,
                     color: CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1),
                     alignment: .center)
        }
    }

    private static func drawDonutLegend(
        ctx: CGContext,
        slices: [DonutSlice],
        total: Int,
        startX: CGFloat,
        startY: CGFloat,
        maxWidth: CGFloat
    ) {
        let rowHeight: CGFloat = 22
        let swatchSize: CGFloat = 11
        let labelColor = CGColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)

        for (idx, slice) in slices.enumerated() {
            let y = startY + CGFloat(idx) * rowHeight
            // Swatch
            ctx.setFillColor(slice.color)
            ctx.fill(CGRect(x: startX, y: y - swatchSize + 2,
                            width: swatchSize, height: swatchSize))
            // Count + percent label: "No Data: N (P%)"
            let pctStr = String(format: "%.0f%%", slice.pct)
            let legend = "\(slice.label): \(slice.count) (\(pctStr))"
            drawText(ctx: ctx, text: legend,
                     at: CGPoint(x: startX + swatchSize + 5, y: y - 2),
                     fontSize: 9, color: labelColor, alignment: .left)
            _ = total  // passed for future use (e.g., total label)
        }
        _ = maxWidth  // available for future layout (e.g., text truncation)
    }

    // MARK: - Core rendering

    private static func renderToPNG(size: CGSize, draw: (CGContext) -> Void) -> Data? {
        let scale: CGFloat = 2.0
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)

        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        // White background
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))

        draw(ctx)

        guard let image = ctx.makeImage() else { return nil }
        return pngData(from: image)
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Layout constants

    private static let margin = ChartMargin(top: 50, right: 30, bottom: 70, left: 70)
    private static let legendItemHeight: CGFloat = 18
    private static let axisFontSize: CGFloat = 10
    private static let titleFontSize: CGFloat = 13
    private static let labelFontSize: CGFloat = 9

    struct ChartMargin {
        let top: CGFloat
        let right: CGFloat
        let bottom: CGFloat
        let left: CGFloat
    }

    // MARK: - Line chart drawing

    private static func drawLineChart(
        ctx: CGContext,
        series: [ChartSeries],
        size: CGSize,
        title: String?,
        yLabel: String?
    ) {
        let m = margin
        let plotRect = CGRect(
            x: m.left, y: m.top,
            width: size.width - m.left - m.right,
            height: size.height - m.top - m.bottom
        )

        // Aggregate all dates and values
        let allDates = series.flatMap { $0.points.map(\.date) }
        let allValues = series.flatMap { $0.points.map(\.value) }
        guard let minDate = allDates.min(), let maxDate = allDates.max() else { return }
        let minVal = min(0, allValues.min() ?? 0)
        let maxVal = max(allValues.max() ?? 100, 1)

        drawGrid(ctx: ctx, plotRect: plotRect, minVal: minVal, maxVal: maxVal,
                 minDate: minDate, maxDate: maxDate)

        // Draw series lines
        for (idx, s) in series.enumerated() {
            let pts = s.points.sorted { $0.date < $1.date }
            guard !pts.isEmpty else { continue }
            let color = s.color
            ctx.setStrokeColor(color)
            ctx.setLineWidth(2)

            let cgPts = pts.map { p in
                CGPoint(
                    x: plotRect.minX + xFraction(p.date, min: minDate, max: maxDate) * plotRect.width,
                    y: plotRect.maxY - yFraction(p.value, min: minVal, max: maxVal) * plotRect.height
                )
            }
            ctx.move(to: cgPts[0])
            for pt in cgPts.dropFirst() { ctx.addLine(to: pt) }
            ctx.strokePath()

            // Dots
            ctx.setFillColor(color)
            for pt in cgPts {
                let r: CGFloat = 3
                ctx.fillEllipse(in: CGRect(x: pt.x - r, y: pt.y - r, width: r*2, height: r*2))
            }
            _ = idx // suppress unused warning
        }

        drawAxesLabels(ctx: ctx, plotRect: plotRect, minVal: minVal, maxVal: maxVal,
                       minDate: minDate, maxDate: maxDate, size: size)
        drawLegend(ctx: ctx, series: series.map { ($0.label, $0.color) },
                   plotRect: plotRect, size: size)
        if let title { drawTitle(ctx: ctx, title: title, size: size) }
    }

    // MARK: - Stacked area chart drawing

    private static func drawStackedAreaChart(
        ctx: CGContext,
        series: [ChartSeries],
        size: CGSize,
        title: String?
    ) {
        let m = margin
        let plotRect = CGRect(
            x: m.left, y: m.top,
            width: size.width - m.left - m.right,
            height: size.height - m.top - m.bottom
        )

        // Compute stacked values — all series share the same date axis
        let allDates = series.flatMap { $0.points.map(\.date) }
        guard let minDate = allDates.min(), let maxDate = allDates.max() else { return }

        // Build union date set
        var dateSet = Set<Date>()
        for s in series { s.points.forEach { dateSet.insert($0.date) } }
        let sortedDates = dateSet.sorted()

        // Compute per-date totals for Y axis
        var totals: [Date: Double] = [:]
        for s in series {
            let valueDict = Dictionary(s.points.map { ($0.date, $0.value) }, uniquingKeysWith: +)
            for (d, v) in valueDict { totals[d, default: 0] += v }
        }
        let maxVal = max(totals.values.max() ?? 100, 1)

        drawGrid(ctx: ctx, plotRect: plotRect, minVal: 0, maxVal: maxVal,
                 minDate: minDate, maxDate: maxDate)

        // Stacked areas
        var baselines: [Date: Double] = Dictionary(uniqueKeysWithValues: sortedDates.map { ($0, 0.0) })
        for s in series.reversed() {
            let valueDict = Dictionary(s.points.map { ($0.date, $0.value) }, uniquingKeysWith: +)
            var topPts: [CGPoint] = []
            var bottomPts: [CGPoint] = []
            for date in sortedDates {
                let base = baselines[date] ?? 0
                let value = base + (valueDict[date] ?? 0)
                let x = plotRect.minX + xFraction(date, min: minDate, max: maxDate) * plotRect.width
                topPts.append(CGPoint(
                    x: x,
                    y: plotRect.maxY - yFraction(value, min: 0, max: maxVal) * plotRect.height
                ))
                bottomPts.append(CGPoint(
                    x: x,
                    y: plotRect.maxY - yFraction(base, min: 0, max: maxVal) * plotRect.height
                ))
            }
            guard let first = topPts.first else { continue }
            ctx.move(to: first)
            for pt in topPts.dropFirst() { ctx.addLine(to: pt) }
            for pt in bottomPts.reversed() { ctx.addLine(to: pt) }
            ctx.closePath()
            let fill = s.color.copy(alpha: 0.7) ?? s.color
            ctx.setFillColor(fill)
            ctx.fillPath()

            for date in sortedDates {
                let v = valueDict[date] ?? 0
                baselines[date] = (baselines[date] ?? 0) + v
            }
        }

        drawAxesLabels(ctx: ctx, plotRect: plotRect, minVal: 0, maxVal: maxVal,
                       minDate: minDate, maxDate: maxDate, size: size)
        drawLegend(ctx: ctx, series: series.map { ($0.label, $0.color) },
                   plotRect: plotRect, size: size)
        if let title { drawTitle(ctx: ctx, title: title, size: size) }
    }

    // MARK: - Bar chart drawing

    private static func drawBarChart(
        ctx: CGContext,
        data: BarChartData,
        size: CGSize,
        title: String?
    ) {
        let m = margin
        let plotRect = CGRect(
            x: m.left, y: m.top,
            width: size.width - m.left - m.right,
            height: size.height - m.top - m.bottom
        )

        let count = data.categories.count
        guard count > 0 else { return }
        let maxVal = max(data.values.max() ?? 1, 1)
        let barWidth = plotRect.width / CGFloat(count) * 0.7
        let spacing = plotRect.width / CGFloat(count)

        // Light grid lines
        ctx.setStrokeColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        ctx.setLineWidth(0.5)
        let yTicks = 5
        for i in 0...yTicks {
            let y = plotRect.maxY - (CGFloat(i) / CGFloat(yTicks)) * plotRect.height
            ctx.move(to: CGPoint(x: plotRect.minX, y: y))
            ctx.addLine(to: CGPoint(x: plotRect.maxX, y: y))
            ctx.strokePath()
            let label = "\(Int((Double(i) / Double(yTicks)) * maxVal))"
            drawText(ctx: ctx, text: label,
                     at: CGPoint(x: plotRect.minX - 5, y: y),
                     fontSize: labelFontSize, color: .init(red: 0.3, green: 0.3, blue: 0.3, alpha: 1),
                     alignment: .right)
        }

        for (idx, (cat, value)) in zip(data.categories, data.values).enumerated() {
            let x = plotRect.minX + CGFloat(idx) * spacing + spacing * 0.15
            let barHeight = CGFloat(value / maxVal) * plotRect.height
            let color = idx < data.colors.count ? data.colors[idx] : ChartPalette.color(for: idx)
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: x, y: plotRect.maxY - barHeight, width: barWidth, height: barHeight))
            // Category label
            drawText(ctx: ctx, text: String(cat.prefix(12)),
                     at: CGPoint(x: x + barWidth/2, y: plotRect.maxY + 5),
                     fontSize: labelFontSize, color: .init(red: 0.2, green: 0.2, blue: 0.2, alpha: 1),
                     alignment: .center)
        }

        // Axes
        ctx.setStrokeColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1))
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: plotRect.minX, y: plotRect.minY))
        ctx.addLine(to: CGPoint(x: plotRect.minX, y: plotRect.maxY))
        ctx.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.maxY))
        ctx.strokePath()

        if let title { drawTitle(ctx: ctx, title: title, size: size) }
    }

    // MARK: - Shared drawing helpers

    private static func drawGrid(
        ctx: CGContext,
        plotRect: CGRect,
        minVal: Double, maxVal: Double,
        minDate: Date, maxDate: Date
    ) {
        // Horizontal grid
        ctx.setStrokeColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        ctx.setLineWidth(0.5)
        let yTicks = 5
        for i in 0...yTicks {
            let y = plotRect.maxY - (CGFloat(i) / CGFloat(yTicks)) * plotRect.height
            ctx.move(to: CGPoint(x: plotRect.minX, y: y))
            ctx.addLine(to: CGPoint(x: plotRect.maxX, y: y))
            ctx.strokePath()
        }

        // Axes
        ctx.setStrokeColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1))
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: plotRect.minX, y: plotRect.minY))
        ctx.addLine(to: CGPoint(x: plotRect.minX, y: plotRect.maxY))
        ctx.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.maxY))
        ctx.strokePath()
    }

    private static func drawAxesLabels(
        ctx: CGContext,
        plotRect: CGRect,
        minVal: Double, maxVal: Double,
        minDate: Date, maxDate: Date,
        size: CGSize
    ) {
        let labelColor = CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)
        let yTicks = 5
        for i in 0...yTicks {
            let value = minVal + (maxVal - minVal) * Double(i) / Double(yTicks)
            let y = plotRect.maxY - (CGFloat(i) / CGFloat(yTicks)) * plotRect.height
            let label = value >= 10 ? "\(Int(value))" : String(format: "%.1f", value)
            drawText(ctx: ctx, text: label,
                     at: CGPoint(x: plotRect.minX - 5, y: y),
                     fontSize: labelFontSize, color: labelColor, alignment: .right)
        }

        // X-axis date ticks — up to 6 evenly spaced
        let span = maxDate.timeIntervalSince(minDate)
        guard span > 0 else { return }
        let nTicks = 6
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "MMM d"
        for i in 0...nTicks {
            let frac = Double(i) / Double(nTicks)
            let date = minDate.addingTimeInterval(span * frac)
            let x = plotRect.minX + CGFloat(frac) * plotRect.width
            drawText(ctx: ctx, text: dateFormatter.string(from: date),
                     at: CGPoint(x: x, y: plotRect.maxY + 12),
                     fontSize: labelFontSize, color: labelColor, alignment: .center)
        }
    }

    private static func drawLegend(
        ctx: CGContext,
        series: [(label: String, color: CGColor)],
        plotRect: CGRect,
        size: CGSize
    ) {
        let itemHeight: CGFloat = 16
        let swatchSize: CGFloat = 10
        let itemSpacing: CGFloat = 120
        let legendTop = plotRect.minY - 30
        let labelColor = CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)

        var x = plotRect.minX
        for (label, color) in series {
            if x + itemSpacing > plotRect.maxX {
                x = plotRect.minX
            }
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: x, y: legendTop - swatchSize, width: swatchSize, height: swatchSize))
            drawText(ctx: ctx, text: String(label.prefix(14)),
                     at: CGPoint(x: x + swatchSize + 4, y: legendTop - swatchSize/2),
                     fontSize: labelFontSize, color: labelColor, alignment: .left)
            x += itemSpacing
        }
        _ = itemHeight
    }

    private static func drawTitle(ctx: CGContext, title: String, size: CGSize) {
        drawText(ctx: ctx, text: title,
                 at: CGPoint(x: size.width / 2, y: 16),
                 fontSize: titleFontSize,
                 color: CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
                 alignment: .center,
                 bold: true)
    }

    // MARK: - Fraction helpers

    private static func xFraction(_ date: Date, min: Date, max: Date) -> CGFloat {
        let span = max.timeIntervalSince(min)
        guard span > 0 else { return 0 }
        return CGFloat(date.timeIntervalSince(min) / span)
    }

    private static func yFraction(_ value: Double, min: Double, max: Double) -> CGFloat {
        let span = max - min
        guard span > 0 else { return 0 }
        return CGFloat((value - min) / span)
    }

    // MARK: - Text rendering (CoreText)

    private enum TextAlignment { case left, center, right }

    private static func drawText(
        ctx: CGContext,
        text: String,
        at point: CGPoint,
        fontSize: CGFloat,
        color: CGColor,
        alignment: TextAlignment = .left,
        bold: Bool = false
    ) {
        let fontName = bold ? "Helvetica-Bold" : "Helvetica"
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, [])

        let x: CGFloat
        switch alignment {
        case .left:   x = point.x
        case .center: x = point.x - bounds.width / 2
        case .right:  x = point.x - bounds.width
        }
        let y = point.y - bounds.height / 2

        ctx.saveGState()
        ctx.translateBy(x: x, y: y + bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
