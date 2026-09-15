import Foundation

/// Checks a Jamf Platform API profile's environment or tenant ID when it validates (spec
/// 2026-09-12 §10.4). `config validate` cannot: the gateway issues a token before it reads the
/// scope header. Same probe as jamf-cli's own `platform setup`.
enum ConnectionCheck {

    typealias Attempt = (exitCode: Int32, stdout: Data)
    /// Runs jamf-cli with these arguments; nil when the process never launched.
    typealias Runner = @Sendable ([String]) async -> Attempt?

    enum Verdict: Equatable, Sendable {
        /// Jamf Pro answered through the gateway in this environment.
        case accepted(jamfProVersion: String?)
        /// The gateway refused the ID; setup must not continue with it.
        case rejectedID(FailureCause.Kind)
        /// The gateway recognised the ID, but no Jamf Pro answered for it.
        case noJamfPro
        /// The check could not tell.
        case undecided(exitCode: Int32?)
    }

    /// Needs no permission. jamf-cli 1.29 renamed `jamf-pro-versions` to `jamf-pro-version`;
    /// the old name warns until 2027-03-09 and the new one exits 2 before 1.29.
    static func versionArguments(profile: String, specNames: Bool) -> [String] {
        ["-p", profile, "pro", specNames ? "jamf-pro-version" : "jamf-pro-versions", "list",
         "--output", "json"]
    }

    /// A Platform call that matches nothing and returns one empty page.
    static func probeArguments(profile: String) -> [String] {
        ["-p", profile, "pro", "platform-devices", "list",
         "--filter", #"serialNumber=="jrc-connection-check""#, "--output", "json"]
    }

    /// Step 2 runs only after a 404 that names no cause.
    static func needsProbe(_ version: Attempt?) -> Bool {
        guard let version, version.exitCode == CLIBridge.exitCodeNotFound else { return false }
        return FailureCause.classify(exitCode: version.exitCode, stdout: version.stdout).kind
            == .other
    }

    static func verdict(version: Attempt?, probe: Attempt?) -> Verdict {
        guard let version else { return .undecided(exitCode: nil) }
        if version.exitCode == 0 {
            return .accepted(jamfProVersion: jamfProVersion(in: version.stdout))
        }
        let first = FailureCause.classify(exitCode: version.exitCode, stdout: version.stdout)
        if first.kind == .scopeRejected || first.kind == .unknownEnvironment {
            return .rejectedID(first.kind)
        }
        guard needsProbe(version) else { return .undecided(exitCode: version.exitCode) }
        guard let probe else { return .undecided(exitCode: nil) }
        if probe.exitCode == 0 { return .noJamfPro }
        let second = FailureCause.classify(exitCode: probe.exitCode, stdout: probe.stdout)
        switch second.kind {
        case .scopeRejected, .unknownEnvironment: return .rejectedID(second.kind)
        case .missingPermission: return .noJamfPro
        case .edgeBlocked, .notServed, .other:
            return namesNoTenant(probe.stdout) ? .noJamfPro : .undecided(exitCode: probe.exitCode)
        }
    }

    /// `404 TENANT_NOT_FOUND`: the environment exists but holds no tenant. `devices` returns it
    /// even for an environment the integration does not own, so it does not prove ownership.
    private static func namesNoTenant(_ stdout: Data) -> Bool {
        JamfCLIErrorEnvelope.parse(stdout)?.message?.contains("TENANT_NOT_FOUND") == true
    }

    static func run(profile: String, specNames: Bool, runner: Runner) async -> Verdict {
        let version = await runner(versionArguments(profile: profile, specNames: specNames))
        var probe: Attempt?
        if needsProbe(version) {
            probe = await runner(probeArguments(profile: profile))
        }
        return verdict(version: version, probe: probe)
    }

    /// `{"version": "11.25.0"}`, or an array holding that object.
    static func jamfProVersion(in stdout: Data) -> String? {
        guard let payload = ReportEngine.jsonPayload(from: stdout),
              let object = try? JSONSerialization.jsonObject(with: payload) else { return nil }
        let fields = (object as? [[String: Any]])?.first ?? (object as? [String: Any])
        guard let version = fields?["version"] as? String, !version.isEmpty else { return nil }
        return version
    }

    /// jamf-cli on PATH with the app's child environment; nil when it is not installed.
    static func liveRunner() -> Runner? {
        guard let binary = ExecutableLocator.locate("jamf-cli") else { return nil }
        return { arguments in
            guard let (exitCode, stdout) = try? await CLIBridge().runAndCapture(
                executable: binary, arguments: arguments,
                environment: CLIBridge.environmentForJamfCLI(), onLine: CLIBridge.noOpOnLine
            ) else { return nil }
            return (exitCode: exitCode, stdout: stdout)
        }
    }
}

extension ConnectionCheck.Verdict {
    var blocksContinue: Bool {
        if case .rejectedID = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .accepted(let version):
            return "Jamf Pro " + (version.map { "\($0) " } ?? "")
                + "answered through the Jamf Platform API in this environment."
        case .rejectedID(.unknownEnvironment):
            return "The gateway does not recognise this environment ID. Copy the platform "
                + "environment ID from Jamf Account: open the integration and click the "
                + "environment pill in Integration details. A tenant ID or client ID here is "
                + "rejected."
        case .rejectedID:
            return "The integration's scope level does not match this ID. An environment-level "
                + "integration needs its environment ID, and a tenant-level (legacy) integration "
                + "its tenant ID. Correct the scope level or the ID, then save again."
        case .noJamfPro:
            return "The gateway recognises this ID, but no Jamf Pro server answered for it. Jamf "
                + "Pro screens stay empty unless the ID is for the environment that holds your "
                + "Jamf Pro tenant."
        case .undecided(let exitCode):
            return "The connection check could not confirm the ID"
                + (exitCode.map { " (exit \($0))" } ?? "")
                + ". You can continue; if screens stay empty after the first collect, check the "
                + "ID with Update credentials in Data Sources."
        }
    }
}
