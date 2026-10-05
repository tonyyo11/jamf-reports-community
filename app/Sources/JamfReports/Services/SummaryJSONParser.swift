import Foundation

// MARK: - mSCP band snapshot (persisted in summary.json)

/// Per-baseline compliance band counts persisted in `summary.json`.
///
/// Optional in all summary files — old summaries decode cleanly without it.
/// Keys match the `ComplianceBandingService.Band` label lowercased (camelCase)
/// so they are stable even if the display labels change.
struct MSCPBandCounts: Codable, Sendable, Equatable {
    /// Devices with 0 failures.
    let pass: Int
    /// Devices with 1–10 failures.
    let low: Int
    /// Devices with 11–30 failures.
    let medLow: Int
    /// Devices with 31–50 failures.
    let medium: Int
    /// Devices with >50 failures.
    let high: Int
    /// Devices with no row for this baseline EA.
    let noData: Int

    /// Total device count (including No Data).
    var total: Int { pass + low + medLow + medium + high + noData }

    private enum CodingKeys: String, CodingKey {
        case pass, low, medLow, medium, high, noData
    }
}

struct DailySummary: Codable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case date, totalDevices, fileVaultPct, compliancePct, staleCount,
             osCurrentPct, crowdstrikePct, patchPct, source, provenance,
             // v3.5 fleet-health expansion (all optional for backward compat)
             sipPct, firewallPct, gatekeeperPct, secureBootPct, bootstrapPct,
             xprotectPct, cvePct, mscpScorePct, securityScore,
             actionItemsP0, actionItemsP1, actionItemsP2,
             noBaselineActive,
             // True when compliancePct is the control-gap proxy (FileVault/SIP/
             // Firewall/Gatekeeper all passing) rather than a real compliance
             // EA / mSCP failure count. UI labels the metric accordingly.
             complianceIsProxy,
             // Per-baseline band counts for mSCP/STIG compliance trend charts.
             // Key = baseline name; value = band distribution for that date.
             mscpBands,
             // S4: baseline display name -> its failures_count_column (EA name).
             // Stable identity that bridges a baseline rename in multi-baseline orgs.
             mscpBandColumns,
             // R4: which of the digest's input kinds came from this collect
             // (live), an older snapshot (cache), or nowhere (absent).
             collectionSources,
             // Mobile device count for the "Managed Devices" trend/tile.
             mobileDeviceCount,
             // 2.7.0: which machine produced this day's data. Only written on a
             // shared workspace, where "whose collect was this?" is a real
             // diagnostic question — one Mac with a stale CSV or a misconfigured
             // tenant otherwise poisons a pooled history invisibly.
             collectedByHost,
             // How `patchPct` was computed. Absent on a summary written before
             // the device-weighted definition (epic #207 C1).
             patchPctBasis,
             // Which inputs `securityScore` was computed from (epic #207 H1).
             securityScoreBasis,
             // Every configured agent's coverage, by name (`crowdstrikePct` is the agent the
             // score counts as EDR).
             securityAgentCoverage
    }

    var id: String { date }
    let date: String
    let totalDevices: Int
    /// Omitted when source data is absent or fails to decode; nil propagates to
    /// TrendStore so the chart skips the point rather than emitting a misleading 0%.
    let fileVaultPct: Double?
    /// Omitted by Python when the source is `"jamf-cli"` (CSV-only metric).
    /// Decoded as nil so `TrendStore.values(metric:)` skips the point rather
    /// than emitting a misleading 0%.
    let compliancePct: Double?
    /// Omitted when `device-compliance` was never collected — unknown is not
    /// zero. Surfaces render "—" and the stability index drops the stale
    /// component rather than treating an unmeasured fleet as fully fresh.
    let staleCount: Int?
    /// Omitted when source data is absent or fails to decode; nil propagates to
    /// TrendStore so the chart skips the point rather than emitting a misleading 0%.
    let osCurrentPct: Double?
    /// Omitted by Python when the source is `"jamf-cli"` (CSV-only metric).
    private(set) var crowdstrikePct: Double?
    /// Omitted when source data is absent or fails to decode; nil propagates to
    /// TrendStore so the chart skips the point rather than emitting a misleading 0%.
    private(set) var patchPct: Double?
    let source: String
    /// Optional run provenance (run-ID, jamf-cli version, tenant URL, operator).
    /// Absent in legacy Python-emitted summaries; present in Swift-emitted ones.
    let provenance: Provenance?

    // v3.5 fleet-health metric expansion. All optional — absent in pre-expansion
    // summaries and absent from data sources that cannot derive them.
    let sipPct: Double?
    let firewallPct: Double?
    let gatekeeperPct: Double?
    let secureBootPct: Double?
    let bootstrapPct: Double?
    let xprotectPct: Double?
    let cvePct: Double?
    let mscpScorePct: Double?
    /// Weighted composite from `SecurityScoreCalculator` (0–100).
    let securityScore: Double?
    /// P0 = required immediate action (FV/SIP/Firewall failures).
    let actionItemsP0: Int?
    /// P1 = routine remediation (CrowdStrike/XProtect failures).
    let actionItemsP1: Int?
    let actionItemsP2: Int?
    /// Active devices (≤30d check-in) with `No Baseline Set` mSCP version.
    let noBaselineActive: Int?
    /// True when `compliancePct` is the control-gap proxy rather than a real
    /// compliance EA / mSCP source. Absent (nil) in legacy summaries.
    let complianceIsProxy: Bool?
    /// Per-baseline mSCP band counts for trend charts.
    /// Key = baseline name (e.g. "NIST 800-53r5"). Absent in legacy summaries.
    let mscpBands: [String: MSCPBandCounts]?
    /// Baseline display name -> its `failures_count_column` (EA name), parallel
    /// to `mscpBands`. The stable identity used to bridge a baseline rename in
    /// multi-baseline orgs. Absent in legacy summaries.
    let mscpBandColumns: [String: String]?
    /// Per-input-kind provenance of this digest: kind -> "live" | "cache" |
    /// "absent". Absent in legacy summaries and generate-time rewrites.
    var collectionSources: [String: String]?
    /// Device count from the newest `mobile-devices-list` snapshot at collect
    /// time. Omitted when the mobile-devices snapshot is absent or fails to
    /// decode — unknown is not zero, and every summary already records the
    /// computer count (`totalDevices`) retroactively, so this field is the
    /// only piece needed to answer "how many managed Macs/mobile devices did
    /// we have on <past date>" from history.
    let mobileDeviceCount: Int?
    /// Machine that collected this day's data. Present only on a shared
    /// workspace; nil everywhere else, where the answer is trivially "this Mac".
    let collectedByHost: String?
    /// `deviceWeightedPatchBasis` when `patchPct` is `Σ on_latest / Σ total` over the
    /// titles that have devices. Nil on a summary written before 2.9, whose `patchPct`
    /// is the unweighted mean of each title's percentage — the two do not compare.
    private(set) var patchPctBasis: String?
    /// The metrics `securityScore` weighed, by `SecurityScore.Metric` raw value in score
    /// order, comma-separated (`SecurityScoreInputs.basis`). Nil on a summary written before
    /// 2.9, which scored FileVault, SIP and Firewall only; two scores compare only when the
    /// bases are equal.
    let securityScoreBasis: String?
    /// Percent of the fleet each configured `security_agents` entry reports connected, by
    /// agent name: `SecurityAgentCoverage` over `totalDevices`, one decimal, like
    /// `crowdstrikePct` (which is the entry the score counts as EDR, and stays for older
    /// readers). An agent no Mac reports is absent, not 0. Nil on a summary written before 2.9.
    private(set) var securityAgentCoverage: [String: Double]?

    /// Value of `patchPctBasis` for the device-weighted definition.
    static let deviceWeightedPatchBasis = "device"

    /// This day on the device-weighted patch definition, with `patchPct` replaced by the
    /// figure re-derived from its `patch-status` snapshot (`TrendStore.resolvingPatch`).
    func withDeviceWeightedPatch(_ pct: Double) -> DailySummary {
        var resolved = self
        resolved.patchPct = pct
        resolved.patchPctBasis = Self.deviceWeightedPatchBasis
        return resolved
    }

    var parsedDate: Date {
        SummaryJSONParser.dateFormatter.date(from: date) ?? Date.distantPast
    }

    /// This summary with every value it lacks taken from `older`, the same day's earlier
    /// summary: a rebuild from the newest snapshots must not turn a value known this morning
    /// into nil because this run did not fetch its source. Values that belong together move
    /// together (a figure and its basis; the compliance figure, its bands and its proxy flag),
    /// and real mSCP compliance is never replaced by the control-gap proxy. A value this
    /// summary has always wins, and so do `date`, `totalDevices` and `source`;
    /// `collectionSources` is left to the caller (`ReportEngine.mergedSources`).
    /// This day with per-agent coverage taken from its dated `ea-results` snapshot
    /// (`TrendStore.resolvingAgentCoverage`), for a summary written before the app recorded
    /// it. A value the summary already has wins; `edrAgent` fills `crowdstrikePct` when that
    /// is missing too.
    func withBackfilledAgentCoverage(
        _ coverage: [String: Double], edrAgent: String?
    ) -> DailySummary {
        var resolved = self
        resolved.securityAgentCoverage = coverage.merging(
            securityAgentCoverage ?? [:]) { _, own in own }
        if crowdstrikePct == nil, let edrAgent { resolved.crowdstrikePct = coverage[edrAgent] }
        return resolved
    }

    /// Each agent's coverage: this run's where it measured the agent, else the earlier one's.
    private func mergedAgentCoverage(_ older: [String: Double]?) -> [String: Double]? {
        guard let older else { return securityAgentCoverage }
        let merged = older.merging(securityAgentCoverage ?? [:]) { _, new in new }
        return merged.isEmpty ? nil : merged
    }

    func filling(from older: DailySummary) -> DailySummary {
        let olderIsReal = older.complianceIsProxy == false && complianceIsProxy != false
        let olderComplianceWins = older.compliancePct != nil
            && (compliancePct == nil || olderIsReal)
        let patchFromOlder = patchPct == nil
        let scoreFromOlder = securityScore == nil
        return DailySummary(
            date: date,
            totalDevices: totalDevices,
            fileVaultPct: fileVaultPct ?? older.fileVaultPct,
            compliancePct: olderComplianceWins ? older.compliancePct : compliancePct,
            staleCount: staleCount ?? older.staleCount,
            osCurrentPct: osCurrentPct ?? older.osCurrentPct,
            crowdstrikePct: crowdstrikePct ?? older.crowdstrikePct,
            patchPct: patchFromOlder ? older.patchPct : patchPct,
            source: source,
            provenance: provenance ?? older.provenance,
            sipPct: sipPct ?? older.sipPct,
            firewallPct: firewallPct ?? older.firewallPct,
            gatekeeperPct: gatekeeperPct ?? older.gatekeeperPct,
            secureBootPct: secureBootPct ?? older.secureBootPct,
            bootstrapPct: bootstrapPct ?? older.bootstrapPct,
            xprotectPct: xprotectPct ?? older.xprotectPct,
            cvePct: cvePct ?? older.cvePct,
            mscpScorePct: olderComplianceWins
                ? older.mscpScorePct : mscpScorePct ?? older.mscpScorePct,
            securityScore: scoreFromOlder ? older.securityScore : securityScore,
            actionItemsP0: actionItemsP0 ?? older.actionItemsP0,
            actionItemsP1: actionItemsP1 ?? older.actionItemsP1,
            actionItemsP2: actionItemsP2 ?? older.actionItemsP2,
            noBaselineActive: noBaselineActive ?? older.noBaselineActive,
            complianceIsProxy: olderComplianceWins ? older.complianceIsProxy : complianceIsProxy,
            mscpBands: olderComplianceWins ? older.mscpBands : mscpBands ?? older.mscpBands,
            mscpBandColumns: olderComplianceWins
                ? older.mscpBandColumns : mscpBandColumns ?? older.mscpBandColumns,
            collectionSources: collectionSources,
            mobileDeviceCount: mobileDeviceCount ?? older.mobileDeviceCount,
            collectedByHost: collectedByHost ?? older.collectedByHost,
            patchPctBasis: patchFromOlder ? older.patchPctBasis : patchPctBasis,
            securityScoreBasis: scoreFromOlder ? older.securityScoreBasis : securityScoreBasis,
            securityAgentCoverage: mergedAgentCoverage(older.securityAgentCoverage)
        )
    }

    init(
        date: String,
        totalDevices: Int,
        fileVaultPct: Double?,
        compliancePct: Double?,
        staleCount: Int?,
        osCurrentPct: Double?,
        crowdstrikePct: Double?,
        patchPct: Double?,
        source: String = "demo",
        provenance: Provenance? = nil,
        sipPct: Double? = nil,
        firewallPct: Double? = nil,
        gatekeeperPct: Double? = nil,
        secureBootPct: Double? = nil,
        bootstrapPct: Double? = nil,
        xprotectPct: Double? = nil,
        cvePct: Double? = nil,
        mscpScorePct: Double? = nil,
        securityScore: Double? = nil,
        actionItemsP0: Int? = nil,
        actionItemsP1: Int? = nil,
        actionItemsP2: Int? = nil,
        noBaselineActive: Int? = nil,
        complianceIsProxy: Bool? = nil,
        mscpBands: [String: MSCPBandCounts]? = nil,
        mscpBandColumns: [String: String]? = nil,
        collectionSources: [String: String]? = nil,
        mobileDeviceCount: Int? = nil,
        collectedByHost: String? = nil,
        patchPctBasis: String? = nil,
        securityScoreBasis: String? = nil,
        securityAgentCoverage: [String: Double]? = nil
    ) {
        self.date = date
        self.totalDevices = totalDevices
        self.fileVaultPct = fileVaultPct
        self.compliancePct = compliancePct
        self.staleCount = staleCount
        self.osCurrentPct = osCurrentPct
        self.crowdstrikePct = crowdstrikePct
        self.patchPct = patchPct
        self.source = source
        self.provenance = provenance
        self.sipPct = sipPct
        self.firewallPct = firewallPct
        self.gatekeeperPct = gatekeeperPct
        self.secureBootPct = secureBootPct
        self.bootstrapPct = bootstrapPct
        self.xprotectPct = xprotectPct
        self.cvePct = cvePct
        self.mscpScorePct = mscpScorePct
        self.securityScore = securityScore
        self.actionItemsP0 = actionItemsP0
        self.actionItemsP1 = actionItemsP1
        self.actionItemsP2 = actionItemsP2
        self.noBaselineActive = noBaselineActive
        self.complianceIsProxy = complianceIsProxy
        self.mscpBands = mscpBands
        self.mscpBandColumns = mscpBandColumns
        self.collectionSources = collectionSources
        self.mobileDeviceCount = mobileDeviceCount
        self.collectedByHost = collectedByHost
        self.patchPctBasis = patchPctBasis
        self.securityScoreBasis = securityScoreBasis
        self.securityAgentCoverage = securityAgentCoverage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        totalDevices = try container.decode(Int.self, forKey: .totalDevices)
        fileVaultPct = try container.decodeIfPresent(Double.self, forKey: .fileVaultPct)
        compliancePct = try container.decodeIfPresent(Double.self, forKey: .compliancePct)
        staleCount = try container.decodeIfPresent(Int.self, forKey: .staleCount)
        osCurrentPct = try container.decodeIfPresent(Double.self, forKey: .osCurrentPct)
        crowdstrikePct = try container.decodeIfPresent(Double.self, forKey: .crowdstrikePct)
        patchPct = try container.decodeIfPresent(Double.self, forKey: .patchPct)
        source = try container.decode(String.self, forKey: .source)
        provenance = try container.decodeIfPresent(Provenance.self, forKey: .provenance)
        sipPct = try container.decodeIfPresent(Double.self, forKey: .sipPct)
        firewallPct = try container.decodeIfPresent(Double.self, forKey: .firewallPct)
        gatekeeperPct = try container.decodeIfPresent(Double.self, forKey: .gatekeeperPct)
        secureBootPct = try container.decodeIfPresent(Double.self, forKey: .secureBootPct)
        bootstrapPct = try container.decodeIfPresent(Double.self, forKey: .bootstrapPct)
        xprotectPct = try container.decodeIfPresent(Double.self, forKey: .xprotectPct)
        cvePct = try container.decodeIfPresent(Double.self, forKey: .cvePct)
        mscpScorePct = try container.decodeIfPresent(Double.self, forKey: .mscpScorePct)
        securityScore = try container.decodeIfPresent(Double.self, forKey: .securityScore)
        actionItemsP0 = try container.decodeIfPresent(Int.self, forKey: .actionItemsP0)
        actionItemsP1 = try container.decodeIfPresent(Int.self, forKey: .actionItemsP1)
        actionItemsP2 = try container.decodeIfPresent(Int.self, forKey: .actionItemsP2)
        noBaselineActive = try container.decodeIfPresent(Int.self, forKey: .noBaselineActive)
        complianceIsProxy = try container.decodeIfPresent(Bool.self, forKey: .complianceIsProxy)
        mscpBands = try container.decodeIfPresent(
            [String: MSCPBandCounts].self, forKey: .mscpBands)
        mscpBandColumns = try container.decodeIfPresent(
            [String: String].self, forKey: .mscpBandColumns)
        collectionSources = try container.decodeIfPresent(
            [String: String].self, forKey: .collectionSources)
        mobileDeviceCount = try container.decodeIfPresent(Int.self, forKey: .mobileDeviceCount)
        collectedByHost = try container.decodeIfPresent(String.self, forKey: .collectedByHost)
        patchPctBasis = try container.decodeIfPresent(String.self, forKey: .patchPctBasis)
        securityScoreBasis = try container.decodeIfPresent(
            String.self, forKey: .securityScoreBasis)
        securityAgentCoverage = try container.decodeIfPresent(
            [String: Double].self, forKey: .securityAgentCoverage)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(totalDevices, forKey: .totalDevices)
        try container.encodeIfPresent(fileVaultPct, forKey: .fileVaultPct)
        try container.encodeIfPresent(compliancePct, forKey: .compliancePct)
        try container.encodeIfPresent(staleCount, forKey: .staleCount)
        try container.encodeIfPresent(osCurrentPct, forKey: .osCurrentPct)
        try container.encodeIfPresent(crowdstrikePct, forKey: .crowdstrikePct)
        try container.encodeIfPresent(patchPct, forKey: .patchPct)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(provenance, forKey: .provenance)
        try container.encodeIfPresent(sipPct, forKey: .sipPct)
        try container.encodeIfPresent(firewallPct, forKey: .firewallPct)
        try container.encodeIfPresent(gatekeeperPct, forKey: .gatekeeperPct)
        try container.encodeIfPresent(secureBootPct, forKey: .secureBootPct)
        try container.encodeIfPresent(bootstrapPct, forKey: .bootstrapPct)
        try container.encodeIfPresent(xprotectPct, forKey: .xprotectPct)
        try container.encodeIfPresent(cvePct, forKey: .cvePct)
        try container.encodeIfPresent(mscpScorePct, forKey: .mscpScorePct)
        try container.encodeIfPresent(securityScore, forKey: .securityScore)
        try container.encodeIfPresent(actionItemsP0, forKey: .actionItemsP0)
        try container.encodeIfPresent(actionItemsP1, forKey: .actionItemsP1)
        try container.encodeIfPresent(actionItemsP2, forKey: .actionItemsP2)
        try container.encodeIfPresent(noBaselineActive, forKey: .noBaselineActive)
        try container.encodeIfPresent(complianceIsProxy, forKey: .complianceIsProxy)
        try container.encodeIfPresent(mscpBands, forKey: .mscpBands)
        try container.encodeIfPresent(mscpBandColumns, forKey: .mscpBandColumns)
        try container.encodeIfPresent(collectionSources, forKey: .collectionSources)
        try container.encodeIfPresent(mobileDeviceCount, forKey: .mobileDeviceCount)
        try container.encodeIfPresent(collectedByHost, forKey: .collectedByHost)
        try container.encodeIfPresent(patchPctBasis, forKey: .patchPctBasis)
        try container.encodeIfPresent(securityScoreBasis, forKey: .securityScoreBasis)
        try container.encodeIfPresent(securityAgentCoverage, forKey: .securityAgentCoverage)
    }
}

extension DailySummary {
    /// False when any number is non-finite or past `SummaryJSONParser.maxSummaryNumber`.
    var numbersAreInRange: Bool {
        let limit = SummaryJSONParser.maxSummaryNumber
        let percents = [
            fileVaultPct, compliancePct, osCurrentPct, crowdstrikePct, patchPct, sipPct,
            firewallPct, gatekeeperPct, secureBootPct, bootstrapPct, xprotectPct, cvePct,
            mscpScorePct, securityScore,
        ].compactMap { $0 } + Array((securityAgentCoverage ?? [:]).values)
        let bands = (mscpBands ?? [:]).values.flatMap {
            [$0.pass, $0.low, $0.medLow, $0.medium, $0.high, $0.noData]
        }
        let counts = [totalDevices] + bands + [
            staleCount, actionItemsP0, actionItemsP1, actionItemsP2, noBaselineActive,
            mobileDeviceCount,
        ].compactMap { $0 }
        return percents.allSatisfy { $0.isFinite && abs($0) <= Double(limit) }
            && counts.allSatisfy { (-limit...limit).contains($0) }
    }
}

struct SummaryJSONParser {
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .iso8601)
        // Use system timezone to match Calendar.current in TrendStore
        return f
    }()

    /// Real summaries are a few KB; anything near this is corrupt or hostile.
    /// Bounds the whole-file read (T-26 — the workspace sits on synced storage
    /// other software can write to).
    static let maxSummaryFileBytes = 2 * 1024 * 1024

    /// A summary number past this magnitude is corrupt or hostile: percentages sit in 0...100
    /// and counts are devices. Screens round these to an Int for labels (`Int(1e30)` traps) and
    /// add counts across profiles (two of `Int.max` overflow), and never see the file.
    static let maxSummaryNumber = 1_000_000_000

    struct NumberOutOfRange: LocalizedError {
        var errorDescription: String? {
            "a number is outside ±\(SummaryJSONParser.maxSummaryNumber)"
        }
    }

    static func parse(_ url: URL) throws -> DailySummary {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxSummaryFileBytes {
            throw CocoaError(.fileReadTooLarge, userInfo: [NSFilePathErrorKey: url.path])
        }
        return try decode(try Data(contentsOf: url))
    }

    /// The summary in `data`; throws when it does not decode or holds a number past
    /// `maxSummaryNumber`.
    static func decode(_ data: Data) throws -> DailySummary {
        let summary = try JSONDecoder().decode(DailySummary.self, from: data)
        guard summary.numbersAreInRange else { throw NumberOutOfRange() }
        return summary
    }

    static func parseDirectory(_ dir: URL) -> [DailySummary] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }

        let summaries = files
            .filter { CloudStorage.isCanonicalSummaryFilename($0.lastPathComponent) }
            .compactMap { url -> DailySummary? in
                do {
                    return try parse(url)
                } catch {
                    AppLogger.collect.warning(
                        "SummaryJSONParser: skipping corrupt summary \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    return nil
                }
            }
            .sorted { $0.date < $1.date }

        return summaries
    }
}
