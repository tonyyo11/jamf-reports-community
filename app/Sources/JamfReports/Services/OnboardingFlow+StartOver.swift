import Foundation

/// Start over: back to the first-launch chooser, taking back what this run created.
extension OnboardingFlow {
    /// A jamf-cli command or a file write is running; navigation waits for it.
    var isBusy: Bool {
        isRegisteringProfile || isValidatingConnection || isRunningFirstReport
            || isConnectingProtect || isConnectingSchool
    }

    /// True when Start over has something to remove, so it asks first.
    var startOverRemovesSomething: Bool { !createdWorkspaces.isEmpty || !createdProfiles.isEmpty }

    /// What Start over removes, for its confirmation.
    var startOverMessage: String {
        var lines = [L("This setup has created:")]
        for profile in createdWorkspaces {
            let folder = WorkspaceRootStore.displayPath(profile: profile)
            lines.append(L("• the workspace folder \(folder), which moves to the Trash"))
        }
        for profile in createdProfiles {
            lines.append(L("• the jamf-cli profile \(profile), which is removed with its saved credentials"))
        }
        lines.append("")
        lines.append(L("You go back to the first screen to choose how to connect."))
        return lines.joined(separator: "\n")
    }

    /// Clears the secrets and the chooser's queued choice, removes the jamf-cli profiles this run
    /// added (and their connection record), then trashes the folders it created. Returns one line
    /// per thing that is still there; an item that failed stays listed, so Start over can retry.
    func startOver() async -> [String] {
        clearAllSecrets()
        Self.pendingProductPath = nil
        Self.pendingProConnectionType = nil
        var problems: [String] = []

        for profile in createdProfiles {
            if let failure = await profileRemover(profile) {
                problems.append(failure)
                continue
            }
            createdProfiles.removeAll { $0 == profile }
            do {
                try connectionStore.removeMember(profile: profile)
            } catch {
                problems.append(L("The jamf-cli profile \(profile) was removed, but its connection record was not: \(error.localizedDescription)"))
            }
        }

        for profile in createdWorkspaces {
            do {
                try workspaceTrasher(profile)
                createdWorkspaces.removeAll { $0 == profile }
            } catch {
                problems.append(L("The workspace folder \(WorkspaceRootStore.displayPath(profile: profile)) was not moved to the Trash: \(error.localizedDescription)"))
            }
        }
        return problems
    }

    /// Whether jamf-cli has no profile named `name` yet. Asked right before a command that adds
    /// one, so Start over never removes a profile that was there before setup. A listing that
    /// cannot be read is not "no profiles": the profile is then not new, and is left alone.
    func isNewProfile(_ name: String) async -> Bool {
        let lister = profileLister
        return await Task.detached(priority: .userInitiated) {
            guard let existing = lister() else { return false }
            return !existing.contains(name)
        }.value
    }

    func noteCreatedProfile(_ name: String) {
        if !createdProfiles.contains(name) { createdProfiles.append(name) }
    }

    /// Every profile jamf-cli has, unusable ones included; nil when neither `config list` nor
    /// jamf-cli's config file could be read.
    nonisolated static func listJamfCLIProfiles() -> Set<String>? {
        ProfileService.listJamfCLIProfiles(scheduleCounts: [:]).map { Set($0.map(\.name)) }
    }

    nonisolated static func removeProfileArguments(name: String) -> [String] {
        ["config", "remove-profile", "--", name]
    }

    /// `jamf-cli config remove-profile`, which also deletes the profile's keychain items.
    nonisolated static func removeJamfCLIProfile(_ name: String) async -> String? {
        let manual = L("Remove it in Terminal: jamf-cli config remove-profile -- ")
            + ProfileName.shellWord(name)
        guard let binary = ExecutableLocator.locate("jamf-cli") else {
            return L("jamf-cli was not found, so the profile \(name) was not removed. \(manual)")
        }
        if CLIBridge.codesignGate(executable: binary, onLine: CLIBridge.noOpOnLine) != nil {
            return L("jamf-cli failed its signature check, so the profile \(name) was not removed. \(manual)")
        }
        let outcome = await JamfCLIProbe.runOutcomeAsync(
            executable: binary, arguments: removeProfileArguments(name: name))
        switch outcome {
        case .completed(let output) where output.exitCode == 0:
            return nil
        case .completed(let output):
            return L("jamf-cli could not remove the profile \(name) (exit \(output.exitCode)). \(manual)")
        case .timedOut:
            return L("jamf-cli did not finish removing the profile \(name). \(manual)")
        case .launchFailed:
            return L("jamf-cli could not be started to remove the profile \(name). \(manual)")
        }
    }
}
