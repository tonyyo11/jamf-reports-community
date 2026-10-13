import Foundation

extension ConnectionCredentialsModel {
    /// The real jamf-cli, file system and store. `profiles` is the app's list of jamf-cli
    /// profiles, read when the sheet plans a run.
    static func liveDependencies(
        profiles: @escaping @MainActor () -> [String], store: ConnectionStore
    ) -> Dependencies {
        Dependencies(
            jamfCLI: {
                guard let binary = ExecutableLocator.locate("jamf-cli") else { return nil }
                let version = await JamfCLIInstaller.installedVersionOffMain(at: binary)
                return JamfCLIContext(binary: binary, version: version)
            },
            register: { context, request in
                try OnboardingFlow.signatureGate(binary: context.binary)
                try await OnboardingFlow.registerPlatformProfile(
                    binary: context.binary, profile: request.profile,
                    gatewayURL: request.gatewayURL, scope: request.scope,
                    scopeID: request.scopeID, clientID: request.clientID,
                    clientSecret: request.clientSecret,
                    noVerify: JamfCLIInstaller.supportsSpecDerivedNames(context.version))
            },
            check: { context, profile in
                await ConnectionCheck.run(
                    profile: profile,
                    specNames: JamfCLIInstaller.supportsSpecDerivedNames(context.version),
                    runner: ConnectionCheck.runner(binary: context.binary))
            },
            existingProfiles: profiles,
            workspaceConflict: { ProfileService.caseVariantWorkspace(of: $0) },
            provisionWorkspace: { try OnboardingFlow.createJamfCLIOnlyWorkspace(for: $0) },
            store: store)
    }
}
