import Foundation

/// The Jamf Security Cloud figures a daily summary records (environment model P12), from the
/// reduced `security-risk` snapshot. nil when this run did not land and read that snapshot, so
/// the summary keeps the earlier value.
struct SecurityCloudSummaryFigures: Equatable, Sendable {
    var count: Int
    /// nil when there is nothing to match against; see `SecurityCloudCorrelation.matchedShare`.
    var matched: MobileSummary.Share?
    /// By lower-cased `riskCategory`; nil when no row carries one.
    var riskCounts: [String: Int]?
}

extension DailySummary {
    /// Devices in the HIGH risk category: a real 0 once risk counts are recorded and none is
    /// high, absent when they are not. The one reader for the alert key and the Trends metric.
    var securityCloudHighRiskCount: Int? {
        securityCloudRiskCounts.map { $0["high"] ?? 0 }
    }
}

/// One row of the reduced `security-risk` snapshot: only what the summary reads.
struct SecurityRiskRow: Decodable, Equatable, Sendable {
    var externalId: String?
    var riskCategory: String?

    private enum CodingKeys: String, CodingKey { case externalId, riskCategory }

    init(externalId: String? = nil, riskCategory: String? = nil) {
        self.externalId = externalId
        self.riskCategory = riskCategory
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        externalId = try? c.decodeIfPresent(String.self, forKey: .externalId)
        riskCategory = try? c.decodeIfPresent(String.self, forKey: .riskCategory)
    }

    /// The newest `security-risk` snapshot in `dataDir`; nil when none exists or it cannot be
    /// read or decoded (absent is not an empty list).
    static func load(dataDir: URL) -> [SecurityRiskRow]? {
        guard let url = FileManager.newestJSONFile(
            in: dataDir.appendingPathComponent(ReportEngine.securityRiskKind)),
              let data = BoundedFile.readLogged(url, inside: dataDir) else { return nil }
        return try? JSONDecoder().decode([SecurityRiskRow].self, from: data)
    }

    /// Device counts by lower-cased category; a blank or missing category is not counted, and
    /// nil when no row has one.
    static func riskCounts(_ rows: [SecurityRiskRow]) -> [String: Int]? {
        let counts = Dictionary(
            grouping: rows.compactMap {
                $0.riskCategory?.trimmingCharacters(in: .whitespaces).lowercased()
            }.filter { !$0.isEmpty }, by: { $0 }
        ).mapValues(\.count)
        return counts.isEmpty ? nil : counts
    }
}
