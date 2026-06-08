import Foundation

/// Single naming convention for every user-triggered export and engine report:
/// `<kind>-<profile>-<yyyy-MM-dd_HHmmss>.<ext>`.
///
/// Production surfaced two problems this fixes: exports without a timestamp
/// (`patch-compliance-prod.csv`) silently overwrite the previous export, and
/// engine reports without a profile (`report_2026-06-01_120000.xlsx`) can't be
/// attributed to a tenant once moved out of their workspace folder.
enum ExportNaming {

    /// `<kind>-<profile>-<timestamp>.<ext>`. The profile segment is omitted
    /// when `profile` is empty (single-tenant fallback).
    static func filename(kind: String, profile: String, ext: String, now: Date = Date()) -> String {
        let kindPart = sanitize(kind)
        let profilePart = sanitize(profile)
        let stamp = timestamp(now)
        if profilePart.isEmpty {
            return "\(kindPart)-\(stamp).\(ext)"
        }
        return "\(kindPart)-\(profilePart)-\(stamp).\(ext)"
    }

    /// `yyyy-MM-dd_HHmmss` in the local time zone — sortable, collision-safe
    /// at one-second granularity, and no characters that need escaping.
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: date)
    }

    /// Sanitize an arbitrary string into a safe filename component. Replaces
    /// anything outside `[A-Za-z0-9._-]` with `-` and collapses repeats.
    static func sanitize(_ raw: String) -> String {
        var result = raw.unicodeScalars.map { scalar in
            let char = Character(scalar)
            if char.isLetter || char.isNumber || char == "." || char == "_" || char == "-" {
                return String(char)
            }
            return "-"
        }.joined()
        result = result.replacingOccurrences(
            of: "-{2,}", with: "-", options: .regularExpression
        )
        // Trim leading/trailing hyphens and dots — leading dots make files
        // hidden on the filesystem.
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }
}
