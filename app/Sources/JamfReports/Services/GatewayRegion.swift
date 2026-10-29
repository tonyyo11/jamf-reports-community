import Foundation

/// The three Jamf Platform API gateway hosts (Jamf Cloud only). Onboarding and Update credentials
/// pick a region instead of typing a URL, or choose Other and type a host; the profile still
/// stores the URL jamf-cli was given.
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

    /// The number `school setup`'s "Choose [1-4]" region prompt takes for this region.
    var setupChoice: String {
        switch self {
        case .us: "1"
        case .eu: "2"
        case .apac: "3"
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

/// What a typed, stored or adopted gateway host is, before any jamf-cli call.
enum GatewayURLCheck: Equatable, Sendable {
    /// Usable: the URL as jamf-cli should receive it (`https://host[:port]`, host lowercased).
    case ok(String)
    case invalid
    /// `apigw.jamf.com` or a host under it, which jamf-cli refuses by name.
    case retired
}

extension GatewayRegion {
    static let retiredHost = "apigw.jamf.com"

    /// Shown wherever a retired gateway is refused; the hint is the one `FailureCause` gives
    /// when jamf-cli refuses it after a failed collect.
    static let retiredRefusal = "\(retiredHost) is the retired Jamf Platform gateway. "
        + FailureCause.retiredGatewayHint

    static let invalidHostText = "Enter a host such as gateway.example.org, with an optional "
        + "port. Use only letters, digits, dots and hyphens; https:// is optional."

    /// The one check of a gateway host for every entry point. Accepts a host of letters, digits,
    /// dots and hyphens with an optional port, with or without `https://`.
    static func check(_ typed: String) -> GatewayURLCheck {
        let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // The retired gateway is named whatever else is wrong with the URL (a scheme, a path).
        if isRetired(host: looseHost(of: value)) { return .retired }
        var rest = Substring(value)
        if let scheme = rest.range(of: "https://", options: [.anchored, .caseInsensitive]) {
            rest.removeSubrange(scheme)
        }
        if rest.hasSuffix("/") { rest.removeLast() }
        let parts = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count <= 2, let host = parts.first.map({ String($0).lowercased() }),
              isHostName(host) else { return .invalid }
        var port = ""
        if parts.count == 2 {
            guard let number = Int(parts[1]), (1...65535).contains(number),
                  parts[1].allSatisfy(\.isASCII), parts[1].allSatisfy(\.isNumber)
            else { return .invalid }
            port = ":\(number)"
        }
        return .ok("https://\(host)\(port)")
    }

    private static func isRetired(host: String) -> Bool {
        host == retiredHost || host.hasSuffix("." + retiredHost)
    }

    /// The host of `value` with any scheme, user info, port, path, query or fragment removed;
    /// not validated, only for recognising the retired gateway.
    private static func looseHost(of value: String) -> String {
        var rest = Substring(value)
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        if let end = rest.firstIndex(where: { "/?#".contains($0) }) { rest = rest[..<end] }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        if let colon = rest.firstIndex(of: ":") { rest = rest[..<colon] }
        return rest.lowercased()
    }

    /// Dot-separated labels of ASCII letters, digits and inner hyphens, so a typed host can never
    /// read as a flag or carry a path, user info or whitespace.
    private static func isHostName(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-" else { return false }
            return label.unicodeScalars.allSatisfy {
                $0.value < 0x80 && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
            }
        }
    }

    /// Why `typed` cannot be used, nil when it can.
    static func problem(with typed: String) -> String? {
        switch check(typed) {
        case .ok: nil
        case .invalid: invalidHostText
        case .retired: retiredRefusal
        }
    }
}

extension OnboardingFlow {
    /// The region `gatewayURL` names, nil when it is some other URL.
    var gatewayRegion: GatewayRegion? { GatewayRegion.region(forURL: gatewayURL) }

    /// The picker's selection: nil is Other, which stays selected while a host is typed even
    /// when it happens to name a region.
    var gatewayPickerSelection: GatewayRegion? {
        gatewayOtherSelected ? nil : gatewayRegion
    }

    func chooseGatewayRegion(_ region: GatewayRegion) {
        gatewayOtherSelected = false
        gatewayURL = region.url
    }

    /// Other starts with no host, unless one is already typed that no region names.
    func chooseOtherGateway() {
        gatewayOtherSelected = true
        if gatewayRegion != nil { gatewayURL = "" }
    }

    /// The URL jamf-cli receives; nil when `gatewayURL` is not usable.
    var normalizedGatewayURL: String? {
        if case .ok(let url) = GatewayRegion.check(gatewayURL) { return url }
        return nil
    }
}
