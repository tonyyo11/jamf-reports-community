import Foundation

/// Checks the Platform API fields `school setup` wrote onto a Jamf School profile, with the one
/// read they serve: `school blueprints list`. jamf-cli validates none of them when it saves.
enum SchoolPlatformCheck {

    typealias Runner = ConnectionCheck.Runner

    enum Verdict: Equatable, Sendable {
        /// The gateway answered; `blueprints` is how many it listed, nil when unreadable.
        case accepted(blueprints: Int?)
        /// The integration lacks `blueprints:read`.
        case missingPermission
        /// The gateway refused the tenant ID. The School API key still works.
        case rejectedTenant
        /// The check could not tell, and why.
        case undecided(reason: String)
    }

    static let permission = "blueprints:read"

    /// Shown on the switch and the Data Sources row.
    static let experimentalNote = L("Experimental: Jamf School blueprints through the Platform API; report results on GitHub.")

    static func arguments(profile: String) -> [String] {
        ["-p", profile, "--no-input", "school", "blueprints", "list", "--output", "json"]
    }

    static func verdict(_ attempt: ConnectionCheck.Attempt?, profile: String? = nil) -> Verdict {
        guard let attempt else { return .undecided(reason: "jamf-cli did not start") }
        if attempt.exitCode == CLIBridge.exitCodeTimedOut {
            return .undecided(reason: L("no answer within \(Int(ConnectionCheck.timeout)) seconds"))
        }
        if attempt.exitCode == 0 {
            let list = ReportEngine.jsonPayload(from: attempt.stdout)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [Any]
            return .accepted(blueprints: list?.count)
        }
        let cause = FailureCause.classify(exitCode: attempt.exitCode, stdout: attempt.stdout)
        switch cause.kind {
        case .scopeRejected, .unknownEnvironment: return .rejectedTenant
        case .missingPermission: return .missingPermission
        default:
            let message = JamfCLIErrorEnvelope.parse(attempt.stdout)?.message
            // The message is jamf-cli's own text and reaches the UI and the setup note.
            let shown = message.map {
                String(LogRedactor.redactedForSharing($0, profile: profile).prefix(200))
            }
            return .undecided(reason: shown.map { L("exit \(attempt.exitCode): \($0)") }
                ?? L("exit \(attempt.exitCode)"))
        }
    }

    static func run(profile: String, runner: Runner) async -> Verdict {
        verdict(await runner(arguments(profile: profile)), profile: profile)
    }
}

extension SchoolPlatformCheck.Verdict {
    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .accepted(let count):
            return L("The Platform API answered: ")
                + (count.map { ($0 == 1 ? L("\($0) blueprint") : L("\($0) blueprints")) } ?? "blueprints")
                + L(" listed.")
        case .missingPermission:
            return L("The gateway accepted the tenant ID, but the integration lacks \(SchoolPlatformCheck.permission). Grant it on the integration in Jamf Account.")
        case .rejectedTenant:
            return L("The Jamf Account gateway does not accept this tenant ID. The profile was kept and the Jamf School API still works; correct the Platform API fields with Update.")
        case .undecided(let reason):
            return L("The Platform API check could not tell (\(reason)). The Jamf School API still works.")
        }
    }
}

/// The Data Sources row for a Jamf School workspace's Platform API fields. Configured means the
/// profile carries a tenant ID in `config list`; the ID itself is never shown.
enum SchoolPlatformRow: Equatable, Sendable {
    /// `config list` could not be read for the profile.
    case unknown
    case notConfigured
    case configured
    /// Configured, and the last check this session was refused by the gateway.
    case rejected

    static func state(
        resolved: ProfileAuthMethod.Resolved?, lastCheck: SchoolPlatformCheck.Verdict?
    ) -> SchoolPlatformRow {
        guard let resolved else { return .unknown }
        guard resolved.isTenantLevel else { return .notConfigured }
        return lastCheck == .rejectedTenant ? .rejected : .configured
    }

    var label: String {
        switch self {
        case .unknown: L("Platform API: could not read the jamf-cli profile")
        case .notConfigured: L("Platform API: not configured")
        case .configured: L("Platform API: configured")
        case .rejected: L("Platform API fields rejected")
        }
    }

    var actionTitle: String {
        switch self {
        case .unknown, .notConfigured: L("Add\u{2026}")
        case .configured, .rejected: L("Update\u{2026}")
        }
    }

    /// Whether Update credentials opens with the Platform API switch on.
    var hasFields: Bool { self == .configured || self == .rejected }
}
