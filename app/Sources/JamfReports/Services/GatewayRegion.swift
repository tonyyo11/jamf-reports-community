import Foundation

/// The three Jamf Platform API gateway hosts (Jamf Cloud only). Onboarding and Update credentials
/// pick a region instead of typing a URL; the profile still stores the URL jamf-cli was given.
enum GatewayRegion: String, CaseIterable, Identifiable, Sendable {
    case us, eu, apac

    var id: String { rawValue }

    var label: String {
        switch self {
        case .us: "United States"
        case .eu: "Europe"
        case .apac: "Asia-Pacific"
        }
    }

    var host: String { "\(rawValue).api.jamfcloud.com" }
    var url: String { "https://\(host)" }

    /// The region a stored gateway URL names; nil for any other URL (a retired host, a proxy, a
    /// typo), which the picker shows as is and keeps until the region is changed. The host
    /// compares case-insensitively, as DNS does; a path, query, port or user info is not a match.
    static func region(forURL value: String) -> GatewayRegion? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("://"), let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host?.lowercased()
        else { return nil }
        return allCases.first { $0.host == host }
    }

    /// The gateway URL to start Update credentials with, from what the profile list shows: the
    /// list keeps a bare host (`us.api.jamfcloud.com`), or "(jamf-cli profile)" when jamf-cli
    /// recorded none. A known host becomes its region's URL; any other host is kept as typed
    /// with `https://` added; nil means keep the default region.
    static func startingURL(fromStored stored: String) -> String? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              !trimmed.hasPrefix("(") else { return nil }
        let full = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return region(forURL: full)?.url ?? full
    }
}

extension OnboardingFlow {
    /// The region `gatewayURL` names, nil when it is some other URL.
    var gatewayRegion: GatewayRegion? { GatewayRegion.region(forURL: gatewayURL) }

    func chooseGatewayRegion(_ region: GatewayRegion) {
        gatewayURL = region.url
    }
}
