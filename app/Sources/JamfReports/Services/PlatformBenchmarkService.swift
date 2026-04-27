import Foundation

/// Discovers and summarizes cached Jamf Platform compliance benchmark snapshots.
///
/// This service intentionally reads only cached `jamf-cli` JSON files. It does not
/// invoke `jamf-cli`, mutate config, or assume the Platform preview commands are enabled.
enum PlatformBenchmarkService {

    struct BenchmarkCandidate: Identifiable, Hashable, Sendable {
        var id: String { slug }
        let name: String
        let slug: String
        let ruleSnapshotURL: URL?
        let deviceSnapshotURL: URL?
        let modifiedAt: Date
        let ruleCount: Int
        let failingDeviceCount: Int

        var sourceCount: Int {
            (ruleSnapshotURL == nil ? 0 : 1) + (deviceSnapshotURL == nil ? 0 : 1)
        }
    }

    struct BenchmarkSummary: Sendable {
        let candidate: BenchmarkCandidate
        let totalRules: Int
        let rulesWithFailures: Int
        let rulesWithUnknown: Int
        let averagePassRate: Double?
        let devicesReturned: Int
        let devicesWithFailures: Int
        let averageCompliance: Double?
        let topRules: [RuleSummary]
        let topDevices: [DeviceSummary]
    }

    struct RuleSummary: Identifiable, Sendable {
        var id: String { rule }
        let rule: String
        let passed: Int
        let failed: Int
        let unknown: Int
        let devices: Int
        let passRate: Double?
    }

    struct DeviceSummary: Identifiable, Sendable {
        var id: String { deviceID.isEmpty ? device : deviceID }
        let device: String
        let deviceID: String
        let rulesFailed: Int
        let rulesPassed: Int
        let compliance: Double?
    }

    static func discover(profile: String) -> [BenchmarkCandidate] {
        guard let dataDirectory = jamfCLIDataDirectory(for: profile) else { return [] }
        return discover(in: dataDirectory)
    }

    static func discover(in dataDirectory: URL) -> [BenchmarkCandidate] {
        var groups: [String: CandidateAccumulator] = [:]

        for file in jsonFiles(in: dataDirectory) {
            let stem = file.deletingPathExtension().lastPathComponent
            let kind = snapshotKind(from: stem)
            guard kind != .other else { continue }

            let rows = loadRows(from: file)
            let inferredName = benchmarkName(from: rows)
                ?? benchmarkName(fromFileStem: stem)
                ?? "Unspecified Benchmark"
            let slug = benchmarkSlug(for: inferredName, fileStem: stem)
            var accumulator = groups[slug] ?? CandidateAccumulator(
                name: inferredName,
                slug: slug,
                modifiedAt: modificationDate(for: file),
                rules: [],
                devices: [],
                ruleSnapshotURL: nil,
                deviceSnapshotURL: nil
            )

            accumulator.modifiedAt = max(accumulator.modifiedAt, modificationDate(for: file))
            if accumulator.name == "Unspecified Benchmark", inferredName != accumulator.name {
                accumulator.name = inferredName
            }

            switch kind {
            case .rules:
                if isNewer(file, than: accumulator.ruleSnapshotURL) {
                    accumulator.rules = rows
                    accumulator.ruleSnapshotURL = file
                }
            case .devices:
                if isNewer(file, than: accumulator.deviceSnapshotURL) {
                    accumulator.devices = rows
                    accumulator.deviceSnapshotURL = file
                }
            case .other:
                break
            }

            groups[slug] = accumulator
        }

        return groups.values
            .map { item in
                BenchmarkCandidate(
                    name: item.name,
                    slug: item.slug,
                    ruleSnapshotURL: item.ruleSnapshotURL,
                    deviceSnapshotURL: item.deviceSnapshotURL,
                    modifiedAt: item.modifiedAt,
                    ruleCount: item.rules.count,
                    failingDeviceCount: item.devices.count
                )
            }
            .sorted {
                if $0.modifiedAt == $1.modifiedAt { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                return $0.modifiedAt > $1.modifiedAt
            }
    }

    static func summary(profile: String, benchmarkName: String) -> BenchmarkSummary? {
        guard let dataDirectory = jamfCLIDataDirectory(for: profile) else { return nil }
        let candidates = discover(in: dataDirectory)
        let selectedSlug = legacySlug(benchmarkName)
        guard let candidate = candidates.first(where: {
            $0.name.caseInsensitiveCompare(benchmarkName) == .orderedSame
                || $0.slug == selectedSlug
                || $0.slug.hasPrefix(selectedSlug)
        }) else {
            return nil
        }
        return summary(for: candidate)
    }

    static func summary(for candidate: BenchmarkCandidate) -> BenchmarkSummary? {
        let rules = candidate.ruleSnapshotURL.map(loadRows(from:)) ?? []
        let devices = candidate.deviceSnapshotURL.map(loadRows(from:)) ?? []
        guard !rules.isEmpty || !devices.isEmpty else { return nil }

        let ruleSummaries = rules.map(ruleSummary(from:))
        let deviceSummaries = devices.map(deviceSummary(from:))
        let passRates = ruleSummaries.compactMap(\.passRate)
        let complianceValues = deviceSummaries.compactMap(\.compliance)

        return BenchmarkSummary(
            candidate: candidate,
            totalRules: ruleSummaries.count,
            rulesWithFailures: ruleSummaries.filter { $0.failed > 0 }.count,
            rulesWithUnknown: ruleSummaries.filter { $0.unknown > 0 }.count,
            averagePassRate: average(passRates),
            devicesReturned: deviceSummaries.count,
            devicesWithFailures: deviceSummaries.filter { $0.rulesFailed > 0 }.count,
            averageCompliance: average(complianceValues),
            topRules: ruleSummaries
                .sorted { ($0.failed, $0.unknown, $0.rule) > ($1.failed, $1.unknown, $1.rule) }
                .prefix(10)
                .map { $0 },
            topDevices: deviceSummaries
                .sorted { ($0.rulesFailed, $0.device) > ($1.rulesFailed, $1.device) }
                .prefix(10)
                .map { $0 }
        )
    }

    private enum SnapshotKind {
        case rules
        case devices
        case other
    }

    private struct CandidateAccumulator {
        var name: String
        var slug: String
        var modifiedAt: Date
        var rules: [[String: Any]]
        var devices: [[String: Any]]
        var ruleSnapshotURL: URL?
        var deviceSnapshotURL: URL?
    }

    private static func jamfCLIDataDirectory(for profile: String) -> URL? {
        WorkspacePaths.dataDir(for: profile)
    }

    private static func jsonFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let safeRoot = directory.resolvingSymlinksInPath().path + "/"
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension.lowercased() == "json" else { return nil }
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(safeRoot) else { return nil }
            let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true ? resolved : nil
        }
    }

    private static func snapshotKind(from stem: String) -> SnapshotKind {
        let lowered = stem.lowercased()
        if lowered.contains("compliance-rules") || lowered.contains("compliance_rules") {
            return .rules
        }
        if lowered.contains("compliance-devices") || lowered.contains("compliance_devices") {
            return .devices
        }
        return .other
    }

    private static func loadRows(from url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        return rows(from: root)
    }

    private static func rows(from value: Any) -> [[String: Any]] {
        if let rows = value as? [[String: Any]] { return rows }
        guard let object = value as? [String: Any] else { return [] }
        for key in ["data", "results", "items", "rows", "rules", "devices"] {
            if let nested = object[key] {
                let nestedRows = rows(from: nested)
                if !nestedRows.isEmpty { return nestedRows }
            }
        }
        return object.values.compactMap { $0 as? [[String: Any]] }.first ?? []
    }

    private static func benchmarkName(from rows: [[String: Any]]) -> String? {
        for row in rows {
            for key in ["benchmark", "benchmarkTitle", "benchmarkName", "baseline", "baselineTitle"] {
                if let value = stringValue(row[key]), !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static func benchmarkName(fromFileStem stem: String) -> String? {
        var tail = stem
            .replacingOccurrences(of: "compliance-rules", with: "")
            .replacingOccurrences(of: "compliance_rules", with: "")
            .replacingOccurrences(of: "compliance-devices", with: "")
            .replacingOccurrences(of: "compliance_devices", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))

        if let underscore = tail.range(of: #"_20\d{2}"#, options: .regularExpression) {
            tail = String(tail[..<underscore.lowerBound])
        }
        if let hash = tail.range(of: #"-[0-9a-f]{8}$"#, options: .regularExpression) {
            tail = String(tail[..<hash.lowerBound])
        }
        guard !tail.isEmpty else { return nil }
        return tail
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private static func benchmarkSlug(for name: String, fileStem: String) -> String {
        let fileName = benchmarkName(fromFileStem: fileStem) ?? ""
        let fileSlug = legacySlug(fileName)
        return fileSlug.isEmpty ? legacySlug(name) : fileSlug
    }

    private static func ruleSummary(from row: [String: Any]) -> RuleSummary {
        RuleSummary(
            rule: stringValue(row["rule"]) ?? stringValue(row["name"]) ?? stringValue(row["title"]) ?? "Unnamed Rule",
            passed: intValue(row["passed"]),
            failed: intValue(row["failed"]),
            unknown: intValue(row["unknown"]),
            devices: intValue(row["devices"]),
            passRate: percentValue(row["passRate"] ?? row["pass_rate"])
        )
    }

    private static func deviceSummary(from row: [String: Any]) -> DeviceSummary {
        DeviceSummary(
            device: stringValue(row["device"]) ?? stringValue(row["name"]) ?? "Unnamed Device",
            deviceID: stringValue(row["deviceId"]) ?? stringValue(row["device_id"]) ?? "",
            rulesFailed: intValue(row["rulesFailed"] ?? row["rules_failed"]),
            rulesPassed: intValue(row["rulesPassed"] ?? row["rules_passed"]),
            compliance: percentValue(row["compliance"])
        )
    }

    private static func legacySlug(_ value: String) -> String {
        let lowered = value.lowercased()
        var output = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            let isAllowed = CharacterSet.alphanumerics.contains(scalar)
            if isAllowed {
                output.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                output.append("-")
                lastWasDash = true
            }
            if output.count >= 48 { break }
        }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        default:
            return 0
        }
    }

    private static func percentValue(_ value: Any?) -> Double? {
        switch value {
        case let double as Double:
            return double > 1 ? double / 100 : double
        case let number as NSNumber:
            let double = number.doubleValue
            return double > 1 ? double / 100 : double
        case let string as String:
            let cleaned = string.replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let double = Double(cleaned) else { return nil }
            return double > 1 ? double / 100 : double
        default:
            return nil
        }
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private static func isNewer(_ url: URL, than existing: URL?) -> Bool {
        guard let existing else { return true }
        return modificationDate(for: url) >= modificationDate(for: existing)
    }
}
