import Foundation

// MARK: - ControlID

/// A typed wrapper for a compliance-control identifier string.
///
/// Canonical form matches NIST SP 800-53 / DISA STIG notation:
/// `^[A-Z]{2,5}-\d+(\.\d+)?$` — e.g. `AC-3`, `IA-5`, `AC-3(2)` (with enhancements).
///
/// Non-matching strings are accepted but flagged as non-canonical via `isCanonical`.
/// This lets operators paste free-text references without the app rejecting them.
///
/// ## Cross-lane handoff — Q1
///
/// `ConfigException.controlID: String? = nil` **MUST be added to the struct**
/// in `ConfigDecoder.swift` by Q1 before the extension below can surface the
/// typed `controlID` property. Until Q1 lands that field this extension is
/// compiled but the computed property returns `nil` unconditionally.
///
/// When Q1 adds the stored property:
/// 1. Change the computed property body to `ControlID(rawValue: raw)`.
/// 2. Remove the `// DEFERRED:` comment.
public struct ControlID: Codable, Sendable, Hashable {

    // Regex: two-to-five uppercase letters, dash, one-or-more digits,
    // optional dot-and-digits enhancement, optional parenthesized suffix.
    // Matches: AC-3, IA-5, AC-3(2), SI-7.1, CM-6(1)
    private static let canonicalPattern =
        #"^[A-Z]{2,5}-\d+(\(\d+\))?(\.\d+(\(\d+\))?)?$"#

    /// The raw string as provided by the caller.
    public let raw: String

    /// `true` when `raw` matches the canonical NIST/STIG control-ID format.
    /// `false` for free-text references — stored without modification but not validated.
    public let isCanonical: Bool

    // MARK: - Init

    /// Parse a control ID string.
    ///
    /// - Parameter rawValue: The control identifier string, e.g. `"AC-3"` or `"AC-3(2)"`.
    public init(raw: String) {
        self.raw = raw
        self.isCanonical = raw.range(
            of: ControlID.canonicalPattern,
            options: .regularExpression
        ) != nil
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self.init(raw: value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

// MARK: - ConfigException extension

extension ConfigException {

    /// Typed control-ID accessor. Returns `nil` when no `control_id` was present
    /// in the YAML, otherwise wraps the raw string in a `ControlID` (which records
    /// whether the raw form matched the canonical NIST/STIG pattern).
    var typedControlID: ControlID? {
        guard let raw = controlID, !raw.isEmpty else { return nil }
        return ControlID(raw: raw)
    }
}
