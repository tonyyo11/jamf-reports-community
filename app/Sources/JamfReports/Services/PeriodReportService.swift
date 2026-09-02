import Foundation

/// Thin IO shell: gathers a profile's summaries, extension-attribute snapshots
/// and config, then hands the pure model and emitter the work.
enum PeriodReportService {

    enum ServiceError: Error, LocalizedError {
        case noDataInPeriod
        var errorDescription: String? {
            switch self {
            case .noDataInPeriod:
                "No collected data falls inside that period, so there is nothing to report."
            }
        }
    }

    /// Everything this profile could report on, fleet metrics first.
    static func catalog(profile: String) -> [PeriodMetric] {
        let summaries = loadSummaries(profile: profile)
        let config = loadConfig(profile: profile)
        return PeriodMetricCatalog.fleetMetrics(in: summaries)
            + PeriodMetricCatalog.eaMetrics(
                names: eaNames(profile: profile),
                customEAs: config?.customEas ?? [],
                securityAgents: config?.securityAgents ?? [])
    }

    /// Fleet metrics only. Extension attributes are opt-in: a value can be a
    /// username, serial or certificate subject, and this report is destined for
    /// a document someone forwards.
    static func defaultSelection(from catalog: [PeriodMetric]) -> [String] {
        catalog.filter { $0.source == .fleet }.map(\.id)
    }

    /// Drops saved selections that name a metric no longer offered — a profile
    /// whose EA disappeared should not show an error for a choice it no longer
    /// has.
    static func pruneSelection(_ selection: [String], available: [PeriodMetric]) -> [String] {
        let ids = Set(available.map(\.id))
        return selection.filter { ids.contains($0) }
    }

    /// Reporting devices and distinct values for an attribute, so the picker can
    /// warn about identifier-shaped ones before they are chosen.
    ///
    /// Once a period has resolved, this checks BOTH boundary snapshots — an
    /// attribute can be identifier-shaped at the start of the window and
    /// status-shaped at the end (or vice versa) — and returns whichever
    /// reading looks more like an identifier. Without a period (not yet
    /// resolved), it falls back to the newest snapshot. For more than one
    /// attribute, prefer `cardinalityBatch` — this reloads `ea-results` on
    /// every call.
    static func cardinality(
        profile: String, ea: String, period: ReportPeriod? = nil
    ) -> (devices: Int, distinct: Int) {
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else { return (0, 0) }
        return best(of: ea, in: boundarySnapshots(dataDir: dataDir, period: period))
    }

    /// Cardinality for several attributes at once, loading the resolved
    /// period's boundary snapshots — or the newest snapshot, with no period —
    /// exactly ONCE and sharing them across every attribute. On a large EA
    /// set this avoids `cardinality(profile:ea:period:)`'s per-attribute
    /// reload: two `ea-results` decodes total here versus two per attribute
    /// there.
    static func cardinalityBatch(
        profile: String, eas: [String], period: ReportPeriod? = nil
    ) -> [String: (devices: Int, distinct: Int)] {
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else { return [:] }
        let snapshots = boundarySnapshots(dataDir: dataDir, period: period)
        return Dictionary(uniqueKeysWithValues: eas.map { ($0, best(of: $0, in: snapshots)) })
    }

    /// The period's start/end snapshots, or the newest snapshot when there is
    /// no period yet.
    private static func boundarySnapshots(
        dataDir: URL, period: ReportPeriod?
    ) -> [PeriodEASnapshot] {
        guard let period else {
            return [PeriodEAReader.load(dataDir: dataDir, on: Date())].compactMap { $0 }
        }
        return [period.start.resolved, period.end.resolved].compactMap {
            PeriodEAReader.load(dataDir: dataDir, on: $0)
        }
    }

    /// The more identifier-shaped of an attribute's readings across the
    /// supplied (already-loaded) snapshots.
    ///
    /// `PeriodMetricCatalog.looksLikeIdentifier` requires a minimum sample
    /// size before the ratio counts at all, so ranking by ratio alone can let
    /// a tiny, coincidentally all-distinct snapshot (e.g. 3 devices, 3
    /// values) outrank a well-sampled one that actually clears the
    /// identifier threshold (e.g. 200 devices, 190 values). Flagged status is
    /// therefore the primary key; the ratio is only a tiebreak between two
    /// readings that agree on flagged-ness.
    private static func best(
        of ea: String, in snapshots: [PeriodEASnapshot]
    ) -> (devices: Int, distinct: Int) {
        snapshots.map { $0.cardinality(of: ea) }.max(by: isRankedBelow) ?? (0, 0)
    }

    private static func isRankedBelow(
        _ lhs: (devices: Int, distinct: Int), _ rhs: (devices: Int, distinct: Int)
    ) -> Bool {
        let lhsFlagged = PeriodMetricCatalog.looksLikeIdentifier(
            distinct: lhs.distinct, devices: lhs.devices)
        let rhsFlagged = PeriodMetricCatalog.looksLikeIdentifier(
            distinct: rhs.distinct, devices: rhs.devices)
        if lhsFlagged != rhsFlagged { return rhsFlagged }
        return identifierRatio(lhs) < identifierRatio(rhs)
    }

    /// The share of distinct values among reporting devices — higher means
    /// more identifier-shaped. Guards the empty-devices case rather than
    /// dividing by zero.
    private static func identifierRatio(_ c: (devices: Int, distinct: Int)) -> Double {
        guard c.devices > 0 else { return 0 }
        return Double(c.distinct) / Double(c.devices)
    }

    /// The period a picker choice resolves to, so a caller can evaluate
    /// against real boundaries before a report is actually generated.
    static func resolvedPeriod(
        profile: String, kind: ReportPeriod.Kind, now: Date = Date()
    ) -> ReportPeriod? {
        let dates = loadSummaries(profile: profile).compactMap { dayDate($0.date) }
        return ReportPeriod.resolve(kind: kind, availableDates: dates, now: now)
    }

    @discardableResult
    static func generate(
        profile: String, kind: ReportPeriod.Kind, metricIDs: [String], now: Date = Date()
    ) throws -> URL {
        let summaries = loadSummaries(profile: profile)
        let dates = summaries.compactMap { dayDate($0.date) }
        guard let period = ReportPeriod.resolve(kind: kind, availableDates: dates, now: now) else {
            throw ServiceError.noDataInPeriod
        }
        let all = catalog(profile: profile)
        let wanted = metricIDs.isEmpty ? defaultSelection(from: all) : metricIDs
        let selected = all.filter { wanted.contains($0.id) }

        var eaSnapshots: [PeriodEASnapshot] = []
        if selected.contains(where: { if case .extensionAttribute = $0.source { return true }
                                      return false }),
           let dataDir = try? WorkspacePaths.dataDir(for: profile) {
            eaSnapshots = [PeriodEAReader.load(dataDir: dataDir, on: period.start.resolved),
                           PeriodEAReader.load(dataDir: dataDir, on: period.end.resolved)]
                .compactMap { $0 }
        }

        let model = PeriodReportModel.build(
            period: period, metrics: selected, summaries: summaries,
            eaSnapshots: eaSnapshots, profile: profile, generatedAt: now)

        let dir = try WorkspacePaths.outputDir(for: profile)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(ExportNaming.filename(
            kind: PeriodReportEmitter.reportKind(for: model),
            profile: profile, ext: "xlsx", now: now))
        try PeriodReportEmitter.emit(model: model, to: url)
        return url
    }

    // MARK: - IO

    private static func loadSummaries(profile: String) -> [DailySummary] {
        guard let dir = try? WorkspacePaths.summariesDir(for: profile) else { return [] }
        return SummaryJSONParser.parseDirectory(dir)
    }

    private static func loadConfig(profile: String) -> ReportConfig? {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return nil }
        return try? ConfigLoader.load(from: workspace.appendingPathComponent("config.yaml"))
    }

    private static func eaNames(profile: String) -> [String] {
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile),
              let snap = PeriodEAReader.load(dataDir: dataDir, on: Date()) else { return [] }
        return snap.valuesByEA.keys.sorted()
    }

    private static func dayDate(_ s: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f.date(from: s)
    }
}
