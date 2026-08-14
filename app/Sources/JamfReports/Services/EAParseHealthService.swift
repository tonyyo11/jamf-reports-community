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
            // Match the banding lens: intValue tolerates whole doubles ("2.0" → 2).
            if let n = intCount(trimmed), n >= 0, maxValid.map({ n <= $0 }) ?? true {
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

    /// Int an `AnyCodable.intValue`-fed banding accepts for a string count:
    /// an exact Int, else a whole non-negative Double ("2.0" → 2). `Int(exactly:)`
    /// returns nil (not a trap) for a Double outside Int's range or non-finite.
    private static func intCount(_ trimmed: String) -> Int? {
        if let n = Int(trimmed) { return n }
        guard let d = Double(trimmed), d >= 0,
              d.truncatingRemainder(dividingBy: 1) == 0 else { return nil }
        return Int(exactly: d)
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

    /// Outcome of `coverageDriftOutcome` — distinguishes "computed a real
    /// drift" from "couldn't compute one", so a caller never has to treat an
    /// empty `[]` as proof of stability when the truth is "no signal yet".
    enum CoverageDriftOutcome: Sendable, Equatable {
        /// Drift across every EA present in the two comparison days. May
        /// itself be `[]` when nothing changed — that IS a real "stable"
        /// signal, unlike `.insufficientData`.
        case computed([CoverageDrift])
        /// Fewer than two non-salvaged decodable `ea-results` days were
        /// available to compare. `reason` is a user-facing explanation.
        case insufficientData(reason: String)
    }

    /// Coverage drift for every EA present in the two newest decodable snapshot
    /// DAYS under `dataDir/ea-results/`. Returns `.insufficientData` when fewer
    /// than two non-salvaged distinct calendar days decode; otherwise
    /// `.computed` with the drift sorted by `deltaPP` ascending (biggest drops
    /// first — an empty array here means the drift was computed and is stable).
    static func coverageDriftOutcome(dataDir: URL) -> CoverageDriftOutcome {
        let resultsDir = dataDir.appendingPathComponent("ea-results", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: resultsDir,
            includingPropertiesForKeys: nil
        ) else {
            return .insufficientData(reason: "Fewer than two ea-results snapshots")
        }

        let snapshots = entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .filter { $0.lastPathComponent.lowercased() != "manifest.json" }
            .sorted {
                MSCPChartDataBuilder.dateFromSnapshotFilename($0, fm: fm)
                    > MSCPChartDataBuilder.dateFromSnapshotFilename($1, fm: fm)
            }

        switch twoNewestDistinctDays(snapshots, fm: fm) {
        case .found(let current, let previous):
            return .computed(drift(current: current, previous: previous))
        case .insufficientDays(let sawSalvage):
            let reason = sawSalvage
                ? "The most recent snapshot(s) were salvaged from truncated files — "
                    + "coverage change can't be verified"
                : "Fewer than two ea-results snapshots"
            return .insufficientData(reason: reason)
        }
    }

    /// Back-compat/UI-consumption shim over `coverageDriftOutcome` for callers
    /// (e.g. `ExtensionAttributesView`) that only want the drift list and treat
    /// "no signal" and "stable" the same way. `ConfigDoctorService` uses the
    /// richer outcome directly so it can distinguish the two.
    static func coverageDrift(dataDir: URL) -> [CoverageDrift] {
        if case .computed(let drift) = coverageDriftOutcome(dataDir: dataDir) {
            return drift
        }
        return []
    }

    /// Result of scanning for the two newest distinct comparison days.
    private enum TwoDaysResult {
        case found(current: [EAResultRow], previous: [EAResultRow])
        /// Fewer than two non-salvaged distinct days decoded. `sawSalvage` is
        /// true when at least one candidate day was skipped specifically
        /// because it was salvaged (vs. simply absent/undecodable), so the
        /// caller can give a more specific reason.
        case insufficientDays(sawSalvage: Bool)
    }

    /// Pick the newest decodable file from each of the two most recent DISTINCT
    /// calendar days. Returns `.insufficientDays` if fewer than two distinct
    /// days decode.
    ///
    /// A day whose decode reason is a salvage (recovered from a 16KB-truncated
    /// file) is SKIPPED entirely — it doesn't qualify as either side of the
    /// comparison, because a partial-fleet day fabricates drift against its
    /// neighbor rather than reflecting a real coverage change.
    private static func twoNewestDistinctDays(
        _ snapshotsNewestFirst: [URL],
        fm: FileManager
    ) -> TwoDaysResult {
        let cal = Calendar(identifier: .gregorian)
        var days: [(day: DateComponents, rows: [EAResultRow])] = []
        var sawSalvage = false

        for url in snapshotsNewestFirst {
            let date = MSCPChartDataBuilder.dateFromSnapshotFilename(url, fm: fm)
            let day = cal.dateComponents([.year, .month, .day], from: date)
            if days.contains(where: { $0.day == day }) { continue }  // older file, same day
            guard let data = try? Data(contentsOf: url) else { continue }
            let decoded = EAResultRow.decodeSnapshot(data)
            if EAResultRow.isSalvageReason(decoded.reason) {
                sawSalvage = true
                AppLogger.platform.notice(
                    "EAParseHealthService.coverageDrift: skipping salvaged snapshot \(url.lastPathComponent, privacy: .public) — a truncated day fabricates drift"
                )
                continue
            }
            guard let rows = decoded.rows else { continue }
            days.append((day, rows))
            if days.count == 2 { break }
        }

        guard days.count == 2 else { return .insufficientDays(sawSalvage: sawSalvage) }
        return .found(current: days[0].rows, previous: days[1].rows)  // newest-first, so [0] is current
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
                  let id = MSCPComplianceService.primaryIdentifier(for: row),
                  !(row.value?.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            else { continue }
            devicesByEA[name, default: []].insert(id.lowercased())
        }

        let denom = Double(universe.count)
        return devicesByEA.mapValues { Double($0.count) / denom * 100.0 }
    }
}
