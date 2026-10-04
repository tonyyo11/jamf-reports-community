import Foundation

/// The one reader of a failed-rules list cell (`compliance.baselines[].failures_list_column`).
///
/// mSCP's audit script writes one rule ID per line; older exports and hand-built EAs use `|`,
/// `,` or `;`. An audit that cannot evaluate a Mac writes a status in the list's place ("No
/// Baseline Set", "Multiple Baselines Found"). Top Failing Rules and the count-vs-list check
/// both read the cell through here, so they cannot disagree about what a list is.
enum FailedRuleList {

    private static let separators = CharacterSet(charactersIn: "\n\r\t|,;")

    /// Text a script writes instead of a list. Matched whole, case-insensitively.
    private static let statusValues: Set<String> = [
        "none", "pass", "passed", "n/a", "no baseline set", "multiple baselines found",
    ]

    /// The distinct rule IDs in `cell`, in order of first appearance. A blank cell is an
    /// empty list (nothing failed). `nil` means the cell holds no list at all: a status value,
    /// or text no rule ID could be read from. Such a Mac was not evaluated, so it is neither
    /// a Mac with failures nor a Mac with none.
    static func rules(in cell: String?) -> [String]? {
        let parts = (cell ?? "").components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return [] }
        if parts.count == 1, statusValues.contains(parts[0].lowercased()) { return nil }
        var seen = Set<String>()
        let rules = parts.filter {
            isRuleID($0) && !statusValues.contains($0.lowercased()) && seen.insert($0).inserted
        }
        return rules.isEmpty ? nil : rules
    }

    /// Rule IDs are one token of letters, digits, `_`, `.` or `-` (`os_firewall_enable`), so
    /// a sentence is never one.
    private static func isRuleID(_ token: String) -> Bool {
        token.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
    }
}
