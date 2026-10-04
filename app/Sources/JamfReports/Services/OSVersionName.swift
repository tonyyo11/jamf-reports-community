import Foundation

/// The one spelling of a macOS version for anything that counts Macs by version.
///
/// Jamf reports the same release both ways: `26.7` (the About box) and `26.7.0`, so a
/// tally by raw string lists one release twice. A dotted number whose third component is
/// `0` loses it; every other string is left as written.
enum OSVersionName {

    struct Row: Sendable, Equatable {
        var version: String
        var count: Int
        var pct: Double
    }

    /// A share as jamf-cli prints it (`"41.2%"`); 0 when it is not a number.
    static func percent(_ text: String) -> Double {
        Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) ?? 0
    }

    static func normalized(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "0", parts.allSatisfy(isDigits) else { return text }
        return "\(parts[0]).\(parts[1])"
    }

    /// `rows` with the rows of one release combined (counts and shares add), in order of
    /// first appearance.
    static func merged(_ rows: [Row]) -> [Row] {
        var merged: [Row] = []
        var position: [String: Int] = [:]
        for row in rows {
            let name = normalized(row.version)
            if let index = position[name] {
                merged[index].count += row.count
                merged[index].pct += row.pct
            } else {
                position[name] = merged.count
                merged.append(Row(version: name, count: row.count, pct: row.pct))
            }
        }
        return merged
    }

    private static func isDigits(_ part: Substring) -> Bool {
        !part.isEmpty && part.allSatisfy { ("0"..."9").contains($0) }
    }
}
