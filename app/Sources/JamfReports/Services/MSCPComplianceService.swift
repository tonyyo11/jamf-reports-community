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
        guard let url = FileManager.newestSnapshotFile(in: resultsDir) else { return [] }

        guard let data = try? Data(contentsOf: url) else {
            AppLogger.platform.warning(
                "MSCPComplianceService: could not read ea-results file \(url.lastPathComponent, privacy: .public)"
            )
            return []
        }
        let decoded = EAResultRow.decodeSnapshot(data)
        guard let rows = decoded.rows else {
            AppLogger.platform.notice(
                "MSCPComplianceService: ea-results \(url.lastPathComponent, privacy: .public) undecodable — \(decoded.reason, privacy: .public)"
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
            // A count above the baseline's rule count is a garbage EA value
            // (broken audit script) → reject as unparseable (No Data), so it
            // never silently bands the device High.
            if let count = row.value?.intValue,
               isValidCount(count, ruleCount: baseline.ruleCount) {
                failuresByDevice[id.lowercased()] = count
            }
            // Unparseable / nil / out-of-bounds value → No Data (no entry in the dict).
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
    /// Internal: `ExtensionAttributeService` reuses it for its device universe.
    static func primaryIdentifier(for row: EAResultRow) -> String? {
        let candidates: [String?] = [row.computerId, row.serial, row.device, row.computerName]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    /// A non-negative count is valid unless a positive `ruleCount` bound is set
    /// and the count exceeds it (garbage EA value → treated as No Data).
    private static func isValidCount(_ count: Int, ruleCount: Int?) -> Bool {
        guard count >= 0 else { return false }
        if let bound = ruleCount, bound > 0, count > bound { return false }
        return true
    }
}

// MARK: - Denominators

extension MSCPComplianceService.BaselineResult {
    /// Devices with zero failures — the numerator of `compliancePct`.
    var passCount: Int {
        bands.first { $0.label == ComplianceBandingService.Band.pass.label }?.count ?? 0
    }

    /// What `compliancePct` divides: "465 of 632 evaluated". The donut's shares divide by
    /// `totalDevices` instead (`shareBasisText`), so the two never read as one denominator.
    var complianceRateBasisText: String {
        "\(passCount) of \(devicesWithData) evaluated"
    }

    /// The evaluated devices against all devices in the snapshot: "of 664 devices, 32 No Data".
    var evaluatedBasisText: String {
        "of \(totalDevices) device\(totalDevices == 1 ? "" : "s"), \(noDataCount) No Data"
    }

    /// What the donut legend's percentages divide: every device in the snapshot, No Data included.
    var shareBasisText: String {
        "Share of all \(totalDevices) device\(totalDevices == 1 ? "" : "s"), No Data included"
    }
}

extension MSCPComplianceService {
    /// The screen subtitle for the configured baselines. Every baseline sees the same devices,
    /// but each evaluates only those that report its own column, so the evaluated count is the
    /// first baseline's alone only when they all agree; otherwise the range is given.
    static func evaluatedSummary(_ results: [BaselineResult]) -> String {
        let counts = results.map(\.devicesWithData)
        guard let low = counts.min(), let high = counts.max(), high > 0,
              let total = results.first?.totalDevices else {
            return "No device data matched the configured baseline EA column."
        }
        let baselines = "\(results.count) mSCP baseline\(results.count == 1 ? "" : "s")"
        let devices = "\(total) device\(total == 1 ? "" : "s")"
        if low == high { return "\(low) of \(devices) evaluated across \(baselines)." }
        return "\(devices) across \(baselines); each evaluates the devices that report its "
            + "column (\(low) to \(high))."
    }
}

// MARK: - Count-vs-list cross-check

extension MSCPComplianceService {

    /// Per-baseline agreement between the failure count EA and the failure list EA.
    ///
    /// A device disagrees when its parsed integer count differs from the number
    /// of rule IDs in its list cell (`FailedRuleList`). Devices lacking a parseable
    /// count or a list (a status such as "No Baseline Set" is not one) are skipped,
    /// not counted as disagreements.
    struct CrossCheckResult: Sendable, Equatable {
        /// The configured baseline name.
        let baselineName: String
        /// Devices with BOTH a parseable count and a list row.
        let devicesCompared: Int
        /// Count of compared devices where count != number of list entries.
        let disagreements: Int
        /// `disagreements ÷ devicesCompared`. `nil` when `devicesCompared == 0`.
        var disagreementRate: Double? {
            devicesCompared > 0 ? Double(disagreements) / Double(devicesCompared) : nil
        }
    }

    /// Cross-check the failure count against the failure list for every baseline
    /// that configures a non-empty `failuresListColumn`. Baselines without a list
    /// column are omitted from the result.
    static func crossCheck(
        rows: [EAResultRow],
        baselines: [ComplianceBaselineConfig]
    ) -> [CrossCheckResult] {
        baselines.compactMap { baseline in
            let listCol = (baseline.failuresListColumn ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !listCol.isEmpty else { return nil }
            return crossCheckBaseline(baseline, listColumn: listCol, rows: rows)
        }
    }

    private static func crossCheckBaseline(
        _ baseline: ComplianceBaselineConfig,
        listColumn: String,
        rows: [EAResultRow]
    ) -> CrossCheckResult {
        let countCol = baseline.failuresCountColumn.trimmingCharacters(in: .whitespaces)

        var countByDevice: [String: Int] = [:]
        var listLenByDevice: [String: Int] = [:]
        for row in rows {
            guard let eaName = row.eaName, let id = primaryIdentifier(for: row) else { continue }
            let key = id.lowercased()
            if eaName.caseInsensitiveCompare(countCol) == .orderedSame {
                if let count = row.value?.intValue,
                   isValidCount(count, ruleCount: baseline.ruleCount) {
                    countByDevice[key] = count
                }
            } else if eaName.caseInsensitiveCompare(listColumn) == .orderedSame {
                // A status in place of a list ("No Baseline Set") has no length to compare.
                if let rules = FailedRuleList.rules(in: row.value?.stringValue) {
                    listLenByDevice[key] = rules.count
                }
            }
        }

        var compared = 0
        var disagreements = 0
        for (device, count) in countByDevice {
            guard let listLen = listLenByDevice[device] else { continue }
            compared += 1
            if count != listLen { disagreements += 1 }
        }

        return CrossCheckResult(
            baselineName: baseline.name,
            devicesCompared: compared,
            disagreements: disagreements
        )
    }
}
