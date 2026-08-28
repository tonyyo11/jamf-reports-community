import Foundation

/// Per-boundary EA values, supplied by `PeriodEAReader`.
struct PeriodEASnapshot: Sendable, Equatable {
    let date: Date
    /// EA name -> (device identifier -> value)
    let valuesByEA: [String: [String: String]]
}

/// Pure aggregation of a reporting window into rows a workbook can render.
struct PeriodReportModel: Sendable {

    /// Distributions are capped here. Past this many distinct values an EA is
    /// not a status worth tabulating, and the sheet stops being readable.
    static let maxDistinctValues = 25

    /// One metric across the window. Values are `Double?` uniformly so counts
    /// and percentages share a row shape; `unit` decides rendering.
    struct Row: Sendable, Equatable {
        let metricID: String
        let label: String
        let unit: PeriodMetric.Unit
        let startValue: Double?
        let endValue: Double?
        let change: Double?
        let startDate: Date
        let endDate: Date
        var startDistribution: [String: Int] = [:]
        var endDistribution: [String: Int] = [:]
        /// Distinct values dropped by the cap, so truncation is stated rather
        /// than silently changing what the sheet appears to say.
        var omittedValueCount: Int = 0
    }

    struct DayPoint: Sendable, Equatable {
        let date: Date
        let values: [String: Double]
    }

    let period: ReportPeriod
    let profile: String
    let generatedAt: Date
    let rows: [Row]
    let days: [DayPoint]

    static func build(
        period: ReportPeriod,
        metrics: [PeriodMetric],
        summaries: [DailySummary],
        eaSnapshots: [PeriodEASnapshot],
        profile: String,
        generatedAt: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> PeriodReportModel {
        let inPeriod = summaries
            .compactMap { s -> (Date, DailySummary)? in
                guard let d = dayDate(s.date, calendar) else { return nil }
                return (d, s)
            }
            .filter { $0.0 >= calendar.startOfDay(for: period.start.resolved)
                   && $0.0 <= calendar.startOfDay(for: period.end.resolved) }
            .sorted { $0.0 < $1.0 }

        let startSummary = inPeriod.first?.1
        let endSummary = inPeriod.last?.1

        let rows: [Row] = metrics.map { metric in
            switch metric.source {
            case .fleet:
                let s = startSummary.flatMap { fleetValue(metric.id, $0) }
                let e = endSummary.flatMap { fleetValue(metric.id, $0) }
                // nil is not zero: without both ends there is no defensible change.
                let change: Double? = (s != nil && e != nil) ? (e! - s!) : nil
                return Row(metricID: metric.id, label: metric.label, unit: metric.unit,
                           startValue: s, endValue: e, change: change,
                           startDate: period.start.resolved, endDate: period.end.resolved)
            case .extensionAttribute(let name, let match):
                return eaRow(metric: metric, name: name, match: match,
                             period: period, snapshots: eaSnapshots)
            }
        }

        let days = inPeriod.map { (date, s) in
            var v: [String: Double] = [:]
            for m in metrics where m.source == .fleet {
                if let value = fleetValue(m.id, s) { v[m.id] = value }
            }
            return DayPoint(date: date, values: v)
        }

        return PeriodReportModel(period: period, profile: profile,
                                 generatedAt: generatedAt, rows: rows, days: days)
    }

    static func fleetValue(_ id: String, _ s: DailySummary) -> Double? {
        switch id {
        case "totalDevices":   return Double(s.totalDevices)
        case "fileVaultPct":   return s.fileVaultPct
        case "compliancePct":  return s.compliancePct
        case "osCurrentPct":   return s.osCurrentPct
        case "patchPct":       return s.patchPct
        case "sipPct":         return s.sipPct
        case "firewallPct":    return s.firewallPct
        case "gatekeeperPct":  return s.gatekeeperPct
        case "secureBootPct":  return s.secureBootPct
        case "bootstrapPct":   return s.bootstrapPct
        case "xprotectPct":    return s.xprotectPct
        case "cvePct":         return s.cvePct
        case "mscpScorePct":   return s.mscpScorePct
        case "securityScore":  return s.securityScore
        case "crowdstrikePct": return s.crowdstrikePct
        case "staleCount":     return s.staleCount.map(Double.init)
        default:               return nil
        }
    }

    static func formatValue(_ v: Double?, unit: PeriodMetric.Unit) -> String {
        guard let v else { return "—" }
        switch unit {
        case .percent:      return String(format: "%.1f%%", v)
        case .count:        return String(Int(v.rounded()))
        case .distribution: return "—"
        }
    }

    /// Percentage change is in percentage points — stated, because a figure
    /// quoted into a management document must not be ambiguous.
    static func formatChange(_ v: Double?, unit: PeriodMetric.Unit) -> String {
        guard let v else { return "—" }
        switch unit {
        case .percent:      return String(format: "%+.1f pp", v)
        case .count:        return String(format: "%+d", Int(v.rounded()))
        case .distribution: return "—"
        }
    }

    private static func dayDate(_ s: String, _ c: Calendar) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = c; f.timeZone = .current
        return f.date(from: s).map(c.startOfDay(for:))
    }
}

extension PeriodReportModel {
    /// Replaced in full by the EA task; present so this type compiles standalone.
    static func eaRow(
        metric: PeriodMetric, name: String, match: String?,
        period: ReportPeriod, snapshots: [PeriodEASnapshot]
    ) -> Row {
        Row(metricID: metric.id, label: metric.label, unit: metric.unit,
            startValue: nil, endValue: nil, change: nil,
            startDate: period.start.resolved, endDate: period.end.resolved)
    }
}
