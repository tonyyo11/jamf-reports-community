import Foundation

/// The one reader of a Mac's raw FileVault value in a `computers` snapshot item, for the
/// Computers screen, the Device Security State sheet and Fleet Drift.
enum FileVaultValue {
    private static let paths: [[String]] = [
        ["diskEncryption", "bootPartitionEncryptionDetails", "partitionFileVault2State"],
        ["operatingSystem", "fileVault2Status"],
        ["diskEncryption", "fileVault2Enabled"],
    ]

    /// The first set field, trimmed: a String as written, a Bool (or a 0/1 number) as
    /// "true"/"false", any other number as its digits. Nil when none is set.
    static func raw(computer item: [String: Any]) -> String? {
        for path in paths {
            var node: Any? = item
            for key in path { node = (node as? [String: Any])?[key] }
            if let value = text(node) { return value }
        }
        return nil
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as Bool: return value ? "true" : "false"
        case let value as NSNumber: return value.stringValue
        default: return nil
        }
    }
}
