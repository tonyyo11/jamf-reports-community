import Foundation

/// One credential's expiry as the daily summary stores it: text, so Macs in other time zones
/// write the same value. `expires` is an ISO 8601 instant (the built-in CA) or a `yyyy-MM-dd`
/// day (an ADE token); `asOf` is the snapshot's date.
struct CredentialExpiryEntry: Codable, Equatable, Sendable {
    let expires: String
    let asOf: String
}

/// What the server-health kinds add to a daily summary. Each group is nil when this run did not
/// measure it, so an earlier value stands (`DailySummary.withEnvironment`).
struct ServerHealthSummaryFigures: Equatable, Sendable {
    /// By credential key: `ca`, `ade:<id>`.
    var expiries: [String: CredentialExpiryEntry]?
    /// Notifications the login sees, set only when the kind landed this run.
    var notificationCount: Int?
}

extension DailySummary {
    /// Whole days from this summary's own date to the soonest stored credential expiry (negative
    /// once past); nil when none is stored or readable. Computed from the stored text, never
    /// stored, so it is right for every day of history.
    var serverCredentialSoonestDays: Int? {
        guard parsedDate != .distantPast else { return nil }
        return (serverCredentialExpiries ?? [:]).compactMap { key, entry in
            CredentialExpiry(
                key: key, label: key, raw: entry.expires, warningDays: 0, now: parsedDate
            ).daysLeft
        }.min()
    }
}
