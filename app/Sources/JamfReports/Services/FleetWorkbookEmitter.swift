import Foundation
import CoreGraphics

/// Renders a `FleetWorkbookModel` into the consolidated fleet **workbook** — a
/// 5-sheet `.xlsx` with embedded `ChartRenderer` PNGs (v2.4.0). Mirrors
/// `FleetReportEmitter` (CSV): pure `workbook(for:)` + thin IO `emit`, same
/// `_fleet-reports/` output dir, same injectable `summariesFor` loader.
///
/// Percentages render as `"%.1f%%"` strings (the `CoreDashboard` convention —
/// `CellFormat.pct` would multiply a 0–100 value by 100). Cell values route
/// through `Worksheet.write` → `CellValue.safe`, so profile/baseline names are
/// formula-injection-safe by construction. nil metrics render "—", never 0.
enum FleetWorkbookEmitter {

    /// Build the model, render the workbook, write it beside the CSV. Returns
    /// the written URL, or nil when no member profile has data.
    @discardableResult
    static func emit(
        group: ReportGroup,
        lookbackDays: Int,
        timestamp: String,
        outputDir: URL? = nil,
        summariesFor: (String) -> [DailySummary] = FleetReportEmitter.defaultSummaries
    ) throws -> URL? {
        let byProfile = group.profiles.map { (profile: $0, summaries: summariesFor($0)) }
        guard let model = FleetWorkbookModel.build(
            groupName: group.name, summariesByProfile: byProfile,
            lookbackDays: lookbackDays, timestamp: timestamp
        ) else { return nil }

        let dir = outputDir ?? FleetReportEmitter.consolidatedDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(
            "fleet-\(ExportNaming.sanitize(group.name))-\(timestamp).xlsx")
        try workbook(for: model).write(to: url)
        return url
    }

    /// Pure model → workbook assembly (5 sheets). Testable without IO.
    static func workbook(for model: FleetWorkbookModel) -> Workbook {
        let wb = Workbook()
        fleetSummarySheet(wb.addSheet("Fleet Summary"), model)
        perProfileSheet(wb.addSheet("Per-Profile Breakdown"), model)
        securityPostureSheet(wb.addSheet("Security Posture"), model)
        complianceSheet(wb.addSheet("Compliance"), model)
        fleetTrendSheet(wb.addSheet("Fleet Trend"), model)
        return wb
    }

    // MARK: - Fleet Summary

    private static func fleetSummarySheet(_ ws: Worksheet, _ model: FleetWorkbookModel) {
        ws.setColumnWidth(0, 0, 22)
        ws.setColumnWidth(1, 3, 14)
        ws.write(model.groupName, row: 0, col: 0, format: .title)
        ws.write("Generated \(model.generatedAt)", row: 1, col: 0, format: .subtitle)
        let head = 3
        for (c, h) in ["Metric", "Current", "Previous", "Δ"].enumerated() {
            ws.write(h, row: head, col: c, format: .header)
        }
        for (i, m) in model.universal.enumerated() {
            let r = head + 1 + i
            ws.write(m.label, row: r, col: 0, format: .cell)
            ws.write(FleetReportEmitter.format(m.value, unit: m.unit), row: r, col: 1, format: .cell)
            ws.write(FleetReportEmitter.format(m.previous, unit: m.unit), row: r, col: 2, format: .cell)
            ws.write(FleetReportEmitter.formatDelta(m.delta, unit: m.unit), row: r, col: 3, format: .cell)
        }
        let withFV = model.perProfile.filter { $0.fileVaultPct != nil }
        guard !withFV.isEmpty else { return }
        let bar = BarChartData(
            categories: withFV.map(\.profile),
            values: withFV.map { $0.fileVaultPct ?? 0 },
            colors: withFV.enumerated().map { ChartPalette.color(for: $0.offset) })
        if let png = ChartRenderer.barChart(data: bar, title: "FileVault % by Profile") {
            ws.insertImage(row: head + model.universal.count + 3, col: 0,
                           data: png, filename: "fleet-fv-by-profile.png")
        }
    }

    // MARK: - Per-Profile Breakdown

    private static func perProfileSheet(_ ws: Worksheet, _ model: FleetWorkbookModel) {
        let headers = ["Profile", "Devices", "FileVault %", "SIP %", "Firewall %",
                       "Gatekeeper %", "Patch %", "OS Current %", "Security Score",
                       "Stale", "Baseline(s)", "Compliance %"]
        for (c, h) in headers.enumerated() { ws.write(h, row: 0, col: c, format: .header) }
        ws.freezePane(row: 1, col: 0)
        for (i, p) in model.perProfile.enumerated() {
            let r = i + 1
            ws.write(p.profile, row: r, col: 0, format: .cell)
            ws.write(p.devices, row: r, col: 1, format: .int)
            ws.write(pct(p.fileVaultPct), row: r, col: 2, format: .cell)
            ws.write(pct(p.sipPct), row: r, col: 3, format: .cell)
            ws.write(pct(p.firewallPct), row: r, col: 4, format: .cell)
            ws.write(pct(p.gatekeeperPct), row: r, col: 5, format: .cell)
            ws.write(pct(p.patchPct), row: r, col: 6, format: .cell)
            ws.write(pct(p.osCurrentPct), row: r, col: 7, format: .cell)
            ws.write(pct(p.securityScore), row: r, col: 8, format: .cell)
            ws.write(p.staleCount.map(String.init) ?? "—", row: r, col: 9, format: .cell)
            ws.write(p.baselineNames.isEmpty ? "—" : p.baselineNames.joined(separator: ", "),
                     row: r, col: 10, format: .cell)
            ws.write(pct(p.compliancePct), row: r, col: 11, format: .cell)
        }
    }

    // MARK: - Security Posture

    private static func securityPostureSheet(_ ws: Worksheet, _ model: FleetWorkbookModel) {
        ws.setColumnWidth(0, 0, 18)
        ws.write("Control", row: 0, col: 0, format: .header)
        ws.write("Fleet %", row: 0, col: 1, format: .header)
        let controls = model.universal.filter { $0.unit == .percent }
        for (i, m) in controls.enumerated() {
            ws.write(m.label, row: i + 1, col: 0, format: .cell)
            ws.write(FleetReportEmitter.format(m.value, unit: m.unit), row: i + 1, col: 1, format: .cell)
        }
        let present = controls.filter { $0.value != nil }
        guard !present.isEmpty else { return }
        let bar = BarChartData(
            categories: present.map(\.label),
            values: present.map { $0.value ?? 0 },
            colors: present.enumerated().map { ChartPalette.color(for: $0.offset) })
        if let png = ChartRenderer.barChart(data: bar, title: "Fleet Security Posture") {
            ws.insertImage(row: controls.count + 3, col: 0, data: png, filename: "fleet-posture.png")
        }
    }

    // MARK: - Compliance (baseline-grouped)

    private static func complianceSheet(_ ws: Worksheet, _ model: FleetWorkbookModel) {
        ws.setColumnWidth(0, 0, 20)
        guard !model.bandGroups.isEmpty else {
            ws.write("No mSCP baseline data reported by any profile in this group.",
                     row: 0, col: 0, format: .subtitle)
            return
        }
        var row = 0
        for group in model.bandGroups {
            row = complianceGroupBlock(ws, group, startRow: row) + 2
        }
    }

    private static func complianceGroupBlock(
        _ ws: Worksheet, _ group: FleetWorkbookModel.BandGroup, startRow: Int
    ) -> Int {
        var row = startRow
        ws.write("Baseline: \(group.baseline)", row: row, col: 0, format: .title); row += 1
        ws.write("Profiles: \(group.profiles.joined(separator: ", "))",
                 row: row, col: 0, format: .subtitle); row += 1
        ws.write("Compliance %: \(pct(group.compliancePct))",
                 row: row, col: 0, format: .subtitle); row += 2
        ws.write("Band", row: row, col: 0, format: .header)
        ws.write("Devices", row: row, col: 1, format: .header); row += 1
        let b = group.bands
        let bands: [(String, Int)] = [
            ("Pass", b.pass), ("Low (1–10)", b.low), ("Med-Low (11–30)", b.medLow),
            ("Medium (31–50)", b.medium), ("High (>50)", b.high), ("No Data", b.noData)]
        for (label, count) in bands {
            ws.write(label, row: row, col: 0, format: .cell)
            ws.write(count, row: row, col: 1, format: .int); row += 1
        }
        let slices = bands.enumerated().compactMap { idx, br -> ChartRenderer.DonutSlice? in
            br.1 > 0 ? ChartRenderer.DonutSlice(
                label: br.0, count: br.1, pct: Double(br.1) / Double(max(b.total, 1)) * 100,
                color: ChartPalette.complianceBandColorsWithNoData[idx]) : nil
        }
        if let png = ChartRenderer.donutChart(
            slices: slices, title: group.baseline, footer: "Total devices: \(b.total)") {
            ws.insertImage(row: startRow, col: 3, data: png,
                           filename: "fleet-bands-\(ExportNaming.sanitize(group.baseline)).png")
        }
        if group.series.count >= 2, let png = bandStackplot(group) {
            ws.insertImage(row: row + 1, col: 0, data: png,
                           filename: "fleet-bandtrend-\(ExportNaming.sanitize(group.baseline)).png")
            // reserve ~26 rows for the embedded stackplot before the next baseline block
            row += 26
        }
        return row
    }

    private static func bandStackplot(_ group: FleetWorkbookModel.BandGroup) -> Data? {
        // 5 bands only — "No Data" has no area in a stacked trend (the donut includes it; this doesn't).
        let bandKeys: [(label: String, value: (MSCPBandCounts) -> Int)] = [
            ("Pass", { $0.pass }), ("Low", { $0.low }), ("Med-Low", { $0.medLow }),
            ("Medium", { $0.medium }), ("High", { $0.high })]
        let series = bandKeys.enumerated().map { idx, bk -> ChartSeries in
            let points = group.series.compactMap { bp -> (date: Date, value: Double)? in
                guard let date = SummaryJSONParser.dateFormatter.date(from: bp.date) else { return nil }
                return (date: date, value: Double(bk.value(bp.bands)))
            }
            return ChartSeries(
                label: bk.label, color: ChartPalette.complianceBandColors[idx], points: points)
        }
        return ChartRenderer.stackedAreaChart(
            series: series, title: "\(group.baseline) — Bands Over Time")
    }

    // MARK: - Fleet Trend

    private static func fleetTrendSheet(_ ws: Worksheet, _ model: FleetWorkbookModel) {
        let headers = ["Date", "Devices", "FileVault %", "SIP %", "Firewall %",
                       "Gatekeeper %", "Patch %", "OS Current %", "Security Score"]
        for (c, h) in headers.enumerated() { ws.write(h, row: 0, col: c, format: .header) }
        ws.freezePane(row: 1, col: 0)
        for (i, t) in model.trend.enumerated() {
            let r = i + 1
            ws.write(t.date, row: r, col: 0, format: .cell)
            ws.write(t.devices, row: r, col: 1, format: .int)
            ws.write(pct(t.fileVaultPct), row: r, col: 2, format: .cell)
            ws.write(pct(t.sipPct), row: r, col: 3, format: .cell)
            ws.write(pct(t.firewallPct), row: r, col: 4, format: .cell)
            ws.write(pct(t.gatekeeperPct), row: r, col: 5, format: .cell)
            ws.write(pct(t.patchPct), row: r, col: 6, format: .cell)
            ws.write(pct(t.osCurrentPct), row: r, col: 7, format: .cell)
            ws.write(pct(t.securityScore), row: r, col: 8, format: .cell)
        }
        if model.trend.count >= 2, let png = trendLine(model) {
            ws.insertImage(row: model.trend.count + 3, col: 0, data: png, filename: "fleet-trend.png")
        }
    }

    private static func trendLine(_ model: FleetWorkbookModel) -> Data? {
        let kpis: [(label: String, value: (FleetWorkbookModel.TrendPoint) -> Double?)] = [
            ("FileVault %", { $0.fileVaultPct }), ("SIP %", { $0.sipPct }),
            ("Firewall %", { $0.firewallPct }), ("Gatekeeper %", { $0.gatekeeperPct }),
            ("Patch %", { $0.patchPct }), ("OS Current %", { $0.osCurrentPct }),
            ("Security Score", { $0.securityScore })]
        let series = kpis.enumerated().compactMap { idx, kpi -> ChartSeries? in
            let points = model.trend.compactMap { tp -> (date: Date, value: Double)? in
                guard let date = SummaryJSONParser.dateFormatter.date(from: tp.date),
                      let value = kpi.value(tp) else { return nil }
                return (date: date, value: value)
            }
            return points.isEmpty ? nil
                : ChartSeries(label: kpi.label, color: ChartPalette.color(for: idx), points: points)
        }
        return series.isEmpty ? nil : ChartRenderer.lineChart(series: series, title: "Fleet Trend")
    }

    // MARK: - Cell formatting

    private static func pct(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? "—"
    }

}
