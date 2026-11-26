import Foundation

/// When one credential (a certificate, a token) stops working, and how long is left: the one
/// calculator the ADE token and the server-health credentials share, so they agree.
struct CredentialExpiry: Sendable, Equatable {
    enum State: Sendable, Equatable { case expired, expiring, ok, notReported }

    /// What the server gave: a local calendar day or an instant.
    enum Source: Sendable, Equatable {
        /// `yyyy-MM-dd`, good through that day.
        case day(String)
        case instant(Date)
    }

    let key: String
    let label: String
    let source: Source?
    /// A `yyyy-MM-dd` day, or an ISO 8601 instant, so Macs in other zones store the same text.
    let expiresText: String?
    /// Whole calendar days from today to the expiry day; negative once expired.
    let daysLeft: Int?
    let state: State

    static func state(daysLeft: Int, warningDays: Int) -> State {
        daysLeft < 0 ? .expired : daysLeft <= warningDays ? .expiring : .ok
    }

    init(
        key: String, label: String, raw: Any?, warningDays: Int, now: Date,
        calendar: Calendar = .current
    ) {
        self.key = key
        self.label = label
        let start = calendar.startOfDay(for: now)
        let source = Self.parse(raw, calendar: calendar)
        self.source = source
        switch source {
        case .day(let text):
            expiresText = text
            let left = Self.localDay(text, calendar: calendar).flatMap {
                calendar.dateComponents([.day], from: start, to: $0).day
            }
            daysLeft = left
            state = left.map { Self.state(daysLeft: $0, warningDays: warningDays) } ?? .notReported
        case .instant(let date):
            expiresText = ISO8601Time.string(date)
            let left = calendar.dateComponents(
                [.day], from: start, to: calendar.startOfDay(for: date)).day
            daysLeft = left
            // An instant that has passed is expired now, not "expiring" until midnight.
            state = now >= date ? .expired
                : left.map { Self.state(daysLeft: $0, warningDays: warningDays) } ?? .notReported
        case nil:
            expiresText = nil
            daysLeft = nil
            state = .notReported
        }
    }

    /// The capture rule: an integer above 10^11 is epoch milliseconds, any other integer epoch
    /// seconds; `yyyy-MM-dd` is a day; any other string is ISO 8601 with or without fractional
    /// seconds, read as UTC when it names no zone; anything else is not reported.
    static func parse(_ raw: Any?, calendar: Calendar = .current) -> Source? {
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value == value.rounded(), abs(value) < 1e15 else { return nil }
            let seconds = value > 1e11 ? value / 1000 : value
            return .instant(Date(timeIntervalSince1970: seconds))
        }
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if localDay(text, calendar: calendar) != nil { return .day(text) }
        return (ISO8601Time.parse(text) ?? ISO8601Time.parse(text + "Z")).map { .instant($0) }
    }

    private static func localDay(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              text.allSatisfy({ $0 == "-" || ($0.isASCII && $0.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2])
        else { return nil }
        let wanted = DateComponents(year: year, month: month, day: dayOfMonth)
        guard let date = calendar.date(from: wanted),
              calendar.dateComponents([.year, .month, .day], from: date) == wanted
        else { return nil }
        return date
    }
}
