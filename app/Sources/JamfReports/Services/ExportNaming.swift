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
        let profilePart = profilePart(profile)
        let stamp = timestamp(now)
        if profilePart.isEmpty {
            return "\(kindPart)-\(stamp).\(ext)"
        }
        return "\(kindPart)-\(profilePart)-\(stamp).\(ext)"
    }

    /// What every generated report's name starts with unless `output.file_prefix` says otherwise.
    static let defaultFilePrefix = "jamf"
    static let maxFilePrefixLength = 24

    /// `output.file_prefix` when it can start a file name: 1-24 ASCII letters, digits or
    /// hyphens. No underscore, which separates the prefix from the kind when a name is read
    /// back (`reportNameParts`). Nil for anything else, which reads as `jamf`.
    static func validFilePrefix(_ raw: String?) -> String? {
        guard let typed = raw?.trimmingCharacters(in: .whitespaces), !typed.isEmpty,
              typed.count <= maxFilePrefixLength,
              typed.unicodeScalars.allSatisfy({
                  $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
              })
        else { return nil }
        return typed
    }

    /// The prefix the profile's config.yaml sets, for a screen that has no decoded config.
    static func filePrefix(profile: String) -> String {
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            return defaultFilePrefix
        }
        let url = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: url.path),
              let output = (try? ConfigLoader.load(from: url))?.output
        else { return defaultFilePrefix }
        return output.resolvedFilePrefix
    }

    /// What a generated report's file name starts with, before the profile: the one
    /// definition the writers and the Generate sheet's "What will be written" share.
    static func reportKind(
        for type: GenerateOutputType, schoolMode: Bool, prefix: String = defaultFilePrefix
    ) -> String {
        switch type {
        case .xlsx, .csvFolder: schoolMode ? "\(prefix)_school_report" : "\(prefix)_report"
        case .html, .pdf: "\(prefix)_report"
        case .csv: "\(prefix)_inventory"
        }
    }

    /// A generated report's name split at its kind: `acme_report_prod_2026-…` is prefix
    /// `acme`, kind `report`, rest `prod_2026-…`. Names from before 2.12 have no prefix
    /// (`report_…`, `school-report_…`, `inventory_…`), so any prefix and the old names read
    /// back. Nil for a name that is not a generated report.
    struct ReportNameParts: Equatable {
        enum Kind: String { case report, schoolReport, inventory }
        let prefix: String?
        let kind: Kind
        let rest: String

        /// The name without its prefix, so runs of one profile match whatever prefix wrote them.
        var key: String { "\(kind.rawValue)_\(rest)" }
    }

    static func reportNameParts(_ stem: String) -> ReportNameParts? {
        let pattern = #/
            (?i)^ (?: ([A-Za-z0-9-]{1,24}) _ )?
            (school_report | school-report | report | inventory) _ (.+) $
            /#
        guard let match = stem.wholeMatch(of: pattern) else { return nil }
        let kind: ReportNameParts.Kind = switch match.2.lowercased() {
        case "school_report", "school-report": .schoolReport
        case "inventory": .inventory
        default: .report
        }
        return ReportNameParts(prefix: match.1.map(String.init), kind: kind, rest: String(match.3))
    }

    /// A generated report's file name before its timestamp and extension: `jamf_report_prod`.
    static func stem(
        for type: GenerateOutputType, profile: String, schoolMode: Bool,
        prefix: String = defaultFilePrefix
    ) -> String {
        let kind = reportKind(for: type, schoolMode: schoolMode, prefix: prefix)
        let part = profilePart(profile)
        return part.isEmpty ? kind : "\(kind)_\(part)"
    }

    /// A profile name inside a file name: kept whole (spaces, dots and accents included) so it
    /// reads back exactly, with only what a file name can't hold encoded (`ProfileName`).
    static func profilePart(_ profile: String) -> String {
        ProfileName.pathComponent(profile)
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

extension ReportConfig {
    /// What this workspace's generated reports are named with (`output.file_prefix`).
    var filePrefix: String { output?.resolvedFilePrefix ?? ExportNaming.defaultFilePrefix }
}
