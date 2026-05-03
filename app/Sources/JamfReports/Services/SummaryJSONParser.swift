import Foundation

struct DailySummary: Codable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case date, totalDevices, fileVaultPct, compliancePct, staleCount, osCurrentPct, crowdstrikePct, patchPct, source
    }

    var id: String { date }
    let date: String
    let totalDevices: Int
    let fileVaultPct: Double
    /// Omitted by Python when the source is `"jamf-cli"` (CSV-only metric).
    /// Decoded as nil so `TrendStore.values(metric:)` skips the point rather
    /// than emitting a misleading 0%.
    let compliancePct: Double?
    let staleCount: Int
    let osCurrentPct: Double
    /// Omitted by Python when the source is `"jamf-cli"` (CSV-only metric).
    let crowdstrikePct: Double?
    let patchPct: Double
    let source: String

    var parsedDate: Date {
        SummaryJSONParser.dateFormatter.date(from: date) ?? Date.distantPast
    }

    init(
        date: String,
        totalDevices: Int,
        fileVaultPct: Double,
        compliancePct: Double?,
        staleCount: Int,
        osCurrentPct: Double,
        crowdstrikePct: Double?,
        patchPct: Double,
        source: String = "demo"
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        totalDevices = try container.decode(Int.self, forKey: .totalDevices)
        fileVaultPct = try container.decode(Double.self, forKey: .fileVaultPct)
        compliancePct = try container.decodeIfPresent(Double.self, forKey: .compliancePct)
        staleCount = try container.decode(Int.self, forKey: .staleCount)
        osCurrentPct = try container.decode(Double.self, forKey: .osCurrentPct)
        crowdstrikePct = try container.decodeIfPresent(Double.self, forKey: .crowdstrikePct)
        patchPct = try container.decode(Double.self, forKey: .patchPct)
        source = try container.decode(String.self, forKey: .source)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(totalDevices, forKey: .totalDevices)
        try container.encode(fileVaultPct, forKey: .fileVaultPct)
        try container.encodeIfPresent(compliancePct, forKey: .compliancePct)
        try container.encode(staleCount, forKey: .staleCount)
        try container.encode(osCurrentPct, forKey: .osCurrentPct)
        try container.encodeIfPresent(crowdstrikePct, forKey: .crowdstrikePct)
        try container.encode(patchPct, forKey: .patchPct)
        try container.encode(source, forKey: .source)
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
