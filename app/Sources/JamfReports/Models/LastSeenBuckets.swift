import Foundation

/// How long ago each device was last seen, as counts in four buckets (environment model P9-R3).
/// A device with no known date is in none; a bucket nobody measured is nil, never 0.
struct LastSeenBuckets: Codable, Equatable, Sendable {
    struct Counts: Codable, Equatable, Sendable {
        var underOneDay: Int?
        var underSevenDays: Int?
        var sevenDaysOrMore: Int?
        var never: Int?

        var total: Int {
            [underOneDay, underSevenDays, sevenDaysOrMore, never].compactMap { $0 }
                .reduce(0, +)
        }

        var values: [Int] {
            [underOneDay, underSevenDays, sevenDaysOrMore, never].compactMap { $0 }
        }
    }

    var computers: Counts?
    var mobile: Counts?
}
