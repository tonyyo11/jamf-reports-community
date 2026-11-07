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
        clientID: String, clientSecret: Data
    ) async throws {
        var stdinData = platformGatewayStdin(clientID: clientID, clientSecret: clientSecret)
        defer { stdinData.resetBytes(in: 0..<stdinData.count) }

        let result = try await runWithPTY(
            executable: binary,
            arguments: platformGatewayArguments(
                profile: profile, gatewayURL: gatewayURL, scope: scope, scopeID: scopeID),
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
        _ text: String, clientID: String, clientSecret: Data
    ) -> String {
        var redacted = redacting(clientSecret, in: text)
        if clientID.count >= 8 {
            redacted = redacted.replacingOccurrences(of: clientID, with: "[redacted]")
        }
        return redacted
    }

    /// `text` with every occurrence of the secret's bytes replaced, matched as UTF-8 so the
    /// secret never becomes a String.
    nonisolated static func redacting(_ secret: Data, in text: String) -> String {
        guard !secret.isEmpty else { return text }
        var bytes = Data(text.utf8)
        let mark = Data("[redacted]".utf8)
        var start = bytes.startIndex
        while let found = bytes.range(of: secret, in: start..<bytes.endIndex) {
            bytes.replaceSubrange(found, with: mark)
            start = found.lowerBound + mark.count
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A workspace for a profile: the folders and the minimal config.yaml, confirmed on this Mac
    /// as onboarding confirms it. A config.yaml already there is kept as it is. Returns whether
    /// it wrote one.
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

    /// A Protect-only environment (P8): the workspace folder named after the login, the minimal
    /// config.yaml and `profiles: {protect: <login>}` with no MDM slot, all confirmed on this
    /// Mac. A config.yaml already there is never overwritten.
    static func createProtectOnlyEnvironment(
        login: String, appSupport: URL = AppSupport.directory()
    ) throws {
        guard try createJamfCLIOnlyWorkspace(for: login) else {
            throw FlowError.workspaceHasConfig(login)
        }
        _ = try ConfigService.saveBlock(key: "profiles", profile: login) {
            var block = YAMLCodec.YAMLMapping(entries: [])
            block.set(
                ProfilesConfigWriter.Slot.protect.rawValue, value: .scalar(.string(login)))
            $0.set("profiles", value: .mapping(block))
        }
        SharedConfigPin.confirmWritten(
            login, key: .protectProfile, profile: login, appSupport: appSupport)
    }
}

extension Data {
    /// Zeroes the bytes in place, then empties the value. In place only while this is the one
    /// reference to the buffer (a shared buffer is copied first, leaving the other holder's
    /// bytes), so a secret is never copied into a second stored value.
    mutating func wipe() {
        resetBytes(in: startIndex..<endIndex)
        self = Data()
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
