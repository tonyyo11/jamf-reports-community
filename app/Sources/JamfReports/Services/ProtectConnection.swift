import Foundation

/// What Data Sources > Additional Products says about Jamf Protect, and the write that
/// disconnects it. The connection itself is `protect.enabled/profile` in the workspace's
/// config.yaml (`EnvironmentProfiles`); the jamf-cli profile it names lives in jamf-cli.
enum ProtectConnection {
    enum State: Equatable, Sendable {
        case notConnected
        case connected(profile: String)
        /// config.yaml names a profile jamf-cli no longer lists.
        case profileMissing(profile: String)
    }

    /// `configured` is the profile config.yaml names (nil when Protect is off). `cliProfiles` is
    /// the names `jamf-cli config list` returned, nil until read. An empty list reads as
    /// unknown too, since it is also what a Mac without jamf-cli returns: the app only says a
    /// profile is missing when it can see others.
    static func state(configured: String?, cliProfiles: [String]?) -> State {
        guard let configured else { return .notConnected }
        guard let cliProfiles, !cliProfiles.isEmpty, !cliProfiles.contains(configured) else {
            return .connected(profile: configured)
        }
        return .profileMissing(profile: configured)
    }

    static let credentialsNote =
        "Jamf Protect uses its own API client from Jamf Protect, not your Jamf Account "
        + "integration."

    /// Said after a disconnect. The profile is left in jamf-cli, so the command that removes it
    /// is named; a profile jamf-cli no longer lists needs no such line.
    static func disconnectedNote(profile: String, profileMissing: Bool) -> String {
        let base = "Jamf Protect is disconnected from this workspace."
        guard !profileMissing else { return base }
        return base + " The jamf-cli profile \(profile) is still in jamf-cli; "
            + "jamf-cli config remove-profile \(ProfileName.shellWord(profile)) removes it."
    }

    /// Sets `protect.enabled: false` and removes `protect.profile` through the scoped block
    /// writer, so every other key in the block stays and a comment there is copied out first
    /// (`ConfigSaveReport.backupName`). A workspace with no `protect` block is left alone.
    /// The changed profile is then confirmed on this Mac: disconnecting is the operator's own
    /// act, and an unconfirmed `protect.profile` would read as drift on the next run.
    @discardableResult
    static func disconnect(
        workspace profile: String, appSupport: URL = AppSupport.directory()
    ) throws -> ConfigSaveReport {
        let report = try ConfigService.saveBlock(
            key: "protect", profile: profile, profilesSlot: "protect"
        ) { root in
            guard var block = root.value(for: "protect")?.mapping else { return }
            block.set("enabled", value: .scalar(.bool(false)))
            block.entries.removeAll { $0.key == "profile" }
            root.set("protect", value: .mapping(block))
        }.report
        SharedConfigPin.confirmBestEffort(
            profile: profile, keys: [.protectProfile], appSupport: appSupport)
        return report
    }
}
