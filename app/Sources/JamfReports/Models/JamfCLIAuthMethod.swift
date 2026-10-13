import Foundation

/// A jamf-cli profile's `auth-method`, the one reading of it (2.10). jamf-cli's `config list` (or
/// its config file) is the authority; every comparison goes through this type, never a string.
/// The value is matched as jamf-cli matches it: exactly, after trimming whitespace. jamf-cli's
/// own `switch p.AuthMethod { case "platform": … }` is case-sensitive, so a hand-typed
/// `Platform` is not a Platform API profile to jamf-cli and is `.other` here too.
enum JamfCLIAuthMethod: Equatable, Sendable {
    /// `config add-profile` with an API client (Jamf Pro, and Jamf Protect's `protect setup`).
    case oauth2
    /// A Jamf Account integration through the Jamf Platform API gateway.
    case platform
    /// `school setup`: Jamf School's network ID and API key.
    case apiKey
    /// `security setup`: Jamf Security Cloud.
    case security
    case other(String)

    /// The value as jamf-cli reports it, trimmed; nil when it says nothing.
    init?(raw: String?) {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        switch value {
        case "oauth2": self = .oauth2
        case "platform": self = .platform
        case "apikey": self = .apiKey
        case "security": self = .security
        default: self = .other(value)
        }
    }

    /// The word jamf-cli uses, for log lines (`auth-method is oauth2`).
    var rawValue: String {
        switch self {
        case .oauth2: "oauth2"
        case .platform: "platform"
        case .apiKey: "apikey"
        case .security: "security"
        case .other(let value): value
        }
    }

    var isPlatform: Bool { self == .platform }
}
