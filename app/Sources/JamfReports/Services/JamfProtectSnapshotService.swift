import Foundation

struct JamfProtectSnapshot: Sendable {
    struct Metric: Identifiable, Sendable {
        var id: String { label }
        let label: String
        let value: String
        let detail: String
        let source: URL?
    }

    struct HistoryEntry: Identifiable, Sendable {
        var id: String { "\(kind)-\(source.path)" }
        let kind: String
        let count: Int?
        let summary: String
        let date: Date
        let source: URL
    }

    let profile: String
    let workspaceURL: URL?
    let dataRoots: [URL]
    let metrics: [Metric]
    let history: [HistoryEntry]

    var hasData: Bool { !metrics.isEmpty || !history.isEmpty }
    var newestSnapshotDate: Date? { history.map(\.date).max() }
}

enum JamfProtectSnapshotService {
    static func load(profile: String) -> JamfProtectSnapshot {
        let workspace = ProfileService.workspaceURL(for: profile)
        let roots = candidateDataRoots(profile: profile, workspace: workspace).filter {
            var isDirectory = ObjCBool(false)
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        let files = discoverJSONFiles(in: roots)
        let catalog = Catalog(files: files)
        let metrics = buildMetrics(from: catalog)
        let history = buildHistory(from: catalog)
        return JamfProtectSnapshot(
            profile: profile,
            workspaceURL: workspace,
            dataRoots: roots,
            metrics: metrics,
            history: history
        )
    }

    private static func candidateDataRoots(profile: String, workspace: URL?) -> [URL] {
        // Refuse any path construction unless ProfileService.workspaceURL accepted the profile.
        // This is the only path-construction site in this service; without this gate, a caller
        // that bypassed WorkspaceStore could pass `../../etc` and the JSON enumerator would
        // happily walk it.
        guard let workspaceRoot = workspace else { return [] }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return uniqueURLs([
            workspaceRoot.appendingPathComponent("jamf-cli-data", isDirectory: true),
            workspaceRoot.appendingPathComponent("jamf-protect-data", isDirectory: true),
            workspaceRoot.appendingPathComponent("protect", isDirectory: true),
            workspaceRoot,
            cwd.appendingPathComponent("jamf-cli-data", isDirectory: true),
        ])
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func discoverJSONFiles(in roots: [URL]) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        return roots.flatMap { root -> [URL] in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: options
            ) else {
                return []
            }
            return enumerator.compactMap { item in
                guard let url = item as? URL, url.pathExtension.lowercased() == "json" else {
                    return nil
                }
                let values = try? url.resourceValues(forKeys: Set(keys))
                return values?.isRegularFile == true ? url : nil
            }
        }
    }

    private static func buildMetrics(from catalog: Catalog) -> [JamfProtectSnapshot.Metric] {
        var metrics: [JamfProtectSnapshot.Metric] = []
        appendCountMetric("Computers", category: .computers, catalog: catalog, into: &metrics)
        appendCountMetric("Analytics", category: .analytics, catalog: catalog, into: &metrics)
        appendCountMetric("Plans", category: .plans, catalog: catalog, into: &metrics)
        appendCountMetric("Audit Logs", category: .auditLogs, catalog: catalog, into: &metrics)
        appendAlertMetric(catalog: catalog, into: &metrics)
        appendComplianceMetric(catalog: catalog, into: &metrics)
        appendOverviewMetric(catalog: catalog, into: &metrics)
        return metrics
    }

    private static func appendCountMetric(
        _ label: String,
        category: ProtectCategory,
        catalog: Catalog,
        into metrics: inout [JamfProtectSnapshot.Metric]
    ) {
        guard let snapshot = catalog.latest(category) else { return }
        let count = itemCount(snapshot.value)
        metrics.append(.init(
            label: label,
            value: count.map(String.init) ?? "Present",
            detail: formattedDate(snapshot.date),
            source: snapshot.url
        ))
    }

    private static func appendAlertMetric(
        catalog: Catalog,
        into metrics: inout [JamfProtectSnapshot.Metric]
    ) {
        guard let snapshot = catalog.latest(.alerts) else { return }
        let count = itemCount(snapshot.value)
        let statusCounts = groupedCounts(snapshot.value, keyCandidates: ["status", "state", "severity"])
        let detail = statusCounts.isEmpty
            ? formattedDate(snapshot.date)
            : statusCounts.prefix(3).map { "\($0.key): \($0.value)" }.joined(separator: " · ")
        metrics.append(.init(
            label: "Alerts",
            value: count.map(String.init) ?? "Present",
            detail: detail,
            source: snapshot.url
        ))
    }

    private static func appendComplianceMetric(
        catalog: Catalog,
        into metrics: inout [JamfProtectSnapshot.Metric]
    ) {
        guard let snapshot = catalog.latest(.insights) else { return }
        let score = numberValue(
            in: snapshot.value,
            keys: ["compliance_score", "complianceScore", "compliance", "score", "overallScore"]
        )
        metrics.append(.init(
            label: "Insights Score",
            value: score.map { formattedScore($0) } ?? "Present",
            detail: formattedDate(snapshot.date),
            source: snapshot.url
        ))
    }

    private static func appendOverviewMetric(
        catalog: Catalog,
        into metrics: inout [JamfProtectSnapshot.Metric]
    ) {
        guard let snapshot = catalog.latest(.overview) else { return }
        let count = numberValue(
            in: snapshot.value,
            keys: ["total", "totalComputers", "computers", "protectedComputers", "devices"]
        )
        metrics.append(.init(
            label: "Overview",
            value: count.map { formattedNumber(Int($0)) } ?? "Present",
            detail: formattedDate(snapshot.date),
            source: snapshot.url
        ))
    }

    private static func buildHistory(from catalog: Catalog) -> [JamfProtectSnapshot.HistoryEntry] {
        catalog.snapshots
            .sorted { $0.date > $1.date }
            .map { snapshot in
                .init(
                    kind: snapshot.category.displayName,
                    count: itemCount(snapshot.value),
                    summary: historySummary(snapshot),
                    date: snapshot.date,
                    source: snapshot.url
                )
            }
    }

    private static func historySummary(_ snapshot: ProtectSnapshotFile) -> String {
        if let count = itemCount(snapshot.value) {
            return "\(formattedNumber(count)) records"
        }
        if let dict = snapshot.value as? [String: Any] {
            return "\(dict.keys.count) fields"
        }
        return snapshot.url.lastPathComponent
    }

    private static func itemCount(_ value: Any) -> Int? {
        if let array = value as? [Any] { return array.count }
        if let dict = value as? [String: Any] {
            for key in ["results", "data", "items", "computers", "alerts", "logs", "plans"] {
                if let array = dict[key] as? [Any] { return array.count }
            }
            if dict.keys.contains(where: { $0.lowercased().contains("count") }) {
                return nil
            }
        }
        return nil
    }

    private static func groupedCounts(
        _ value: Any,
        keyCandidates: [String]
    ) -> [(key: String, value: Int)] {
        let rows: [Any]
        if let array = value as? [Any] {
            rows = array
        } else if let dict = value as? [String: Any],
                  let firstArray = ["results", "data", "items", "alerts"].compactMap({
                      dict[$0] as? [Any]
                  }).first {
            rows = firstArray
        } else if let dict = value as? [String: Any] {
            return dict.compactMap { key, value in
                guard let count = intValue(value) else { return nil }
                return (key: key, value: count)
            }
            .sorted { $0.value > $1.value }
        } else {
            return []
        }

        var counts: [String: Int] = [:]
        for row in rows {
            guard let dict = row as? [String: Any] else { continue }
            for key in keyCandidates {
                guard let value = stringValue(dict[key]), !value.isEmpty else { continue }
                counts[value, default: 0] += 1
                break
            }
        }
        return counts.sorted { $0.value > $1.value }
    }

    private static func numberValue(in value: Any, keys: [String]) -> Double? {
        if let dict = value as? [String: Any] {
            for key in keys {
                if let direct = doubleValue(dict[key]) { return direct }
            }
            for nested in dict.values {
                if let found = numberValue(in: nested, keys: keys) { return found }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let found = numberValue(in: item, keys: keys) { return found }
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string.replacingOccurrences(of: "%", with: "")) }
        return nil
    }

    private static func formattedNumber(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private static func formattedScore(_ value: Double) -> String {
        if value <= 1 {
            return "\(Int((value * 100).rounded()))%"
        }
        return "\(Int(value.rounded()))%"
    }

    private static func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct ProtectSnapshotFile {
    let category: ProtectCategory
    let url: URL
    let date: Date
    let value: Any
}

private struct Catalog {
    let snapshots: [ProtectSnapshotFile]

    init(files: [URL]) {
        snapshots = files.compactMap { url in
            guard let category = ProtectCategory(url: url),
                  let data = try? Data(contentsOf: url),
                  let value = try? JSONSerialization.jsonObject(with: data)
            else {
                return nil
            }
            return ProtectSnapshotFile(
                category: category,
                url: url,
                date: Self.snapshotDate(for: url),
                value: value
            )
        }
    }

    func latest(_ category: ProtectCategory) -> ProtectSnapshotFile? {
        snapshots
            .filter { $0.category == category }
            .max { $0.date < $1.date }
    }

    private static func snapshotDate(for url: URL) -> Date {
        if let date = dateFromFilename(url.lastPathComponent) {
            return date
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    private static func dateFromFilename(_ name: String) -> Date? {
        let patterns = [
            (#"\d{4}-\d{2}-\d{2}T\d{6}"#, "yyyy-MM-dd'T'HHmmss"),
            (#"\d{4}-\d{2}-\d{2}_\d{6}"#, "yyyy-MM-dd_HHmmss"),
            (#"\d{8}_\d{6}"#, "yyyyMMdd_HHmmss"),
            (#"\d{4}-\d{2}-\d{2}"#, "yyyy-MM-dd"),
            (#"\d{8}"#, "yyyyMMdd"),
        ]
        for (pattern, format) in patterns {
            guard let range = name.range(of: pattern, options: .regularExpression) else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: String(name[range])) {
                return date
            }
        }
        return nil
    }
}

private enum ProtectCategory: CaseIterable, Sendable {
    case overview
    case computers
    case analytics
    case plans
    case alerts
    case insights
    case auditLogs

    init?(url: URL) {
        let path = url.deletingPathExtension().path.lowercased()
        guard path.contains("protect") || path.contains("jamf-cli-data") else { return nil }
        if Self.matches(path, any: ["audit-log", "audit_log", "auditlogs", "audit/log"]) {
            self = .auditLogs
        } else if Self.matches(path, any: ["compliance-score", "compliance_score", "insights"]) {
            self = .insights
        } else if Self.matches(path, any: ["status-count", "status_count", "alerts"]) {
            self = .alerts
        } else if Self.matches(path, any: ["plan"]) {
            self = .plans
        } else if Self.matches(path, any: ["analytic"]) {
            self = .analytics
        } else if Self.matches(path, any: ["computer"]) {
            self = .computers
        } else if Self.matches(path, any: ["overview", "summary"]) {
            self = .overview
        } else {
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .overview: "Overview"
        case .computers: "Computers"
        case .analytics: "Analytics"
        case .plans: "Plans"
        case .alerts: "Alerts"
        case .insights: "Insights"
        case .auditLogs: "Audit Logs"
        }
    }

    private static func matches(_ path: String, any needles: [String]) -> Bool {
        needles.contains { path.contains($0) }
    }
}
