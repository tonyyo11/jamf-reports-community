import Foundation

struct DailySummary: Codable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case date, totalDevices, fileVaultPct, compliancePct, staleCount,
             osCurrentPct, crowdstrikePct, patchPct, source, provenance,
             // v3.5 fleet-health expansion (all optional for backward compat)
             sipPct, firewallPct, gatekeeperPct, secureBootPct, bootstrapPct,
             xprotectPct, cvePct, mscpScorePct, securityScore,
             actionItemsP0, actionItemsP1, actionItemsP2,
             noBaselineActive
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
    let staleCount: Int
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

    var parsedDate: Date {
        SummaryJSONParser.dateFormatter.date(from: date) ?? Date.distantPast
    }

    init(
        date: String,
        totalDevices: Int,
        fileVaultPct: Double?,
        compliancePct: Double?,
        staleCount: Int,
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
        noBaselineActive: Int? = nil
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        totalDevices = try container.decode(Int.self, forKey: .totalDevices)
        fileVaultPct = try container.decodeIfPresent(Double.self, forKey: .fileVaultPct)
        compliancePct = try container.decodeIfPresent(Double.self, forKey: .compliancePct)
        staleCount = try container.decode(Int.self, forKey: .staleCount)
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
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(totalDevices, forKey: .totalDevices)
        try container.encodeIfPresent(fileVaultPct, forKey: .fileVaultPct)
        try container.encodeIfPresent(compliancePct, forKey: .compliancePct)
        try container.encode(staleCount, forKey: .staleCount)
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

    static func parse(_ url: URL) throws -> DailySummary {
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
                try? parse(url)
            }
            .sorted { $0.date < $1.date }
        
        return summaries
    }
}
