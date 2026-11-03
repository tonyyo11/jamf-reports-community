import Foundation

/// Spec 3.1: a `platform` slot whose profile reaches another Jamf Pro than `jamf_pro` would mix
/// two servers' data in one folder. Unknown (the probe failed, `jss-url:read` missing) never
/// blocks: we could not ask.
enum PlatformHostCheck {
    typealias Lookup = @Sendable (_ jamfPro: String, _ platform: String, _ bin: URL)
        -> (jamfPro: String?, platform: String?)

    enum Verdict: Equatable, Sendable {
        case same
        case different(jamfPro: String, platform: String)
        case unknown
    }

    static func verdict(jamfProURL: String?, platformJamfProURL: String?) -> Verdict {
        guard let jamfPro = PlatformTwin.host(of: jamfProURL),
              let platform = PlatformTwin.host(of: platformJamfProURL) else { return .unknown }
        return jamfPro == platform ? .same : .different(jamfPro: jamfPro, platform: platform)
    }

    /// The Jamf Pro profile's URL from jamf-cli's config file, and the Jamf Pro URL the platform
    /// profile reaches: recorded on its `Connection` member, else asked once per process.
    static let live: Lookup = { jamfPro, platform, bin in
        let configured = ProfileService.readConfigFile(at: ProfileService.jamfCLIConfigFileURL())?
            .first { $0.name == jamfPro }?.url
        let learned = ConnectionStore().jamfProURL(profile: platform)
            ?? PlatformTwin.learnJamfProURL(profile: platform, binary: bin)
        return (configured, learned)
    }
}
