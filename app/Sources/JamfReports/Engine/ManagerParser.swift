import Foundation

// MARK: - ManagerParser

/// Parses Active Directory Distinguished Names (DNs) into readable manager names.
///
/// Mirrors the Python `_parse_manager` function (line 542).
/// Used in the Stale Devices sheet to render the Manager column.
enum ManagerParser {

    // CN capture: one or more chars that are not comma or backslash,
    // OR a backslash-comma escape sequence.
    private static let dnRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^CN=((?:[^,\\]|\\,)+)"#,
            options: [.caseInsensitive]
        )
    }()

    private static let nanValues: Set<String> = ["nan", "NaN", "NAN"]

    /// Parse a raw manager field value, returning a readable name.
    ///
    /// - Parameter rawValue: The raw string from the CSV manager column.
    /// - Returns: A human-readable name, or `""` for nil/empty/NaN inputs.
    static func parse(_ rawValue: String?) -> String {
        guard let raw = rawValue else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !nanValues.contains(trimmed) else { return "" }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = dnRegex.firstMatch(in: trimmed, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: trimmed) else {
            // No CN= prefix — pass through as-is.
            return trimmed
        }

        let cnRaw = String(trimmed[captureRange])
        let unescaped = cnRaw.replacingOccurrences(of: "\\,", with: ",")
        return unescaped.trimmingCharacters(in: .whitespaces).capitalized
    }
}
