import Foundation

extension OnboardingFlow {
    /// Registers one Platform API profile with `jamf-cli config add-profile`: the credentials go
    /// in over the PTY's stdin, the stdin bytes are wiped when the call ends, and a failure's
    /// output is redacted of the secret and client ID. Onboarding, Update credentials and
    /// Add environments all register through this; the caller runs `signatureGate` first and
    /// clears its own copy of the secret. `config add-profile` overwrites an existing profile
    /// of the same name.
    static func registerPlatformProfile(
        binary: URL, profile: String, gatewayURL: String, scope: PlatformScope, scopeID: String,
        clientID: String, clientSecret: String, noVerify: Bool
    ) async throws {
        var stdinData = platformGatewayStdin(clientID: clientID, clientSecret: clientSecret)
        defer { stdinData.resetBytes(in: 0..<stdinData.count) }

        let result = try await runWithPTY(
            executable: binary,
            arguments: platformGatewayArguments(
                profile: profile, gatewayURL: gatewayURL, scope: scope, scopeID: scopeID,
                noVerify: noVerify),
            stdin: stdinData
        )
        guard result.exitCode == 0 else {
            let redacted = redactedPlatformOutput(
                result.combined.trimmed, clientID: clientID, clientSecret: clientSecret)
            throw FlowError.processFailed(
                redacted.isEmpty ? "jamf-cli exited \(result.exitCode)." : redacted)
        }
    }

    nonisolated static func redactedPlatformOutput(
        _ text: String, clientID: String, clientSecret: String
    ) -> String {
        var redacted = text
        if !clientSecret.isEmpty {
            redacted = redacted.replacingOccurrences(of: clientSecret, with: "[redacted]")
        }
        if clientID.count >= 8 {
            redacted = redacted.replacingOccurrences(of: clientID, with: "[redacted]")
        }
        return redacted
    }

    /// A workspace for a profile that has no CSV: the folders and the minimal config.yaml the
    /// "skip CSV mapping" step writes, confirmed on this Mac as onboarding confirms it. A
    /// config.yaml already there is kept as it is. Returns whether it wrote one.
    @discardableResult
    static func createJamfCLIOnlyWorkspace(for profile: String) throws -> Bool {
        try createWorkspaceFolders(for: profile)
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            throw FlowError.invalidProfile
        }
        let config = workspace.appendingPathComponent("config.yaml")
        guard !FileManager.default.fileExists(atPath: config.path) else { return false }
        try ScaffoldService.writeMinimalConfig(to: config, profile: profile)
        SharedConfigPin.confirmWrittenConfig(at: config, profile: profile)
        return true
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
