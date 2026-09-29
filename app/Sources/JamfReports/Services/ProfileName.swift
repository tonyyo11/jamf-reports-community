import Foundation

/// Maps a jamf-cli profile name to the places it lands on disk. jamf-cli accepts any name (it
/// checks only the URL and auth method), so the app keeps the exact name and encodes it only here.
enum ProfileName {

    /// Why a name can't be used. The app takes every other name jamf-cli takes.
    enum Problem: Equatable, Sendable {
        case empty
        case controlCharacter
        case edgeWhitespace
        case tooLong

        var explanation: String {
            switch self {
            case .empty:
                return "The profile has no name."
            case .controlCharacter:
                return "The name contains a line break, tab or other control character."
            case .edgeWhitespace:
                return "The name starts or ends with a space."
            case .tooLong:
                return "The name is too long to use as a folder and file name."
            }
        }
    }

    /// Longest label part, in UTF-8 bytes. Keeps `<label>.<timestamp>.log` and
    /// `report_<name>_<timestamp>.xlsx.manifest.txt` under the 255-byte file name limit.
    static let maxEncodedBytes = 120

    static func problem(with name: String) -> Problem? {
        guard let first = name.unicodeScalars.first, let last = name.unicodeScalars.last else {
            return .empty
        }
        if name.unicodeScalars.contains(where: isControl) { return .controlCharacter }
        let edges = CharacterSet.whitespacesAndNewlines
        if edges.contains(first) || edges.contains(last) { return .edgeWhitespace }
        return labelComponent(name).utf8.count > maxEncodedBytes ? .tooLong : nil
    }

    /// Folder and file-name part. Percent-encodes `%`, `/`, `:`, control characters, and a
    /// leading `.` (hidden) or `_` (the workspace root's own `_fleet-reports`). A name of letters,
    /// digits, `-` and `_` starting with a letter or digit is unchanged.
    static func pathComponent(_ name: String) -> String {
        encode(name) { scalar, isFirst in
            switch scalar {
            case "%", "/", ":": return true
            case ".", "_": return isFirst
            default: return isControl(scalar)
            }
        }
    }

    /// Schedule-label part. Percent-encodes everything outside ASCII letters, digits, `_` and
    /// `-`, so a `.` in a label is always a separator.
    static func labelComponent(_ name: String) -> String {
        encode(name) { scalar, _ in
            !(scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
                || scalar == "-"))
        }
    }

    /// The name `component` encodes, or nil when it isn't `pathComponent` of any name.
    static func name(fromPathComponent component: String) -> String? {
        guard let name = component.removingPercentEncoding, pathComponent(name) == component
        else { return nil }
        return name
    }

    /// The name `component` encodes, or nil when it isn't `labelComponent` of any name.
    static func name(fromLabelComponent component: String) -> String? {
        guard let name = component.removingPercentEncoding, labelComponent(name) == component
        else { return nil }
        return name
    }

    /// One entry of a comma-separated profile list on a command line (`--exclude-profiles`),
    /// trimmed. `%2C` stands for a comma in a name and `%25` for a percent sign.
    static func name(fromListElement element: Substring) -> String {
        let trimmed = element.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.removingPercentEncoding ?? trimmed
    }

    /// The name as one shell word, for commands the app shows or copies: unchanged when it
    /// has only letters, digits, `_`, `-` and `.`, otherwise single-quoted.
    static func shellWord(_ name: String) -> String {
        let plain = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        if !name.isEmpty, name.unicodeScalars.allSatisfy(plain.contains) { return name }
        return "'" + name.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `--profile <word>` for the app's own command line. A name starting with `-` is joined
    /// with `=`, because swift-argument-parser reads a separate dash-leading value as an option.
    static func profileOption(_ name: String) -> String {
        name.hasPrefix("-") ? "--profile=\(shellWord(name))" : "--profile \(shellWord(name))"
    }

    /// Names whose keys match share one folder on a case- and normalization-insensitive volume,
    /// which is how macOS formats APFS by default.
    static func folderKey(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
    }

    /// Control characters plus the line and paragraph separators (U+2028, U+2029), which are
    /// not category `.control` but split lines for YAMLCodec and the line-based run logs.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || CharacterSet.newlines.contains(scalar)
    }

    private static func encode(
        _ name: String, escaping: (Unicode.Scalar, _ isFirst: Bool) -> Bool
    ) -> String {
        var out = ""
        for (index, scalar) in name.unicodeScalars.enumerated() {
            if escaping(scalar, index == 0) {
                for byte in String(scalar).utf8 { out += String(format: "%%%02X", byte) }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
