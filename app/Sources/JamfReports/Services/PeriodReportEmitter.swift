import Foundation

/// Renders a `PeriodReportModel` as an .xlsx. Thin by design: all aggregation
/// happened in the model, mirroring `FleetWorkbookEmitter`. Every cell goes
/// through `Worksheet.write` → `CellValue.safe`, so server-supplied EA values
/// and names cannot become formulas.
enum PeriodReportEmitter {

    static func emit(model: PeriodReportModel, to url: URL) throws {
        try workbook(for: model).write(to: url)
    }

    /// `ExportNaming` kind carrying the period, so two quarters' reports are
    /// distinguishable by name rather than only by generation timestamp.
    static func reportKind(for model: PeriodReportModel) -> String {
        "period-report-\(stamp(model.period.start.resolved))-\(stamp(model.period.end.resolved))"
    }

    static func workbook(for model: PeriodReportModel) -> Workbook {
        let wb = Workbook()
        buildSummary(wb.addSheet("Summary"), model)
        buildDaily(wb.addSheet("Daily detail"), model)
        let distributions = model.rows.filter { $0.unit == .distribution }
        if !distributions.isEmpty {
            buildDistributions(wb.addSheet("Value distributions"), distributions)
        }
        buildAbout(wb.addSheet("About"), model)
        return wb
    }

    /// The paste-ready block. Deliberately free of caveats and commentary so a
    /// rectangular selection copies straight into another document.
    private static func buildSummary(_ ws: Worksheet, _ m: PeriodReportModel) {
        ws.write("Fleet metrics", row: 0, col: 0, format: .title)
        ws.write("\(dateLabel(m.period.start.resolved)) – \(dateLabel(m.period.end.resolved))"
                 + " · \(m.profile)", row: 1, col: 0, format: .subtitle)
        let headers = ["Metric", "Start", "End", "Change", "Start as of", "End as of"]
        for (c, h) in headers.enumerated() {
            ws.write(h, row: 3, col: c, format: .header)
        }
        for (i, row) in m.rows.enumerated() {
            let r = 4 + i
            ws.write(row.label, row: r, col: 0, format: .cell)
            ws.write(PeriodReportModel.formatValue(row.startValue, unit: row.unit),
                     row: r, col: 1, format: .cell)
            ws.write(PeriodReportModel.formatValue(row.endValue, unit: row.unit),
                     row: r, col: 2, format: .cell)
            ws.write(PeriodReportModel.formatChange(row.change, unit: row.unit),
                     row: r, col: 3, format: .cell)
            ws.write(dateLabel(row.startDate), row: r, col: 4, format: .cell)
            ws.write(dateLabel(row.endDate), row: r, col: 5, format: .cell)
        }
        ws.setColumnWidth(0, 0, 34)
        ws.setColumnWidth(1, 5, 14)
        ws.freezePane(row: 4, col: 1)
    }

    private static func buildDaily(_ ws: Worksheet, _ m: PeriodReportModel) {
        let charted = m.rows.filter { $0.unit != .distribution }
        ws.write("Date", row: 0, col: 0, format: .header)
        for (c, row) in charted.enumerated() {
            ws.write(row.label, row: 0, col: c + 1, format: .header)
        }
        for (i, day) in m.days.enumerated() {
            let r = i + 1
            ws.write(dateLabel(day.date), row: r, col: 0, format: .cell)
            for (c, row) in charted.enumerated() {
                if let v = day.values[row.metricID] {
                    ws.write(v, row: r, col: c + 1, format: .cell)
                } else {
                    ws.writeBlank(row: r, col: c + 1, format: .cell)
                }
            }
        }
        ws.setColumnWidth(0, 0, 14)
        ws.freezePane(row: 1, col: 1)
    }

    private static func buildDistributions(_ ws: Worksheet, _ rows: [PeriodReportModel.Row]) {
        var r = 0
        for row in rows {
            ws.write(row.label, row: r, col: 0, format: .title); r += 1
            for (c, h) in ["Value", "Start", "End"].enumerated() {
                ws.write(h, row: r, col: c, format: .header)
            }
            r += 1
            let values = Set(row.startDistribution.keys).union(row.endDistribution.keys).sorted()
            for value in values {
                ws.write(value, row: r, col: 0, format: .cell)
                ws.write(row.startDistribution[value] ?? 0, row: r, col: 1, format: .int)
                ws.write(row.endDistribution[value] ?? 0, row: r, col: 2, format: .int)
                r += 1
            }
            if row.omittedValueCount > 0 {
                ws.write("\(row.omittedValueCount) less common value(s) not shown — "
                    + "this attribute has more distinct values than a status normally does.",
                    row: r, col: 0, format: .cell)
                r += 1
            }
            r += 1
        }
        ws.setColumnWidth(0, 0, 46)
        ws.setColumnWidth(1, 2, 12)
    }

    /// Caveats live here, off the Summary sheet, precisely so Summary stays
    /// paste-ready.
    private static func buildAbout(_ ws: Worksheet, _ m: PeriodReportModel) {
        var r = 0
        func line(_ k: String, _ v: String) {
            ws.write(k, row: r, col: 0, format: .header)
            ws.write(v, row: r, col: 1, format: .cell)
            r += 1
        }
        ws.write("About this report", row: r, col: 0, format: .title); r += 2
        line("Profile", m.profile)
        line("Period requested",
             "\(dateLabel(m.period.requestedStart)) – \(dateLabel(m.period.requestedEnd))")
        line("Period reported",
             "\(dateLabel(m.period.start.resolved)) – \(dateLabel(m.period.end.resolved))")
        line("Generated", dateLabel(m.generatedAt))
        line("App version", AppVersionState.currentVersion)
        line("Days with data", String(m.days.count))
        r += 1
        ws.write("Coverage", row: r, col: 0, format: .title); r += 1
        if m.period.start.isAdrift {
            ws.write("Start is \(m.period.start.driftDays) day(s) after the date requested — "
                + "no collection ran closer to it.", row: r, col: 0, format: .cell)
            r += 1
        }
        if m.period.end.isAdrift {
            ws.write("End is \(m.period.end.driftDays) day(s) from the date requested.",
                     row: r, col: 0, format: .cell)
            r += 1
        }
        let truncated = m.rows.filter { $0.omittedValueCount > 0 }
        for row in truncated {
            ws.write("\(row.label): \(row.omittedValueCount) value(s) not shown.",
                     row: r, col: 0, format: .cell)
            r += 1
        }
        if !m.period.start.isAdrift && !m.period.end.isAdrift && truncated.isEmpty {
            ws.write("Both period boundaries landed on days with collected data.",
                     row: r, col: 0, format: .cell)
        }
        ws.setColumnWidth(0, 0, 30)
        ws.setColumnWidth(1, 1, 52)
    }

    private static func dateLabel(_ d: Date) -> String { format(d, "yyyy-MM-dd") }
    private static func stamp(_ d: Date) -> String { format(d, "yyyyMMdd") }
    private static func format(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter(); f.dateFormat = pattern; f.timeZone = .current
        return f.string(from: d)
    }
}
