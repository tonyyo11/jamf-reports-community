import Foundation

/// The one date reader for the report engine: `DeviceInventoryService.parseDate` first (ISO 8601
/// with or without a fraction, then the export forms), then the zone-less and slash forms that
/// reader lacks. Nil when nothing reads; callers show "Unknown" or a dash, never 0 or -1.
struct DateParser: Sendable {
    // Jamf CSV timestamps carry no zone, so the same export yields different day counts on
    // machines in different zones. Pinned to local to match prior implicit behavior: switching
    // to UTC would shift every existing user's days-since-checkin history, so it needs a
    // deliberate release decision. Built once; `.autoupdatingCurrent` follows zone changes.
    private static let formatters: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd",
        "MM/dd/yyyy HH:mm:ss",
        "MM/dd/yyyy",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        return formatter
    }

    func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let date = DeviceInventoryService.parseDate(s) { return date }
        for formatter in Self.formatters {
            if let d = formatter.date(from: s) { return d }
        }
        return nil
    }
}
