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
        /// True when both ends have a value but were recorded under different
        /// definitions of it; `change` is then nil, since the gap is the definition.
        var definitionChanged: Bool = false
    }

    /// The About-sheet note for a row whose `definitionChanged` is set.
    static let patchDefinitionNote = "Patch compliance changed definition during this period "
        + "(device-weighted from 2.9); the change is not shown."

    static let securityScoreDefinitionNote = "The security score changed definition during this "
        + "period (it weighs a different set of inputs at the two ends, such as the EDR agent "
        + "and mSCP compliance); the change is not shown."

    /// The About-sheet note for a metric whose ends were recorded under different definitions.
    static func definitionNote(for metricID: String) -> String? {
        switch metricID {
        case "patchPct": return patchDefinitionNote
        case "securityScore": return securityScoreDefinitionNote
        default: return nil
        }
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
                // A patch figure from before `patchPctBasis` is a per-title mean, so its
                // gap to a device-weighted end is the definition, not the fleet.
                let changedDefinition = s != nil && e != nil
                    && Self.definitionDiffers(metric.id, startSummary, endSummary)
                var change: Double?
                if let s, let e, !changedDefinition { change = e - s }
                return Row(metricID: metric.id, label: metric.label, unit: metric.unit,
                           startValue: s, endValue: e, change: change,
                           startDate: period.start.resolved, endDate: period.end.resolved,
                           definitionChanged: changedDefinition)
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

    /// Whether the two summaries recorded `metricID` under different definitions: patch
    /// compliance by `patchPctBasis`, the security score by `securityScoreBasis` (the metrics
    /// it weighs).
    private static func definitionDiffers(
        _ metricID: String, _ start: DailySummary?, _ end: DailySummary?
    ) -> Bool {
        switch metricID {
        case "patchPct": return start?.patchPctBasis != end?.patchPctBasis
        case "securityScore": return start?.securityScoreBasis != end?.securityScoreBasis
        default: return false
        }
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

    /// Distributions have no single figure; everything else defers to the one
    /// formatting rule the fleet reports already use, so the same quantity is
    /// not rendered two ways in one app.
    static func formatValue(_ v: Double?, unit: PeriodMetric.Unit) -> String {
        guard let rollupUnit = unit.rollupUnit else { return "—" }
        return FleetReportEmitter.format(v, unit: rollupUnit)
    }

    /// Percentage change is in percentage points, per `formatDelta`'s existing
    /// rule — a figure quoted into a management document must not be ambiguous
    /// about which it means.
    static func formatChange(_ v: Double?, unit: PeriodMetric.Unit) -> String {
        guard let rollupUnit = unit.rollupUnit else { return "—" }
        return FleetReportEmitter.formatDelta(v, unit: rollupUnit)
    }

    private static func dayDate(_ s: String, _ c: Calendar) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = c; f.timeZone = .current
        return f.date(from: s).map(c.startOfDay(for:))
    }
}
