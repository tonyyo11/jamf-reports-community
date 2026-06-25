import Foundation

// MARK: - CSVFamily

/// The device family of a Jamf Pro CSV export.
/// Ported verbatim from Python: ``"computers"`` / ``"mobile"`` raw values match the
/// Python return values of ``_detect_csv_family_from_headers``.
enum CSVFamily: String, Sendable, Equatable {
    case computers
    case mobile
}

// MARK: - CSVFamilyDetector

/// Detects whether a Jamf Pro CSV export contains computers or mobile devices.
///
/// Discriminator tables (`computerDiscriminators` / `mobileDiscriminators`) are
/// curated sets of headers that appear in only one export family. Detection counts
/// header hits per set; the winning set wins. Returns `nil` on a tie or zero hits.
enum CSVFamilyDetector {

    // Pre-normalized (lowercase, single-spaced) headers that appear ONLY in a
    // Jamf Pro computer export. Ported verbatim from Python COMPUTER_CSV_DISCRIMINATORS.
    static let computerDiscriminators: Set<String> = [
        "computer name", "jss computer id", "operating system version",
        "last check-in", "gatekeeper", "system integrity protection",
        "filevault 2 status", "firewall enabled", "secure boot level",
        "processor type", "apple silicon", "boot drive percentage full",
    ]

    // Pre-normalized (lowercase, single-spaced) headers that appear ONLY in a
    // Jamf Pro mobile-device export. Ported verbatim from Python MOBILE_CSV_DISCRIMINATORS.
    static let mobileDiscriminators: Set<String> = [
        "display name", "jss mobile device id", "device id", "imei", "iccid",
        "jailbreak detected", "shared ipad", "wi-fi mac address",
        "battery level", "lost mode enabled", "device ownership type",
        "passcode status",
    ]

    /// Normalize a header string for discriminator comparison.
    ///
    /// Lowercases, strips UTF-8 BOM (U+FEFF), collapses all whitespace runs to a
    /// single space, and trims leading/trailing whitespace. Hyphens are preserved
    /// (discriminators include "last check-in", "wi-fi mac address").
    ///
    /// - Parameter header: Raw CSV column name (any casing, may include BOM).
    /// - Returns: Normalized string suitable for comparison against discriminator tables.
    static func normalize(_ header: String) -> String {
        var s = header
        // Strip UTF-8 BOM if present at the very start.
        if s.hasPrefix("\u{FEFF}") { s = String(s.dropFirst()) }
        return s
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Detect the device family of a CSV export from its header names.
    ///
    /// Counts normalized header hits against each discriminator set. Returns
    /// `.mobile` when mobile hits exceed computer hits, `.computers` when
    /// computer hits exceed mobile hits, and `nil` when both are zero or tied.
    ///
    /// - Parameter headers: CSV column names (any case/spacing, may contain BOM).
    /// - Returns: Detected `CSVFamily`, or `nil` if the family is ambiguous.
    static func detect(headers: [String]) -> CSVFamily? {
        let normalized = Set(headers.map { normalize($0) })
        let computerHits = computerDiscriminators.intersection(normalized).count
        let mobileHits = mobileDiscriminators.intersection(normalized).count
        if mobileHits > computerHits { return .mobile }
        if computerHits > mobileHits { return .computers }
        return nil
    }
}
