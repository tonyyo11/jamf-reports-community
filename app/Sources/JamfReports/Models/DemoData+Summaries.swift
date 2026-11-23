import Foundation

/// Each demo workspace's history: the Trends series, the Overview score cards and Fleet
/// Overview's summaries. A series a workspace's products cannot fill is absent, never zero,
/// and every mobile, Protect and School series ends on the summary its screens describe.
extension DemoData {

    /// The series Trends and the Overview chart for `workspace`, cached per demo workspace.
    static func trends(for workspace: String) -> [TrendSeries.Metric: [Double]] {
        trendsByWorkspace[workspace] ?? trendsByWorkspace[org.profile] ?? trends
    }

    private static let trendsByWorkspace: [String: [TrendSeries.Metric: [Double]]] =
        Dictionary(cliProfiles.map { ($0.name, buildTrends(for: $0.name)) },
                   uniquingKeysWith: { first, _ in first })

    private static func buildTrends(for workspace: String) -> [TrendSeries.Metric: [Double]] {
        let environment = environmentProducts(for: workspace)
        if environment.isSchool { return schoolTrends }
        var series = trends
        if environment.composition != .macsOnly { series.merge(mobileTrends) { $1 } }
        if environment.has(.protect) { series.merge(protectTrends) { $1 } }
        return series
    }

    // MARK: - Protect

    /// The Protect figures a summary records from the Protect screen's own demo rows: the
    /// pilot's computers matched by the Protect screen's calculator, and its open alerts.
    static func protectFigures(for workspace: String) -> ProtectSummaryFigures? {
        guard environmentProfiles(for: workspace).protect != nil else { return nil }
        let computers = protectSnapshot.computers
        let matched = ProtectProCorrelation.load(
            protect: computers, profile: workspace, demoMode: true)?.matchedShare
        return ProtectSummaryFigures(
            computers: .init(count: computers.count, matched: matched),
            alerts: ReportEngine.protectAlertFigures(protectSnapshot.alerts))
    }

    /// The summary fields Protect fills, on the newest day only.
    private static var protectSummary: DailySummary {
        DailySummary(date: "", totalDevices: 0, fileVaultPct: nil, compliancePct: nil,
                     staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil)
            .withEnvironment(products: nil, protect: protectFigures(for: org.profile))
    }

    /// The pilot grew from 6 Macs; the last week is the Protect screen's.
    private static let protectTrends: [TrendSeries.Metric: [Double]] = endingOn(
        protectSummary, [
            .protectComputers: (start: 6, jitter: 0.6, isCount: true),
            .protectMatched: (start: 92, jitter: 1.5, isCount: false),
            .protectOpenAlerts: (start: 5, jitter: 1.2, isCount: true),
        ])

    // MARK: - Mobile

    /// The 25 demo mobile devices' history, ending on `mobileSummary`.
    private static let mobileTrends: [TrendSeries.Metric: [Double]] = endingOn(
        DailySummary(date: "", totalDevices: 0, fileVaultPct: nil, compliancePct: nil,
                     staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
                     mobile: mobileSummary), [
            .mobileManaged: (start: -4, jitter: 0.8, isCount: true),
            .mobileOSCurrent: (start: -22, jitter: 4, isCount: false),
            .mobilePasscode: (start: -10, jitter: 2, isCount: false),
            .mobileSupervised: (start: -6, jitter: 1.5, isCount: false),
            .mobileDataProtection: (start: -8, jitter: 2, isCount: false),
            .mobileStale: (start: 3, jitter: 0.8, isCount: true),
            .mobileJailbroken: (start: 0, jitter: 0, isCount: true),
        ], relative: true)

    // MARK: - Jamf School

    /// meridianedu's history: Macs, stale Macs and the mobile figures School rows carry,
    /// ending on `schoolSummary`. No SOFA feed is cached, so no OS currency series.
    private static let schoolTrends: [TrendSeries.Metric: [Double]] = {
        guard let summary = schoolSummary else { return [:] }
        var series: [TrendSeries.Metric: [Double]] = [
            .managedDevices: rounded(trend(
                start: Double(summary.totalDevices - 41), end: Double(summary.totalDevices),
                jitter: 3, pinnedLast: Double(summary.totalDevices))),
        ]
        if let stale = summary.staleCount {
            series[.stale] = rounded(trend(
                start: Double(stale + 9), end: Double(stale), jitter: 2,
                pinnedLast: Double(stale))).map { max($0, 0) }
        }
        return series.merging(endingOn(summary, [
            .mobileManaged: (start: -28, jitter: 2, isCount: true),
            .mobileSupervised: (start: -5, jitter: 1, isCount: false),
            .mobileStale: (start: 6, jitter: 1.5, isCount: true),
        ], relative: true)) { $1 }
    }()

    // MARK: - Helpers

    /// A series per metric that has a value in `summary`, ending exactly on it. `start` is the
    /// first week's value, or its distance from the last when `relative`. Shares stay within
    /// 0-100, counts are whole and never negative.
    private static func endingOn(
        _ summary: DailySummary,
        _ specs: [TrendSeries.Metric: (start: Double, jitter: Double, isCount: Bool)],
        relative: Bool = false
    ) -> [TrendSeries.Metric: [Double]] {
        specs.reduce(into: [:]) { series, entry in
            guard let last = TrendStore.environmentValue(entry.key, in: summary) else { return }
            let start = relative ? last + entry.value.start : entry.value.start
            let points = trend(start: start, end: last, jitter: entry.value.jitter,
                               pinnedLast: last)
            series[entry.key] = entry.value.isCount
                ? rounded(points).map { max($0, 0) }
                : Array(points.map { min(max($0, 0), 100) }.dropLast()) + [last]
        }
    }

    private static func rounded(_ values: [Double]) -> [Double] { values.map { $0.rounded() } }

    // MARK: - Fleet Overview

    /// `workspace`'s daily summaries, oldest first, for Fleet Overview. meridian-prod's are the
    /// Overview's fleet; each later Jamf Pro workspace is a smaller variation with one week
    /// less history. The newest day carries the device maps, mobile figures, products and
    /// Protect figures its environment has; meridianedu's are its School summaries.
    static func fleetSummaries(for workspace: String) -> [DailySummary] {
        let environment = environmentProducts(for: workspace)
        if environment.isSchool { return schoolFleetSummaries }
        let idx = cliProfiles.firstIndex { $0.name == workspace } ?? 0
        let offset = Double(idx * 4)
        let lastIndex = max(trendDates.count - 1 - idx, 0)
        let series = trends(for: workspace)
        func value(_ metric: TrendSeries.Metric, at i: Int) -> Double {
            series[metric]?[safe: i] ?? series[metric]?.last ?? 0
        }
        let mixed = environment.composition != .macsOnly
        return (0...lastIndex).map { i in
            let newest = i == lastIndex
            let maps = newest ? deviceMaps(forProfileAt: idx, mobile: mixed) : .init()
            let summary = DailySummary(
                date: trendDates[safe: i] ?? "2026-04-20",
                totalDevices: deviceCount(forProfileAt: idx),
                fileVaultPct: value(.fileVault, at: i) - offset,
                compliancePct: max(value(.compliance, at: i) - offset, 0),
                staleCount: Int(value(.stale, at: i).rounded()) + idx * 4,
                osCurrentPct: value(.osCurrent, at: i) - offset,
                crowdstrikePct: value(.edrAgent, at: i) - offset,
                patchPct: value(.patch, at: i) - offset,
                mobileDeviceCount: newest && mixed ? mobileDeviceCount : nil,
                mobile: newest && mixed ? mobileSummary : nil,
                osMajorCounts: maps.osMajor,
                modelFamilyCounts: maps.modelFamily,
                mobileFormFactorCounts: maps.formFactor,
                lastSeenBuckets: maps.lastSeen)
            guard newest else { return summary }
            return summary.withEnvironment(
                products: environment.products.map(\.slotName).sorted(),
                protect: protectFigures(for: workspace))
        }
    }

    /// meridianedu's weekly summaries: Macs and stale Macs from its trend, then the newest
    /// written by the School writer from `schoolSnapshot`.
    private static let schoolFleetSummaries: [DailySummary] = {
        let macs = schoolTrends[.managedDevices] ?? []
        let stale = schoolTrends[.stale] ?? []
        let older = trendDates.indices.dropLast().map { i in
            DailySummary(
                date: trendDates[i], totalDevices: Int((macs[safe: i] ?? 0).rounded()),
                fileVaultPct: nil, compliancePct: nil,
                staleCount: stale[safe: i].map { Int($0.rounded()) }, osCurrentPct: nil,
                crowdstrikePct: nil, patchPct: nil, source: "jamf-cli")
        }
        return older + [schoolSummary].compactMap { $0 }
    }()

    /// The device maps of the profile at `index`: meridian-prod's are `summaryDeviceMaps`;
    /// each later one is those Mac maps scaled to its own Mac count, each map summing to it.
    static func deviceMaps(forProfileAt index: Int, mobile: Bool) -> SummaryDeviceMaps.Fields {
        let maps = summaryDeviceMaps
        guard index > 0 else { return maps }
        let total = deviceCount(forProfileAt: index)
        let macOS = maps.osMajor?.filter { $0.key.hasPrefix("macOS ") }
        let mobileOS = mobile ? maps.osMajor?.filter { !$0.key.hasPrefix("macOS ") } : nil
        return SummaryDeviceMaps.Fields(
            osMajor: scaled(macOS, to: total).map {
                $0.merging(mobileOS ?? [:], uniquingKeysWith: +)
            },
            modelFamily: scaled(maps.modelFamily, to: total),
            formFactor: mobile ? maps.formFactor : nil,
            lastSeen: maps.lastSeen.map { seen in
                LastSeenBuckets(
                    computers: seen.computers.map { scaled($0, to: total) },
                    mobile: mobile ? seen.mobile : nil)
            })
    }

    /// Largest-remainder scaling of `counts` to sum to `total`; ties go to the larger bucket.
    private static func scaled(_ counts: [String: Int]?, to total: Int) -> [String: Int]? {
        guard let counts, !counts.isEmpty else { return nil }
        let sum = counts.values.reduce(0, +)
        guard sum > 0 else { return counts }
        let exact = counts.map { ($0.key, Double($0.value) * Double(total) / Double(sum)) }
        var result = Dictionary(uniqueKeysWithValues: exact.map { ($0.0, Int($0.1)) })
        let left = total - result.values.reduce(0, +)
        let order = exact.sorted {
            let (a, b) = ($0.1 - $0.1.rounded(.down), $1.1 - $1.1.rounded(.down))
            return a != b ? a > b : ($0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0)
        }
        for (key, _) in order.prefix(left) { result[key, default: 0] += 1 }
        return result.filter { $0.value > 0 }
    }

    private static func scaled(
        _ counts: LastSeenBuckets.Counts, to total: Int
    ) -> LastSeenBuckets.Counts {
        let keys = ["under", "week", "older", "never"]
        let values = [counts.underOneDay, counts.underSevenDays, counts.sevenDaysOrMore,
                      counts.never].map { $0 ?? 0 }
        let out = scaled(Dictionary(uniqueKeysWithValues: zip(keys, values)), to: total) ?? [:]
        return LastSeenBuckets.Counts(
            underOneDay: out["under"], underSevenDays: out["week"],
            sevenDaysOrMore: out["older"], never: out["never"])
    }
}
