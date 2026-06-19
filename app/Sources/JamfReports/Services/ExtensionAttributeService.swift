import Foundation

/// Reads Extension Attribute results and definitions from the workspace's
/// jamf-cli data directory and prepares them for the `ExtensionAttributesView`.
/// Surfaces EA coverage gaps and value distributions to help admins understand
/// which EAs are actually populating data across the fleet.
///
/// Aggregates are pre-computed at decode time: the raw `[EAResultRow]` array
/// (which can reach tens of thousands of rows on large fleets — 600 devices ×
/// 90 EAs = 54k rows) is consumed in a single streaming pass and dropped
/// before the `Snapshot` is returned. The view holds only bounded aggregates:
/// one `Coverage` per EA, and a `ValueDistribution` whose `top` is capped at
/// `topValueLimit` plus an `otherCount` tail bucket.
struct ExtensionAttributeService: Sendable {

    /// Maximum number of distinct values kept per EA in the value
    /// distribution. Excess values are aggregated into `otherCount`.
    static let topValueLimit = 20

    /// Everything the ExtensionAttributesView needs from EA results and definitions.
    struct Snapshot: Sendable, Equatable {
        let definitions: [ExtensionAttribute]
        let coverage: [Coverage]
        let totalDevices: Int
        let totalEAs: Int
        /// Total number of raw EA result rows that were decoded. Useful for
        /// the view to show "Top values shown per EA; full data in reports."
        let totalRowCount: Int
        let valueDistributions: [ValueDistribution]
        let sourceFile: URL?
        let snapshotDate: Date?

        var cacheSource: CacheSource {
            CacheSource.from(snapshotDate: snapshotDate, withinHours: 36)
        }

        struct Coverage: Sendable, Equatable, Identifiable {
            let eaName: String
            let definitionId: String?
            let populatedDevices: Int
            let totalDevices: Int
            var id: String { eaName }
            var coveragePct: Double {
                totalDevices > 0 ? Double(populatedDevices) / Double(totalDevices) * 100 : 0
            }
        }

        /// Bounded per-EA value frequency table. `top` holds the most common
        /// `topValueLimit` values sorted by descending count; `otherCount` is
        /// the total occurrences of all remaining distinct values.
        struct ValueDistribution: Sendable, Equatable, Identifiable {
            let eaName: String
            let top: [ValueCount]
            let otherCount: Int
            let distinctValueCount: Int
            var id: String { eaName }

            struct ValueCount: Sendable, Equatable {
                let value: String
                let count: Int
            }
        }

        static let empty = Snapshot(
            definitions: [],
            coverage: [],
            totalDevices: 0,
            totalEAs: 0,
            totalRowCount: 0,
            valueDistributions: [],
            sourceFile: nil,
            snapshotDate: nil
        )

        // ExtensionAttribute does not conform to Equatable, so we compare
        // definitions by their identifier list (sufficient for the view's
        // diff needs — definition mutation between snapshots is rare and
        // a count/id change is enough to redraw).
        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.definitions.map(\.id) == rhs.definitions.map(\.id) &&
            lhs.coverage == rhs.coverage &&
            lhs.totalDevices == rhs.totalDevices &&
            lhs.totalEAs == rhs.totalEAs &&
            lhs.totalRowCount == rhs.totalRowCount &&
            lhs.valueDistributions == rhs.valueDistributions &&
            lhs.sourceFile == rhs.sourceFile &&
            lhs.snapshotDate == rhs.snapshotDate
        }
    }

    /// Returns the newest snapshot for `profile`. Returns `.empty` when no
    /// data is available — that's a normal state pre-first-collect.
    static func load(profile: String) -> Snapshot {
        guard let dir = (try? WorkspacePaths.dataDir(for: profile)) else {
            return .empty
        }
        let resultsDir = dir.appendingPathComponent("ea-results", isDirectory: true)
        let definitionsDir = dir.appendingPathComponent("computer-extension-attributes", isDirectory: true)

        let resultsURL = FileManager.newestJSONFile(in: resultsDir)
        let definitionsURL = FileManager.newestJSONFile(in: definitionsDir)

        return load(resultsURL: resultsURL, definitionsURL: definitionsURL) ?? .empty
    }

    /// Test seam: load directly from arbitrary file URLs.
    ///
    /// Returns `nil` when neither URL produced a usable input. Returns an
    /// explicit empty `Snapshot` (renderable as the "no data" state) when at
    /// least one file was read successfully but contained empty arrays — this
    /// distinguishes "no input given" from "input given but empty".
    ///
    /// Decode failures are logged via `AppLogger.collect.warning` so a
    /// truncated/malformed snapshot from a previous collect run shows up in
    /// `Console.app` instead of silently rendering the same empty state as
    /// pre-first-collect.
    static func load(resultsURL: URL?, definitionsURL: URL?) -> Snapshot? {
        var definitions: [ExtensionAttribute] = []
        var results: [EAResultRow] = []
        var sourceFile: URL?
        var snapshotDate: Date?
        var readSomething = false

        if let definitionsURL,
           FileManager.default.fileExists(atPath: definitionsURL.path) {
            if let data = try? Data(contentsOf: definitionsURL) {
                do {
                    definitions = try JSONDecoder().decode([ExtensionAttribute].self, from: data)
                    sourceFile = definitionsURL
                    snapshotDate = (try? definitionsURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                    readSomething = true
                } catch {
                    AppLogger.collect.warning(
                        "ExtensionAttributeService: failed to decode definitions at \(definitionsURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
        }

        if let resultsURL,
           FileManager.default.fileExists(atPath: resultsURL.path) {
            if let data = try? Data(contentsOf: resultsURL) {
                do {
                    results = try JSONDecoder().decode([EAResultRow].self, from: data)
                    if sourceFile == nil {
                        sourceFile = resultsURL
                        snapshotDate = (try? resultsURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate
                    }
                    readSomething = true
                } catch {
                    AppLogger.collect.warning(
                        "ExtensionAttributeService: failed to decode results at \(resultsURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
        }

        guard readSomething else { return nil }

        if definitions.isEmpty && results.isEmpty {
            return Snapshot(
                definitions: [],
                coverage: [],
                totalDevices: 0,
                totalEAs: 0,
                totalRowCount: 0,
                valueDistributions: [],
                sourceFile: sourceFile,
                snapshotDate: snapshotDate
            )
        }

        return buildSnapshot(
            results: results,
            definitions: definitions,
            sourceFile: sourceFile,
            snapshotDate: snapshotDate
        )
    }

    // MARK: - Internals

    /// Per-EA accumulator. Sized once per distinct EA name (≤90 typical),
    /// independent of fleet size.
    private struct Accumulator {
        var populatedDeviceIds: Set<String> = []
        var valueCounts: [String: Int] = [:]
    }

    /// Single streaming pass over the raw rows. We accumulate per-EA stats
    /// into small `Accumulator`s and a global `Set` of seen device ids, then
    /// release the raw rows by virtue of leaving scope. Peak memory is bounded
    /// by `O(devices + distinctValues)` rather than `O(rows)`.
    private static func buildSnapshot(
        results: [EAResultRow],
        definitions: [ExtensionAttribute],
        sourceFile: URL?,
        snapshotDate: Date?
    ) -> Snapshot {
        var accumulators: [String: Accumulator] = [:]
        var allDeviceIds: Set<String> = []

        for row in results {
            if let cid = row.computerId { allDeviceIds.insert(cid) }
            let eaName = row.eaName ?? "Unknown"
            let normalized = normalizedPopulatedValue(row.value)

            var acc = accumulators[eaName] ?? Accumulator()
            if let normalized {
                if let cid = row.computerId { acc.populatedDeviceIds.insert(cid) }
                acc.valueCounts[normalized, default: 0] += 1
            }
            accumulators[eaName] = acc
        }

        let totalDevices = allDeviceIds.count
        let totalEAs = results.isEmpty ? definitions.count : accumulators.count
        let definitionIdByName = Dictionary(
            uniqueKeysWithValues: definitions.compactMap { def in
                def.name.map { ($0, def.id) }
            }
        )

        var coverage: [Snapshot.Coverage] = []
        coverage.reserveCapacity(accumulators.count)
        var distributions: [Snapshot.ValueDistribution] = []
        distributions.reserveCapacity(accumulators.count)

        for (eaName, acc) in accumulators {
            coverage.append(Snapshot.Coverage(
                eaName: eaName,
                definitionId: definitionIdByName[eaName] ?? nil,
                populatedDevices: acc.populatedDeviceIds.count,
                totalDevices: totalDevices
            ))
            if let dist = makeDistribution(eaName: eaName, counts: acc.valueCounts) {
                distributions.append(dist)
            }
        }

        coverage.sort { $0.populatedDevices < $1.populatedDevices }
        distributions.sort { $0.eaName < $1.eaName }

        return Snapshot(
            definitions: definitions,
            coverage: coverage,
            totalDevices: totalDevices,
            totalEAs: totalEAs,
            totalRowCount: results.count,
            valueDistributions: distributions,
            sourceFile: sourceFile,
            snapshotDate: snapshotDate
        )
    }

    /// Sorts the per-value counts descending and splits at `topValueLimit`,
    /// rolling the remainder into `otherCount`. Returns `nil` when there are
    /// no populated values — the view has nothing to render in that case.
    private static func makeDistribution(
        eaName: String,
        counts: [String: Int]
    ) -> Snapshot.ValueDistribution? {
        guard !counts.isEmpty else { return nil }
        let sorted = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        let topSlice = sorted.prefix(topValueLimit)
        let top = topSlice.map { Snapshot.ValueDistribution.ValueCount(value: $0.key, count: $0.value) }
        let otherCount = sorted.dropFirst(topValueLimit).reduce(0) { $0 + $1.value }
        return Snapshot.ValueDistribution(
            eaName: eaName,
            top: top,
            otherCount: otherCount,
            distinctValueCount: sorted.count
        )
    }

    /// Returns the normalized form of a populated value, or `nil` if the
    /// value is empty / null / "nil". Normalization is lowercased + trimmed
    /// so case-variant values group together in the distribution.
    private static func normalizedPopulatedValue(_ value: AnyCodable?) -> String? {
        guard let value else { return nil }
        let raw = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        guard lower != "null" && lower != "nil" else { return nil }
        return lower
    }
}
