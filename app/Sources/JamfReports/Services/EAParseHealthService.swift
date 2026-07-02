import Foundation

/// Pure data-accuracy diagnostics for custom EA columns and EA coverage drift.
///
/// Two capabilities, both PII-safe and side-effect-free (only `coverageDrift`
/// touches disk):
///   1. `assess` / `assessIntCount` — typed parse health for a column of values,
///      mirroring the report engine's real type-parse semantics (see the
///      `CSVDashboard.writeEA*` handlers) with a stricter accuracy lens where noted.
///   2. `coverageDrift` — per-EA device-coverage delta between the two newest
///      decodable `ea-results` snapshot days.
struct EAParseHealthService {

    // MARK: - Capability 1: typed parse health

    /// Parse-health summary for a single column of values under a configured EA type.
    struct ColumnHealth: Sendable, Equatable {
        let column: String
        /// Values considered. Post identity-dedup is the caller's responsibility.
        let totalRows: Int
        /// Non-blank values (after whitespace trim).
        let nonEmpty: Int
        /// Values that parse under the configured type.
        let parseable: Int
        /// Up to 3 most-common skeletons of unparseable values, most common first.
        /// Skeletons are PII-safe: letters→"x", digits→"9", punctuation kept.
        let topUnparseable: [Skeleton]
        /// `parseable ÷ nonEmpty`; nil when there are no non-empty values.
        var parseRate: Double? {
            nonEmpty == 0 ? nil : Double(parseable) / Double(nonEmpty)
        }

        /// A PII-safe skeleton of an unparseable value plus its occurrence count.
        /// (Tuples aren't `Equatable`/`Sendable`-friendly, so this is a named type.)
        struct Skeleton: Sendable, Equatable {
            let skeleton: String
            let count: Int
        }
    }

    /// Assess parse health for `values` under `type`.
    ///
    /// Type semantics mirror the engine's typed EA handlers (`CSVDashboard.writeEA*`,
    /// CSVDashboard.swift:578-739):
    ///   - `.boolean` / `.text`: no parse-failure mode — `parseable == nonEmpty`.
    ///   - `.percentage`: numeric after trimming whitespace and an optional trailing
    ///     "%", constrained to `0...100`. This is a STRICTER accuracy lens than the
    ///     engine sheet, which renders any value via `NSString.doubleValue` (0 on
    ///     non-numeric) without range-checking.
    ///   - `.version`: `^\d+(\.\d+)*([\w.-]*)$` — dotted-numeric-ish tokens. The engine
    ///     buckets any value as a version, so this is a STRICTER accuracy lens.
    ///   - `.date`: parses under the same formats as the engine's date-EA path
    ///     (`DateParser`, CSVDashboard.swift:983).
    static func assess(
        column: String,
        values: [String],
        type: CustomEAConfig.EAType
    ) -> ColumnHealth {
        var nonEmpty = 0
        var parseable = 0
        var unparseable: [String] = []
        let parser = DateParser()

        for raw in values {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            nonEmpty += 1
            if parses(trimmed, as: type, dateParser: parser) {
                parseable += 1
            } else {
                unparseable.append(trimmed)
            }
        }

        return ColumnHealth(
            column: column,
            totalRows: values.count,
            nonEmpty: nonEmpty,
            parseable: parseable,
            topUnparseable: topSkeletons(unparseable)
        )
    }

    /// Assess a mSCP/STIG failure-count column: parseable = a non-negative Int,
    /// AND ≤ `maxValid` when `maxValid != nil` (the rule-count upper bound — a
    /// per-device failure count above the baseline's rule total is impossible data).
    static func assessIntCount(
        column: String,
        values: [String],
        maxValid: Int?
    ) -> ColumnHealth {
        var nonEmpty = 0
        var parseable = 0
        var unparseable: [String] = []

        for raw in values {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            nonEmpty += 1
            if let n = Int(trimmed), n >= 0, maxValid.map({ n <= $0 }) ?? true {
                parseable += 1
            } else {
                unparseable.append(trimmed)
            }
        }

        return ColumnHealth(
            column: column,
            totalRows: values.count,
            nonEmpty: nonEmpty,
            parseable: parseable,
            topUnparseable: topSkeletons(unparseable)
        )
    }

    // MARK: - Type parsing (mirrors the engine)

    private static func parses(
        _ value: String,
        as type: CustomEAConfig.EAType,
        dateParser: DateParser
    ) -> Bool {
        switch type {
        case .boolean, .text:
            return true  // non-empty is always a valid bucket; no parse failure mode
        case .percentage:
            return parsesPercentage(value)
        case .version:
            return value.range(of: #"^\d+(\.\d+)*([\w.-]*)$"#, options: .regularExpression) != nil
        case .date:
            return dateParser.parse(value) != nil
        }
    }

    /// Numeric after trimming an optional trailing "%", landing in 0...100.
    private static func parsesPercentage(_ value: String) -> Bool {
        var s = value.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("%") { s = String(s.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard let num = Double(s) else { return false }
        return num >= 0 && num <= 100
    }

    // MARK: - PII-safe skeletonization

    /// Skeletonize a raw value: letters→"x", digits→"9", punctuation/whitespace kept,
    /// capped at 40 characters with a "…" suffix when truncated. Never leaks a raw
    /// character from the input.
    static func skeleton(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(min(value.count, 40))
        for (i, ch) in value.enumerated() {
            if ch.isLetter { out.append("x") }
            else if ch.isNumber { out.append("9") }
            else { out.append(ch) }
            if out.count == 40 {
                // "…" only when characters actually remain past the cap.
                return i + 1 < value.count ? out + "…" : out
            }
        }
        return out
    }

    /// Group unparseable values by skeleton, return the top 3 by count (desc),
    /// tie-broken by skeleton for determinism.
    private static func topSkeletons(_ values: [String]) -> [ColumnHealth.Skeleton] {
        guard !values.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for v in values { counts[skeleton(v), default: 0] += 1 }
        return counts
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(3)
            .map { ColumnHealth.Skeleton(skeleton: $0.key, count: $0.value) }
    }

    // MARK: - Capability 2: EA coverage drift

    /// Per-EA device-coverage change between two `ea-results` snapshot days.
    struct CoverageDrift: Sendable, Equatable {
        let eaName: String
        /// Devices with a non-empty value ÷ device universe, in the older snapshot.
        let previousPct: Double
        /// Devices with a non-empty value ÷ device universe, in the newer snapshot.
        let currentPct: Double
        /// `currentPct − previousPct`, in percentage points.
        var deltaPP: Double { currentPct - previousPct }
    }

    /// Coverage drift for every EA present in the two newest decodable snapshot
    /// DAYS under `dataDir/ea-results/`. Returns `[]` when fewer than two distinct
    /// calendar days decode. Sorted by `deltaPP` ascending (biggest drops first).
    static func coverageDrift(dataDir: URL) -> [CoverageDrift] {
        let resultsDir = dataDir.appendingPathComponent("ea-results", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: resultsDir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let snapshots = entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .filter { $0.lastPathComponent.lowercased() != "manifest.json" }
            .sorted {
                MSCPChartDataBuilder.dateFromSnapshotFilename($0, fm: fm)
                    > MSCPChartDataBuilder.dateFromSnapshotFilename($1, fm: fm)
            }

        guard let (current, previous) = twoNewestDistinctDays(snapshots, fm: fm) else {
            return []
        }
        return drift(current: current, previous: previous)
    }

    /// Pick the newest decodable file from each of the two most recent DISTINCT
    /// calendar days. Returns nil if fewer than two distinct days decode.
    private static func twoNewestDistinctDays(
        _ snapshotsNewestFirst: [URL],
        fm: FileManager
    ) -> (current: [EAResultRow], previous: [EAResultRow])? {
        let cal = Calendar(identifier: .gregorian)
        var days: [(day: DateComponents, rows: [EAResultRow])] = []

        for url in snapshotsNewestFirst {
            let date = MSCPChartDataBuilder.dateFromSnapshotFilename(url, fm: fm)
            let day = cal.dateComponents([.year, .month, .day], from: date)
            if days.contains(where: { $0.day == day }) { continue }  // older file, same day
            guard let data = try? Data(contentsOf: url),
                  let rows = EAResultRow.decodeSnapshot(data).rows else { continue }
            days.append((day, rows))
            if days.count == 2 { break }
        }

        guard days.count == 2 else { return nil }
        return (days[0].rows, days[1].rows)  // newest-first, so [0] is current
    }

    /// Coverage drift across all EAs present in either snapshot.
    private static func drift(current: [EAResultRow], previous: [EAResultRow]) -> [CoverageDrift] {
        let cur = coverageByEA(current)
        let prev = coverageByEA(previous)
        let names = Set(cur.keys).union(prev.keys)
        return names
            .map { CoverageDrift(eaName: $0, previousPct: prev[$0] ?? 0, currentPct: cur[$0] ?? 0) }
            .sorted { $0.deltaPP < $1.deltaPP }
    }

    /// Coverage percentage per EA name for one snapshot: distinct devices with a
    /// non-empty value ÷ device universe. Empty dictionary when the universe is empty.
    private static func coverageByEA(_ rows: [EAResultRow]) -> [String: Double] {
        let universe = MSCPComplianceService.allDistinctDeviceIds(in: rows)
        guard !universe.isEmpty else { return [:] }

        var devicesByEA: [String: Set<String>] = [:]
        for row in rows {
            guard let name = row.eaName,
                  let id = primaryIdentifier(for: row),
                  !(row.value?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            else { continue }
            devicesByEA[name, default: []].insert(id.lowercased())
        }

        let denom = Double(universe.count)
        return devicesByEA.mapValues { Double($0.count) / denom * 100.0 }
    }

    /// Primary device identifier for a row. Mirrors `MSCPComplianceService`'s
    /// private `primaryIdentifier` fallback order (`computerId ?? serial ?? device
    /// ?? computerName`) so coverage joins match the compliance universe exactly.
    private static func primaryIdentifier(for row: EAResultRow) -> String? {
        let candidates: [String?] = [row.computerId, row.serial, row.device, row.computerName]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }
}
