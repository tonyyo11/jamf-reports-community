import Foundation
import Observation

/// The Add sheet's "Connect new" for the Platform API add-on (D25): registers a new jamf-cli
/// Platform profile, checks the ID and the Jamf Pro host, then names it in the current
/// workspace's `profiles.platform` slot. No workspace is made for the profile (D24). The secret
/// lives here from `setSecret` until `connect` ends or the sheet closes, and is never logged.
@MainActor
@Observable
final class PlatformSlotConnectModel {
    typealias PlatformScope = OnboardingFlow.PlatformScope

    /// Everything outside the model, so no test launches jamf-cli or writes config.yaml.
    struct Dependencies {
        var jamfCLI: () -> URL?
        var register: @Sendable (_ binary: URL, _ profile: String, _ gatewayURL: String,
                                 _ scope: PlatformScope, _ scopeID: String,
                                 _ clientID: String, _ secret: Data) async throws -> Void
        var check: @Sendable (_ binary: URL, _ profile: String) async -> ConnectionCheck.Verdict
        var hostVerdict: @Sendable (_ workspace: String, _ platform: String, _ binary: URL) async
            -> PlatformHostCheck.Verdict
        var writeSlot: @Sendable (_ workspace: String, _ platform: String) async throws -> Void
        var existingProfiles: () -> [String]

        /// `existingProfiles` is every name jamf-cli lists, so a new profile takes none of them.
        static func live(existingProfiles: @escaping () -> [String]) -> Dependencies {
            Dependencies(
                jamfCLI: { ExecutableLocator.locate("jamf-cli") },
                register: { binary, profile, gatewayURL, scope, scopeID, clientID, secret in
                    try OnboardingFlow.signatureGate(binary: binary)
                    try await OnboardingFlow.registerPlatformProfile(
                        binary: binary, profile: profile, gatewayURL: gatewayURL, scope: scope,
                        scopeID: scopeID, clientID: clientID, clientSecret: secret)
                },
                check: { binary, profile in
                    await ConnectionCheck.run(
                        profile: profile, runner: ConnectionCheck.runner(binary: binary))
                },
                hostVerdict: { workspace, platform, binary in
                    // jamf-cli blocks, so it runs off the main actor.
                    await Task.detached {
                        guard let jamfPro = EnvironmentProfiles.read(workspace: workspace).jamfPro
                        else { return PlatformHostCheck.Verdict.unknown }
                        let urls = PlatformHostCheck.live(jamfPro, platform, binary)
                        return PlatformHostCheck.verdict(
                            jamfProURL: urls.jamfPro, platformJamfProURL: urls.platform)
                    }.value
                },
                writeSlot: { workspace, platform in
                    // Seeding a block can run `config list`, so it runs off the main actor.
                    _ = try await Task.detached {
                        try ProfilesConfigWriter.save(.platform, to: platform, workspace: workspace)
                    }.value
                },
                existingProfiles: existingProfiles)
        }
    }

    enum Outcome: Equatable {
        case added(String)
        case refused(String)
        case failed(String)
    }

    let workspace: String
    var profileName: String
    var region: GatewayRegion = .us
    var scope: PlatformScope = .environment
    var scopeID = ""
    var clientID = ""
    var secretFieldHasText = false
    // Not observed, so a clear zeroes the stored bytes in place; the has-text Bool drives Connect.
    @ObservationIgnored private var clientSecret = Data()
    private(set) var isRunning = false
    private(set) var outcome: Outcome?

    private let deps: Dependencies

    init(workspace: String, dependencies: Dependencies) {
        self.workspace = workspace
        self.profileName = "\(workspace)-API"
        self.deps = dependencies
    }

    func setSecret(_ data: Data) {
        clientSecret.wipe()
        clientSecret = data
    }

    /// Overwrites the secret before dropping it; the field's own copy is cleared by the sheet.
    func clearSecret() {
        clientSecret.wipe()
        secretFieldHasText = false
    }

    #if DEBUG
    var secretByteCount: Int { clientSecret.count }
    #endif

    var nameProblem: String? {
        let name = profileName
        guard ProfileService.isValid(name) else { return L("This is not a usable profile name.") }
        let key = ProfileName.folderKey(name)
        if deps.existingProfiles().contains(where: { ProfileName.folderKey($0) == key }) {
            return L("jamf-cli already has a profile with this name.")
        }
        return nil
    }

    var canConnect: Bool {
        !isRunning && nameProblem == nil
            && ConnectionEnvironments.isUsableID(scopeID.trimmingCharacters(in: .whitespaces))
            && !clientID.trimmingCharacters(in: .whitespaces).isEmpty
            && (!clientSecret.isEmpty || secretFieldHasText)
    }

    func connect() async {
        guard canConnect else { return }
        isRunning = true
        outcome = nil
        // Moved, not copied: the stored value is empty from here and the local copy is wiped.
        var secret = clientSecret
        clientSecret = Data()
        defer {
            secret.wipe()
            clearSecret()
            isRunning = false
        }
        guard let binary = deps.jamfCLI() else {
            outcome = .failed(
                L("Could not find jamf-cli. Install it from the sidebar's setup step."))
            return
        }
        let profile = profileName
        do {
            try await deps.register(
                binary, profile, region.url, scope,
                scopeID.trimmingCharacters(in: .whitespaces),
                clientID.trimmingCharacters(in: .whitespaces), secret)
        } catch {
            // jamf-cli may have saved the profile before failing (a PTY timeout, for one).
            outcome = .failed(leftover(error.localizedDescription, profile))
            return
        }
        ProfileAuthMethod.invalidateCache()
        PlatformTwin.invalidateCache()
        let gate = await PlatformSlotGate.evaluate(
            profile: profile, tenantLevel: scope == .tenant,
            check: { [deps] in await deps.check(binary, profile) },
            hostVerdict: { [deps, workspace] in await deps.hostVerdict(workspace, profile, binary) })
        let note: String
        switch gate {
        case .refused(let text):
            outcome = .refused(leftover(text, profile))
            return
        case .proceed(let added):
            note = added
        }
        do {
            try await deps.writeSlot(workspace, profile)
        } catch {
            outcome = .failed(leftover(
                L("Could not add \(profile): \(error.localizedDescription)"), profile))
            return
        }
        outcome = .added(
            AddSheetPlan.platformAddedMessage(profile: profile, workspace: workspace) + note)
    }

    private func leftover(_ text: String, _ profile: String) -> String {
        let word = ProfileName.shellWord(profile)
        return text + " "
            + L("The profile \(profile) is still in jamf-cli; remove it with jamf-cli config remove-profile -- \(word).")
    }
}

/// The one check before a Platform profile is named in a workspace's `profiles.platform` slot,
/// shared by Connect new and the listing's Add: a rejected ID or a non-Jamf-Pro environment
/// refuses, then the host check; an undecided answer goes ahead with a note.
@MainActor
enum PlatformSlotGate {
    enum Result: Equatable {
        case refused(String)
        case proceed(note: String)
    }

    static func evaluate(
        profile: String, tenantLevel: Bool,
        check: () async -> ConnectionCheck.Verdict,
        hostVerdict: () async -> PlatformHostCheck.Verdict
    ) async -> Result {
        let verdict = await check()
        var note = ""
        switch verdict {
        case .rejectedID, .noJamfPro:
            return .refused(verdict.message(tenantLevel: tenantLevel))
        case .missingPermission, .undecided:
            note = " " + verdict.message(tenantLevel: tenantLevel)
        case .accepted:
            break
        }
        let hosts = await hostVerdict()
        if let refusal = AddSheetPlan.platformHostRefusal(profile: profile, verdict: hosts) {
            return .refused(refusal)
        }
        return .proceed(note: note)
    }
}
