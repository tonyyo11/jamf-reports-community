import Foundation

/// ISO 8601 reading and writing through `Date.ISO8601FormatStyle`, a Sendable value type, so
/// no shared `ISO8601DateFormatter` is needed.
enum ISO8601Time {
    /// A timestamp with or without a fraction of any length; blanks around it are ignored.
    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Two styles: macOS 15 reads a fraction only from the fractional one, and only
        // without a fraction from the plain one.
        return (try? Date.ISO8601FormatStyle().parse(trimmed))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed))
    }

    /// UTC, seconds precision: `2026-10-29T12:34:56Z`.
    static func string(_ date: Date) -> String { date.formatted(.iso8601) }
}
