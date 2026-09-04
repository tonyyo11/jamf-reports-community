import Foundation

/// A reporting window resolved against the snapshots that actually exist. Each
/// boundary carries the date it resolved to, so no figure claims a date it lacks.
struct ReportPeriod: Sendable, Equatable {

    /// Beyond this many days from the requested boundary, a resolution is
    /// marked. Three days absorbs a weekend or one missed collect without
    /// comment. Presentation only: nothing is excluded and no maths changes.
    static let driftThresholdDays = 3

    enum Kind: Sendable, Equatable {
        case rolling(weeks: Int)
        case lastFullMonth
        /// The last complete calendar quarter. Safe for any organisation: a
        /// fiscal year shifts which number a quarter carries, not where its
        /// boundaries fall, and the report never prints the number.
        case lastFullQuarter
        case explicit(start: Date, end: Date)
    }

    /// One end of the window: what was asked for, and what the data could offer.
    struct Boundary: Sendable, Equatable {
        let requested: Date
        let resolved: Date
        let driftDays: Int
        var isAdrift: Bool { driftDays > ReportPeriod.driftThresholdDays }
    }

    let kind: Kind
    let requestedStart: Date
    let requestedEnd: Date
    let start: Boundary
    let end: Boundary

    /// Returns nil when no snapshot falls inside the requested window — there is
    /// nothing honest to report rather than something approximate.
    static func resolve(
        kind: Kind,
        availableDates: [Date],
        now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> ReportPeriod? {
        let (reqStart, reqEnd) = requestedBounds(kind: kind, now: now, calendar: calendar)
        let inWindow = availableDates
            .filter { $0 >= calendar.startOfDay(for: reqStart) && $0 <= endOfDay(reqEnd, calendar) }
            .sorted()
        guard let first = inWindow.first, let last = inWindow.last else { return nil }
        return ReportPeriod(
            kind: kind,
            requestedStart: reqStart,
            requestedEnd: reqEnd,
            start: boundary(requested: reqStart, resolved: first, calendar: calendar),
            end: boundary(requested: reqEnd, resolved: last, calendar: calendar)
        )
    }

    private static func boundary(requested: Date, resolved: Date, calendar: Calendar) -> Boundary {
        let days = abs(calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: requested),
            to: calendar.startOfDay(for: resolved)).day ?? 0)
        return Boundary(requested: requested, resolved: resolved, driftDays: days)
    }

    private static func endOfDay(_ d: Date, _ c: Calendar) -> Date {
        c.date(byAdding: DateComponents(day: 1, second: -1), to: c.startOfDay(for: d)) ?? d
    }

    private static func requestedBounds(
        kind: Kind, now: Date, calendar: Calendar
    ) -> (Date, Date) {
        switch kind {
        case .explicit(let s, let e):
            return (s, e)
        case .rolling(let weeks):
            return (calendar.date(byAdding: .day, value: -(weeks * 7), to: now) ?? now, now)
        case .lastFullMonth:
            let firstOfThis = calendar.date(
                from: calendar.dateComponents([.year, .month], from: now)) ?? now
            return (calendar.date(byAdding: .month, value: -1, to: firstOfThis) ?? now,
                    calendar.date(byAdding: .day, value: -1, to: firstOfThis) ?? now)
        case .lastFullQuarter:
            let comps = calendar.dateComponents([.year, .month], from: now)
            let quarterStartMonth = (((comps.month ?? 1) - 1) / 3) * 3 + 1
            let firstOfThisQuarter = calendar.date(from: DateComponents(
                year: comps.year, month: quarterStartMonth, day: 1)) ?? now
            return (calendar.date(byAdding: .month, value: -3, to: firstOfThisQuarter) ?? now,
                    calendar.date(byAdding: .day, value: -1, to: firstOfThisQuarter) ?? now)
        }
    }
}
