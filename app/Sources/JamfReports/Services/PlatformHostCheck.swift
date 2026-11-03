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

    /// The Jamf Pro URL of each side. The platform profile's is asked of the server first: a
    /// stored URL outlives a profile that was pointed at another tenant, so it only stands in
    /// when the probe fails. A `jamf_pro` that is itself a Platform profile has the gateway
    /// for its URL, so its Jamf Pro URL is learned the same way; an OAuth one is configured.
    static func lookup(
        jamfPro: String, platform: String, jamfProIsPlatform: Bool, configured: String?,
        learned: (String) -> String?, stored: (String) -> String?
    ) -> (jamfPro: String?, platform: String?) {
        func reached(_ profile: String) -> String? { learned(profile) ?? stored(profile) }
        return (jamfProIsPlatform ? reached(jamfPro) : configured, reached(platform))
    }

    static let live: Lookup = { jamfPro, platform, bin in
        lookup(
            jamfPro: jamfPro, platform: platform,
            jamfProIsPlatform: ProfileAuthMethod.resolve(profile: jamfPro, binary: bin)?.method
                == .platform,
            configured: ProfileService.readConfigFile(at: ProfileService.jamfCLIConfigFileURL())?
                .first { $0.name == jamfPro }?.url,
            learned: { PlatformTwin.learnJamfProURL(profile: $0, binary: bin) },
            stored: { ConnectionStore().jamfProURL(profile: $0) })
    }
}
