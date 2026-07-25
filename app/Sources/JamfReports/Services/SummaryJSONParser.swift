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
             mobileDeviceCount
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
    let crowdstrikePct: Double?
    /// Omitted when source data is absent or fails to decode; nil propagates to
    /// TrendStore so the chart skips the point rather than emitting a misleading 0%.
    let patchPct: Double?
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
    let collectionSources: [String: String]?
    /// Device count from the newest `mobile-devices-list` snapshot at collect
    /// time. Omitted when the mobile-devices snapshot is absent or fails to
    /// decode — unknown is not zero, and every summary already records the
    /// computer count (`totalDevices`) retroactively, so this field is the
    /// only piece needed to answer "how many managed Macs/mobile devices did
    /// we have on <past date>" from history.
    let mobileDeviceCount: Int?

    var parsedDate: Date {
        SummaryJSONParser.dateFormatter.date(from: date) ?? Date.distantPast
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
        mobileDeviceCount: Int? = nil
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

    static func parse(_ url: URL) throws -> DailySummary {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxSummaryFileBytes {
            throw CocoaError(.fileReadTooLarge, userInfo: [NSFilePathErrorKey: url.path])
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(DailySummary.self, from: data)
    }

    static func parseDirectory(_ dir: URL) -> [DailySummary] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }

        let summaries = files
            .filter { $0.lastPathComponent.hasPrefix("summary_") && $0.pathExtension == "json" }
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
