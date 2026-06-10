import Foundation

/// Derives real per-device mSCP/STIG compliance bands from `ea-results` snapshots.
///
/// The existing `CompliancePostureService` proxies compliance using four security
/// controls (FileVault / SIP / Firewall / Gatekeeper) from `pro security report`.
/// This service reads actual mSCP failure counts from the per-device EA results
/// written by the mSCP audit scripts, giving true band distributions.
///
/// ## compliancePct definition
///
/// Real compliancePct = `pass ÷ devicesWithData × 100`, where `devicesWithData`
/// is the count of distinct devices that have a parseable integer row for the
/// configured baseline EA. Devices with no row are "No Data" and excluded from
/// the denominator — structurally identical to the proxy's `compliant ÷
/// deviceGapCounts.count × 100`, which also excludes devices that returned no
/// security data. The numerator and denominator contract are the same, so the
/// number is directly comparable when switching from proxy to real data.
///
/// ## Device identity
///
/// `ea-results` rows carry `{device, ea_name, value}` in the verified prod shape.
/// `computerId`, `serial`, and `computerName` are populated in some jamf-cli
/// versions. The identity fallback chain is:
/// `computerId ?? serial ?? device ?? computerName`
/// Any non-empty key is accepted so a per-device join works across both shapes.
struct MSCPComplianceService: Sendable {

    /// Result for a single baseline evaluation.
    struct BaselineResult: Sendable {
        /// The configured baseline name.
        let name: String
        /// The EA column used to source failure counts.
        let failuresCountColumn: String
        /// Per-band device counts in donut-legend order (Pass → No Data).
        let bands: [ComplianceBand]
        /// Devices with no row for this baseline's EA column.
        let noDataCount: Int
        /// Total distinct devices seen across all ea-results rows.
        let totalDevices: Int
        /// Pass ÷ devicesWithData × 100. `nil` when `devicesWithData == 0`
        /// (i.e. no device has a row for this baseline — treat as proxy).
        let compliancePct: Double?

        /// Devices for which a failure count row exists.
        var devicesWithData: Int { totalDevices - noDataCount }
    }

    /// Evaluate all configured baselines from in-memory rows.
    ///
    /// - Parameters:
    ///   - rows: Decoded `[EAResultRow]` from the workspace's `ea-results` snapshot.
    ///   - baselines: Per-baseline config entries. Pass `config.compliance?.resolvedBaselines`.
    /// - Returns: One `BaselineResult` per entry in `baselines`, in the same order.
    ///   Returns `[]` when `baselines` is empty.
    static func evaluate(
        rows: [EAResultRow],
        baselines: [ComplianceBaselineConfig]
    ) -> [BaselineResult] {
        guard !baselines.isEmpty else { return [] }

        // Build per-device universe from all rows so devices seen in ANY
        // baseline's rows appear in the total (consistent denominator).
        let allDeviceIds = allDistinctDeviceIds(in: rows)

        return baselines.map { baseline in
            evaluateBaseline(baseline, rows: rows, universe: allDeviceIds)
        }
    }

    /// Convenience: load the newest `ea-results` snapshot from the workspace
    /// and evaluate all configured baselines.
    ///
    /// Returns `[]` when no snapshot is available (pre-first-collect).
    static func load(
        profile: String,
        baselines: [ComplianceBaselineConfig]
    ) -> [BaselineResult] {
        guard !baselines.isEmpty,
              let dataDir = try? WorkspacePaths.dataDir(for: profile)
        else { return [] }
        let resultsDir = dataDir.appendingPathComponent("ea-results", isDirectory: true)
        guard let url = FileManager.newestJSONFile(in: resultsDir) else { return [] }

        guard let data = try? Data(contentsOf: url) else {
            AppLogger.engine.warning(
                "MSCPComplianceService: could not read ea-results file \(url.lastPathComponent, privacy: .public)"
            )
            return []
        }
        guard let rows = try? JSONDecoder().decode([EAResultRow].self, from: data) else {
            AppLogger.engine.warning(
                "MSCPComplianceService: failed to decode ea-results file \(url.lastPathComponent, privacy: .public)"
            )
            return []
        }
        return evaluate(rows: rows, baselines: baselines)
    }

    // MARK: - Internals

    /// Returns the set of distinct device identifiers across all rows.
    ///
    /// Fallback chain per row: `computerId ?? serial ?? device ?? computerName`.
    /// The first non-empty value wins and is lowercased so joins are
    /// case-insensitive.
    static func allDistinctDeviceIds(in rows: [EAResultRow]) -> Set<String> {
        var ids: Set<String> = []
        for row in rows {
            if let id = primaryIdentifier(for: row) {
                ids.insert(id.lowercased())
            }
        }
        return ids
    }

    private static func evaluateBaseline(
        _ baseline: ComplianceBaselineConfig,
        rows: [EAResultRow],
        universe: Set<String>
    ) -> BaselineResult {
        let col = baseline.failuresCountColumn.trimmingCharacters(in: .whitespaces)

        // Collect failure counts keyed by device id for this baseline's EA.
        var failuresByDevice: [String: Int] = [:]
        for row in rows {
            guard let eaName = row.eaName,
                  eaName.caseInsensitiveCompare(col) == .orderedSame,
                  let id = primaryIdentifier(for: row)
            else { continue }
            // intValue handles Int, Double-encoded-as-int, and String-encoded counts.
            if let count = row.value?.intValue, count >= 0 {
                failuresByDevice[id.lowercased()] = count
            }
            // Unparseable / nil value → treated as No Data (no entry in the dict).
        }

        // Build failure array over the whole universe:
        // devices without a row get nil (No Data).
        let failuresList: [Int?] = universe.map { failuresByDevice[$0] }
        let bands = ComplianceBandingService.bands(failures: failuresList)
        let noDataCount = failuresList.filter { $0 == nil }.count
        let devicesWithData = universe.count - noDataCount
        let passCount = failuresByDevice.values.filter { $0 == 0 }.count

        let compliancePct: Double? = devicesWithData > 0
            ? (Double(passCount) / Double(devicesWithData)) * 100.0
            : nil

        return BaselineResult(
            name: baseline.name,
            failuresCountColumn: col,
            bands: bands,
            noDataCount: noDataCount,
            totalDevices: universe.count,
            compliancePct: compliancePct
        )
    }

    /// Primary device identifier for a row. Mirrors `RiskScoringService.agentStatusLookup`
    /// fallback order so per-device joins work against both the modern shape
    /// (`device` field) and the legacy shape (`computer_id` / `serial`).
    private static func primaryIdentifier(for row: EAResultRow) -> String? {
        let candidates: [String?] = [row.computerId, row.serial, row.device, row.computerName]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }
}
