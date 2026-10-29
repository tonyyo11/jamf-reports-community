import Foundation

extension ConnectionCredentialsModel {
    /// The real jamf-cli, file system and store. `profiles` is the app's list of jamf-cli
    /// profiles, read when the sheet plans a run.
    static func liveDependencies(
        profiles: @escaping @MainActor () -> [JamfCLIProfile], store: ConnectionStore
    ) -> Dependencies {
        Dependencies(
            jamfCLI: {
                ExecutableLocator.locate("jamf-cli").map { JamfCLIContext(binary: $0) }
            },
            register: { context, request in
                try OnboardingFlow.signatureGate(binary: context.binary)
                try await OnboardingFlow.registerPlatformProfile(
                    binary: context.binary, profile: request.profile,
                    gatewayURL: request.gatewayURL, scope: request.scope,
                    scopeID: request.scopeID, clientID: request.clientID,
                    clientSecret: request.clientSecret)
            },
            check: { context, profile in
                await ConnectionCheck.run(
                    profile: profile, runner: ConnectionCheck.runner(binary: context.binary))
            },
            existingProfiles: { profiles().map(\.name) },
            workspaceConflict: { ProfileService.caseVariantWorkspace(of: $0) },
            provisionWorkspace: { try OnboardingFlow.createJamfCLIOnlyWorkspace(for: $0) },
            store: store,
            canReRegister: { name in
                guard let profile = profiles().first(where: { $0.name == name }) else {
                    return false
                }
                return isLeftoverPlatformProfile(
                    profile, connections: store.load(),
                    workspaceExists: ProfileService.workspaceURL(for: name).map {
                        FileManager.default.fileExists(atPath: $0.path)
                    } ?? true)
            },
            storedURL: { name in profiles().first { $0.name == name }?.url })
    }

    /// A Platform profile that an earlier Add environments attempt in this app registered and
    /// never made a member: recorded as unconfirmed by a connection, in no connection as a
    /// member, and with no workspace folder. A profile made in Terminal, or anything else, may
    /// be in use and holds credentials this app did not write.
    static func isLeftoverPlatformProfile(
        _ profile: JamfCLIProfile, connections: [Connection], workspaceExists: Bool
    ) -> Bool {
        !workspaceExists && profile.auth?.isPlatform == true
            && connections.contains { $0.unconfirmedProfiles.contains(profile.name) }
            && !connections.contains { $0.members.contains { $0.profile == profile.name } }
    }
}
