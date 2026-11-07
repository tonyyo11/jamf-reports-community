import Foundation

/// The Jamf Protect figures a daily summary records (environment model P9-R2).
struct ProtectSummaryFigures: Equatable, Sendable {
    var computerCount: Int?
    var matchedPct: Double?
    var openAlerts: Int?
    var alertCounts: [String: Int]?
}
