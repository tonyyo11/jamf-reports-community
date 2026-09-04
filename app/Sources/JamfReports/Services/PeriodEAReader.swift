import Foundation

/// Turns dated `ea-results` snapshots into per-boundary extension-attribute values.
enum PeriodEAReader {

    /// Groups one snapshot's rows by EA name, then by device identifier. The
    /// identifier prefers computer_id and falls back through serial and device
    /// name, matching how `MSCPComplianceService.primaryIdentifier` joins rows
    /// across the differing shapes jamf-cli has emitted.
    static func snapshot(from data: Data, at date: Date) -> PeriodEASnapshot? {
        guard let rows = EAResultRow.decodeSnapshot(data).rows else { return nil }
        var byEA: [String: [String: String]] = [:]
        for row in rows {
            guard let name = row.eaName else { continue }
            let id = row.computerId ?? row.serial ?? row.device ?? row.computerName
            guard let id, !id.isEmpty else { continue }
            byEA[name, default: [:]][id.lowercased()] = row.value?.stringValue ?? ""
        }
        return PeriodEASnapshot(date: date, valuesByEA: byEA)
    }

    /// Newest `ea-results` snapshot on or before `date`, if one exists.
    static func load(dataDir: URL, on date: Date) -> PeriodEASnapshot? {
        let dir = dataDir.appendingPathComponent("ea-results", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        let candidate = files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json" }
            .compactMap { url -> (Date, URL)? in
                guard let d = CloudStorage.snapshotTimestamp(of: url) else { return nil }
                return (d, url)
            }
            .filter { $0.0 <= date }
            .sorted { $0.0 < $1.0 }
            .last
        guard let candidate, let data = try? Data(contentsOf: candidate.1) else { return nil }
        return snapshot(from: data, at: candidate.0)
    }
}

extension PeriodEASnapshot {
    /// How many devices reported an attribute, and how many distinct values they
    /// gave. The ratio is what separates a status from an identifier.
    func cardinality(of ea: String) -> (devices: Int, distinct: Int) {
        guard let values = valuesByEA[ea] else { return (0, 0) }
        return (values.count, Set(values.values).count)
    }
}

extension PeriodMetricCatalog {
    /// Below this many reporting devices, "every value is distinct" is
    /// coincidence rather than evidence.
    static let identifierMinimumSample = 8

    /// Above this share of distinct values, an attribute is a serial, hostname
    /// or certificate subject rather than a status worth tabulating.
    static let identifierDistinctRatio = 0.8

    /// True when an attribute's values look like per-device identifiers.
    ///
    /// This is the one place an otherwise-aggregate report can carry per-device
    /// data, so the picker warns before such an attribute is chosen rather than
    /// after it reaches a workbook someone forwards.
    static func looksLikeIdentifier(distinct: Int, devices: Int) -> Bool {
        guard devices >= identifierMinimumSample else { return false }
        return Double(distinct) / Double(devices) >= identifierDistinctRatio
    }
}

extension PeriodReportModel {
    static func eaRow(
        metric: PeriodMetric, name: String, match: String?,
        period: ReportPeriod, snapshots: [PeriodEASnapshot]
    ) -> Row {
        let cal = Calendar(identifier: .gregorian)
        func values(_ target: Date) -> [String: String]? {
            snapshots.first { cal.isDate($0.date, inSameDayAs: target) }?.valuesByEA[name]
        }
        let startValues = values(period.start.resolved)
        let endValues = values(period.end.resolved)

        if let match {
            let needle = match.lowercased()
            func count(_ v: [String: String]?) -> Double? {
                guard let v else { return nil }
                return Double(v.values.filter { $0.lowercased().contains(needle) }.count)
            }
            let s = count(startValues), e = count(endValues)
            return Row(metricID: metric.id, label: metric.label, unit: .count,
                       startValue: s, endValue: e,
                       change: (s != nil && e != nil) ? e! - s! : nil,
                       startDate: period.start.resolved, endDate: period.end.resolved)
        }

        let start = cappedDistribution(startValues)
        let end = cappedDistribution(endValues)
        return Row(metricID: metric.id, label: metric.label, unit: .distribution,
                   startValue: nil, endValue: nil, change: nil,
                   startDate: period.start.resolved, endDate: period.end.resolved,
                   startDistribution: start.kept, endDistribution: end.kept,
                   omittedValueCount: max(start.omitted, end.omitted))
    }

    /// Most common values first, capped. Truncation is returned rather than
    /// silently applied — a shortened table that does not say so reads as the
    /// whole picture.
    private static func cappedDistribution(
        _ values: [String: String]?
    ) -> (kept: [String: Int], omitted: Int) {
        guard let values else { return ([:], 0) }
        let counts = Dictionary(
            values.values.map { ($0.isEmpty ? "(empty)" : $0, 1) }, uniquingKeysWith: +)
        guard counts.count > maxDistinctValues else { return (counts, 0) }
        let kept = counts.sorted { ($0.value, $0.key) > ($1.value, $1.key) }
            .prefix(maxDistinctValues)
        return (Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) }),
                counts.count - kept.count)
    }
}
