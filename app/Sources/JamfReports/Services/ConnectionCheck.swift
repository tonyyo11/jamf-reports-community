import Foundation

/// Checks a Jamf Platform API profile's environment or tenant ID when it validates (spec
/// 2026-09-12 §10.4). `config validate` cannot: the gateway issues a token before it reads the
/// scope header. Same probe as jamf-cli's own `platform setup`.
enum ConnectionCheck {

    typealias Attempt = (exitCode: Int32, stdout: Data)
    /// Runs jamf-cli with these arguments; nil when the process never launched. A call that
    /// timed out reports `CLIBridge.exitCodeTimedOut`, whatever output it left.
    typealias Runner = @Sendable ([String]) async -> Attempt?

    enum Verdict: Equatable, Sendable {
        /// Jamf Pro answered through the gateway in this environment.
        case accepted(jamfProVersion: String?)
        /// The gateway refused the ID; setup must not continue with it.
        case rejectedID(FailureCause.Kind)
        /// The gateway recognised the ID, but no Jamf Pro answered for it.
        case noJamfPro
        /// The gateway did not reject the ID, but the integration lacks a permission the check
        /// needs (a plain HTTP 403, not `OWNERSHIP_FORBIDDEN`). `names` holds what jamf-cli's
        /// hint names, empty when it names none.
        case missingPermission(names: [String])
        /// The check could not tell.
        case undecided(exitCode: Int32?)
    }

    /// Needs no permission.
    static func versionArguments(profile: String) -> [String] {
        ["-p", profile, "pro", "jamf-pro-version", "list", "--output", "json"]
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
        // Output cut off by the timeout can hold a refusal; a call that never finished decided
        // nothing, so it must not block setup as a rejected ID.
        if version.exitCode == CLIBridge.exitCodeTimedOut {
            return .undecided(exitCode: version.exitCode)
        }
        if version.exitCode == 0 {
            return .accepted(jamfProVersion: jamfProVersion(in: version.stdout))
        }
        let first = FailureCause.classify(exitCode: version.exitCode, stdout: version.stdout)
        if first.kind == .scopeRejected || first.kind == .unknownEnvironment {
            return .rejectedID(first.kind)
        }
        if first.kind == .missingPermission { return .missingPermission(names: first.names) }
        guard needsProbe(version) else { return .undecided(exitCode: version.exitCode) }
        guard let probe else { return .undecided(exitCode: nil) }
        if probe.exitCode == CLIBridge.exitCodeTimedOut {
            return .undecided(exitCode: probe.exitCode)
        }
        if probe.exitCode == 0 { return .noJamfPro }
        let second = FailureCause.classify(exitCode: probe.exitCode, stdout: probe.stdout)
        switch second.kind {
        case .scopeRejected, .unknownEnvironment: return .rejectedID(second.kind)
        // The version call answered 404 and the gateway resolved the scope for this one (it
        // checks scope before capability), so the ID is known and holds no Jamf Pro.
        case .missingPermission: return .noJamfPro
        case .edgeBlocked, .notServed, .noDeclarationData, .softwareUpdatePlansOff,
             .noConfiguredBenchmark, .retiredGateway, .keychainLocked, .other:
            return namesNoTenant(probe.stdout) ? .noJamfPro : .undecided(exitCode: probe.exitCode)
        }
    }

    /// `404 TENANT_NOT_FOUND`: the environment exists but holds no tenant. `devices` returns it
    /// even for an environment the integration does not own, so it does not prove ownership.
    private static func namesNoTenant(_ stdout: Data) -> Bool {
        JamfCLIErrorEnvelope.parse(stdout)?.message?.contains("TENANT_NOT_FOUND") == true
    }

    static func run(profile: String, runner: Runner) async -> Verdict {
        let version = await runner(versionArguments(profile: profile))
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
        return runner(binary: binary)
    }

    /// Seconds each of the check's two calls may run. A server that accepts the connection and
    /// never answers would otherwise leave Validate spinning with no way out.
    static let timeout: TimeInterval = 60

    static func runner(binary: URL, timeout: TimeInterval = ConnectionCheck.timeout) -> Runner {
        { arguments in
            guard let (exitCode, stdout) = try? await CLIBridge().runAndCapture(
                executable: binary, arguments: arguments,
                environment: CLIBridge.environmentForJamfCLI(), timeout: timeout,
                onLine: CLIBridge.noOpOnLine
            ) else { return nil }
            return (exitCode: exitCode, stdout: stdout)
        }
    }
}

extension ConnectionCheck.Verdict {
    /// The verdict that points the user at a Jamf School workspace instead.
    var suggestsJamfSchool: Bool {
        if case .noJamfPro = self { return true }
        return false
    }

    /// At tenant level (legacy) a tenant that is not Jamf Pro can be Jamf School, Jamf Protect
    /// or Jamf Security Cloud; an environment's MDM is Jamf Pro or Jamf School, so it is School.
    static let notJamfProTenantText = "The gateway recognises this tenant ID, but it is not a "
        + "Jamf Pro tenant. If it is Jamf School, set it up as a Jamf School workspace (Settings › "
        + "Add connection, then Jamf School). If it is Jamf Protect or Jamf "
        + "Security Cloud, Jamf Reports cannot report from it on its own: Jamf Protect is added "
        + "to a Jamf Pro or Jamf School workspace (Data Sources › Add Jamf Protect), and Jamf "
        + "Security Cloud is not supported yet."

    /// What the verdict says without its advice on continuing, for a list of results.
    static func missingPermissionText(names: [String]) -> String {
        // The version request itself needs no permission, and the gateway answers the same 403
        // for a path it does not route, so a refusal is about the integration or the environment
        // as a whole, not about one permission the check needs.
        if !names.isEmpty {
            return "The gateway did not reject this ID, but the integration lacks a permission ("
                + names.joined(separator: "; ") + "). Grant it on the integration in Jamf "
                + "Account, or on the API role for a Jamf Pro privilege."
        }
        return "The gateway did not reject this ID but refused the request. Either the "
            + "integration holds no Jamf Pro permission for this environment, or no Jamf Pro "
            + "answers behind it. Grant the Jamf Pro permissions Jamf Reports reads on the "
            + "integration in Jamf Account, and check that the ID is for the environment that "
            + "holds your Jamf Pro tenant."
    }

    var message: String { message(tenantLevel: false) }

    func message(tenantLevel: Bool) -> String {
        if tenantLevel, case .noJamfPro = self { return Self.notJamfProTenantText }
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
            return "The gateway recognises this ID, but no Jamf Pro server answers for it. This "
                + "environment's MDM is probably Jamf School. Jamf Reports reads Jamf School with "
                + "a School API key, so set it up as a Jamf School workspace (Settings › Add "
                + "connection, then Jamf School). If it should be Jamf Pro, check "
                + "that the ID is for the environment that holds your Jamf Pro tenant."
        case .missingPermission(let names):
            return Self.missingPermissionText(names: names)
                + " You can continue; data that needs the permission will not collect until it "
                + "is granted."
        case .undecided(let exitCode):
            let cause = exitCode == CLIBridge.exitCodeTimedOut
                ? " (no answer within \(Int(ConnectionCheck.timeout)) seconds)"
                : exitCode.map { " (exit \($0))" } ?? ""
            return "The connection check could not confirm the ID" + cause
                + ". You can continue; if screens stay empty after the first collect, check the "
                + "ID with Update credentials in Data Sources."
        }
    }
}
