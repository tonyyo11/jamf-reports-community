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

    /// The Jamf Pro URL of each side, both asked of the server first so the two are compared
    /// on what each server reports (a custom domain differs from the URL typed into jamf-cli).
    /// A stored URL outlives a profile that was pointed at another tenant, so it only stands
    /// in when the probe fails. A `jamf_pro` that is not a Platform profile falls back to the
    /// URL configured in jamf-cli; a Platform one has the gateway there, so it falls back to
    /// the stored one.
    static func lookup(
        jamfPro: String, platform: String, jamfProIsPlatform: Bool, configured: String?,
        learned: (String) -> String?, stored: (String) -> String?
    ) -> (jamfPro: String?, platform: String?) {
        (learned(jamfPro) ?? (jamfProIsPlatform ? stored(jamfPro) : configured),
         learned(platform) ?? stored(platform))
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
