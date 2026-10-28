import Foundation

extension Date {
    /// 2026-06-15 12:00 local: mid-day and mid-month, so a test that stamps a local day never
    /// depends on when it runs. Hand it to the code under test through its `now`/`day` seam.
    static let testNoon: Date = {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 6
        parts.day = 15
        parts.hour = 12
        return Calendar.current.date(from: parts) ?? Date(timeIntervalSince1970: 1_781_539_200)
    }()
}
