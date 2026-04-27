import Foundation

struct DailySummary: Codable, Identifiable, Sendable {
    var id: String { date }
    let date: String         // YYYY-MM-DD
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
}

struct SummaryJSONParser {
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
