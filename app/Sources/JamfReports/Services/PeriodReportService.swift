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
    static func cardinality(profile: String, ea: String) -> (devices: Int, distinct: Int) {
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile),
              let snap = PeriodEAReader.load(dataDir: dataDir, on: Date()) else { return (0, 0) }
        return snap.cardinality(of: ea)
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
