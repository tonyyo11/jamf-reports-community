import Foundation
import Synchronization

/// jamf-cli's JSON error envelope. With `--output json` a failing command writes it to stdout
/// (`formatErrorTo`); `--no-hints` does not remove `hint`.
struct JamfCLIErrorEnvelope: Decodable, Equatable, Sendable {
    let error: String?
    let message: String?
    let hint: String?

    static func parse(_ data: Data) -> JamfCLIErrorEnvelope? {
        guard let payload = ReportEngine.jsonPayload(from: data) else { return nil }
        return try? JSONDecoder().decode(JamfCLIErrorEnvelope.self, from: payload)
    }
}

/// Why one jamf-cli call failed (spec 2026-09-12 §9.2; first matching rule wins).
struct FailureCause: Codable, Equatable, Sendable {

    enum Kind: String, Codable, Sendable {
        /// Rule 1: the integration's scope level or ID does not match what was sent, no scope
        /// ID was sent, or the endpoint accepts another level than the one sent
        /// (`INVALID_REQUEST_CONTEXT_TYPE`).
        case scopeRejected
        /// Rule 2: the gateway does not know the environment ID.
        case unknownEnvironment
        /// Rule 3: blocked at the Jamf gateway edge; jamf-cli advises one cold retry.
        case edgeBlocked
        /// Rule 4: the command is outside what this connection's API serves.
        case notServed
        /// Rules 5–7: a missing permission or privilege.
        case missingPermission
        /// `pro report ddm-status` found no declaration data. jamf-cli skips refused device
        /// reports silently, so the environment has none or the permission is missing.
        case noDeclarationData
        /// `pro report update-status` found Managed Software Update Plans turned off in Jamf
        /// Pro: the plans endpoint answers 503 and jamf-cli exits 0 with no data.
        case softwareUpdatePlansOff
        /// `platform.compliance_benchmarks` lists titles and none of them can be collected: the
        /// tenant lists none of them, or each one is shared by two benchmarks or starts with
        /// "-". `names` holds the configured titles. Recorded by collect, never classified.
        case noConfiguredBenchmark
        /// The profile's URL is the retired `apigw.jamf.com` gateway, which jamf-cli refuses by
        /// name (exit 2) before sending a request.
        case retiredGateway
        /// The login keychain is locked (or unreachable in this session, such as over SSH or
        /// before login), so jamf-cli could not read the profile's `keychain:` credentials.
        case keychainLocked
        /// Rule 8: anything else; the exit-code handling that existed before applies.
        case other
    }

    let kind: Kind
    /// Permission or privilege names parsed from the hint; empty when it names none.
    let names: [String]
    /// jamf-cli's hint, capped at `hintByteLimit`.
    let hint: String?
    let exitCode: Int32
    /// When the failure was recorded; set by `StateFileStore`.
    var recordedAt: Date? = nil

    static let hintByteLimit = 4_096
    /// What jamf-cli prints on stderr when a command swallows a 403 and exits 0.
    static let forbiddenStderrMarker = "permission denied (HTTP 403)"
    /// `pro report blueprint-status` prints this and exits 0 when the environment has none.
    static let noBlueprintsStderrMarker = "No blueprints found."
    /// `pro report update-status` prints this and exits 0 when Jamf Pro returned no update
    /// statuses and no plans: a real empty answer unless a fetch warning came first.
    static let noUpdateDataStderrMarker = "No managed software update data found."
    /// What `pro report update-status` prints when one of its two fetches fails.
    static let updateFetchWarningStderrMarker = "WARNING: failed to fetch"
    /// `pro report ddm-status` prints this and exits 0 when no declaration report came back.
    static let noDeclarationDataStderrMarker = "No DDM declaration data found."
    /// Jamf Pro's 503 body, which `pro report update-status` prints in a warning before it
    /// exits 0 with no data.
    static let softwareUpdatePlansOffStderrMarker = "Managed Software Update Plans toggle is off"
    /// jamf-cli's refusal of `apigw.jamf.com` (`refuseRetiredGatewayURL`, exit 2), which it makes
    /// before any request: "<url> is the retired Jamf Platform gateway and does not serve ...".
    static let retiredGatewayMarker = "is the retired Jamf Platform gateway"
    static let retiredGatewayHint = "Re-run setup with the us, eu or apac api.jamfcloud.com host "
        + "(jamf-cli platform setup --profile-name <profile>), or set url: in the profile."
    /// The gateway's 400 when a command is sent at a scope level it does not accept; its message
    /// names both levels.
    static let invalidContextTypeMarker = "INVALID_REQUEST_CONTEXT_TYPE"
    static let invalidContextTypeHint = "This command accepts a different scope level than this "
        + "profile's integration; the error names both. An environment-level integration is the "
        + "level Jamf recommends, and a tenant-level one cannot reach every command."

    /// jamf-cli reports an unreadable `keychain:` credential as
    /// "reading keychain item <service>/<account>: <error>".
    /// errSecInteractionNotAllowed, which a locked keychain gives when nothing can prompt: the
    /// Security framework's text, or the `security` exit status go-keyring reports (jamf-cli
    /// 1.31 and earlier).
    static let keychainInteractionMarkers = ["User interaction is not allowed", "exit status 36"]
    /// jamf-cli's own wording when the login keychain refuses a write.
    static let keychainRejectedWriteMarker = "login keychain rejected"
    static let keychainLockedHint = "Unlock the login keychain (open Keychain Access, or run "
        + "`security unlock-keychain`), then try again"

    /// True for jamf-cli text that says it could not read credentials because the login
    /// keychain is locked. A missing item ("keychain item not found") is not a lock.
    static func mentionsLockedKeychain(_ text: String) -> Bool {
        if text.contains(keychainRejectedWriteMarker) { return true }
        guard text.contains("keychain") else { return false }
        return keychainInteractionMarkers.contains { text.contains($0) }
    }

    /// Retrying within the hour cannot help (spec §9.5): the credential, its scope ID, its
    /// permissions, the environment's data or the config has to change first. Edge blocks stay
    /// retryable.
    var isPermanent: Bool {
        switch kind {
        case .scopeRejected, .unknownEnvironment, .notServed, .missingPermission,
             .noDeclarationData, .softwareUpdatePlansOff, .noConfiguredBenchmark,
             .retiredGateway: true
        case .edgeBlocked, .keychainLocked, .other: false
        }
    }

    /// Plain-language cause for log lines and the health banner.
    var label: String {
        switch kind {
        case .scopeRejected: "the gateway rejected the integration's scope level or ID"
        case .unknownEnvironment: "the gateway does not recognise the environment ID"
        case .edgeBlocked: "blocked at the Jamf gateway edge"
        case .retiredGateway: "the profile uses the retired apigw.jamf.com gateway host"
        case .notServed: "not served through this connection"
        case .keychainLocked:
            "the login keychain is locked, so jamf-cli could not read this profile's stored "
                + "credentials"
        case .missingPermission:
            names.isEmpty
                ? "missing permission"
                : "missing permission: " + names.joined(separator: "; ")
        case .noDeclarationData:
            "no DDM declaration data: the environment has none, or each device's report was "
                + "refused (Deployment > Declarations reporting)"
        case .softwareUpdatePlansOff:
            "Managed Software Update Plans is turned off in Jamf Pro; turn it on, or add this "
                + "source to jamf_cli.collect_skip"
        case .noConfiguredBenchmark:
            names.isEmpty
                ? "no benchmark in platform.compliance_benchmarks can be collected"
                : "no benchmark in platform.compliance_benchmarks can be collected: "
                    + names.joined(separator: "; ")
        case .other:
            exitCode == CLIBridge.exitCodeTimedOut
                ? "timed out and was stopped" : "exit \(exitCode)"
        }
    }

    static func classify(
        exitCode: Int32, stdout: Data, sawForbiddenOnStderr: Bool = false,
        sawNoDeclarationDataOnStderr: Bool = false, sawSoftwareUpdatePlansOffOnStderr: Bool = false,
        sawKeychainLockedOnStderr: Bool = false
    ) -> FailureCause {
        let envelope = JamfCLIErrorEnvelope.parse(stdout)
        let message = envelope?.message ?? ""
        let hint = envelope?.hint ?? ""
        let cappedHint = hint.isEmpty
            ? nil
            : String(decoding: hint.utf8.prefix(hintByteLimit), as: UTF8.self)
        func cause(
            _ kind: Kind, _ names: [String] = [], hintOverride: String? = nil
        ) -> FailureCause {
            FailureCause(
                kind: kind, names: names, hint: cappedHint ?? hintOverride, exitCode: exitCode)
        }
        // First: this failure comes before any request, so its text carries no HTTP code for the
        // rules below; checked last it would fall through to `.other`.
        if sawKeychainLockedOnStderr || mentionsLockedKeychain(message + "\n" + hint) {
            // Our hint, not jamf-cli's: the fix is the same whatever it suggested.
            return FailureCause(kind: .keychainLocked, names: [], hint: keychainLockedHint,
                                exitCode: exitCode)
        }
        if message.contains(retiredGatewayMarker) {
            return cause(.retiredGateway, hintOverride: retiredGatewayHint)
        }
        if message.contains(invalidContextTypeMarker) {
            return cause(.scopeRejected, hintOverride: invalidContextTypeHint)
        }
        if message.contains("OWNERSHIP_FORBIDDEN")
            || message.contains("REQUEST_CONTEXT_NOT_PROVIDED")
            || hint.hasPrefix("The credential's scope level does not match") {
            return cause(.scopeRejected)
        }
        if message.contains("ENVIRONMENT_NOT_FOUND") { return cause(.unknownEnvironment) }
        if message.hasPrefix("request blocked at the Jamf gateway edge") {
            return cause(.edgeBlocked)
        }
        if hint.contains("does not serve this endpoint")
            || hint.contains("not part of the Jamf Platform gateway's published API")
            || exitCode == CLIBridge.exitCodeRefusedByPolicy {
            return cause(.notServed)
        }
        if exitCode == CLIBridge.exitCodePermissionDenied {
            if hint.contains("Jamf Platform API integration") {
                return cause(.missingPermission, gatewayPermissionNames(in: hint))
            }
            if hint.contains("Required privilege(s):") {
                return cause(.missingPermission, privilegeNames(in: hint))
            }
            return cause(.missingPermission)
        }
        guard exitCode == 0 else { return cause(.other) }
        if sawForbiddenOnStderr { return cause(.missingPermission) }
        if sawSoftwareUpdatePlansOffOnStderr { return cause(.softwareUpdatePlansOff) }
        return cause(sawNoDeclarationDataOnStderr ? .noDeclarationData : .other)
    }

    /// A section jamf-cli 1.29 could not fetch (`fetch_error`) in a document it exited 0 on.
    static func fetchError(_ text: String, exitCode: Int32) -> FailureCause {
        FailureCause(
            kind: text.contains(forbiddenStderrMarker) ? .missingPermission : .other,
            names: [], hint: String(decoding: text.utf8.prefix(hintByteLimit), as: UTF8.self),
            exitCode: exitCode)
    }

    /// Gateway hints name permissions between `in Jamf Account: ` and `. Names are`,
    /// separated by `; ` (jamf-cli `privileges.Hint`).
    static func gatewayPermissionNames(in hint: String) -> [String] {
        guard let start = hint.range(of: "in Jamf Account: "),
              let end = hint.range(of: ". Names are", range: start.upperBound..<hint.endIndex)
        else { return [] }
        return hint[start.upperBound..<end.lowerBound]
            .components(separatedBy: "; ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Jamf Pro hints name privileges after `Required privilege(s): `, separated by `, `,
    /// to the end of that line (jamf-cli `EnrichPrivilegeError`).
    static func privilegeNames(in hint: String) -> [String] {
        guard let start = hint.range(of: "Required privilege(s): ") else { return [] }
        return hint[start.upperBound...]
            .prefix { $0 != "\n" }
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) }
            .filter { !$0.isEmpty }
    }
}

/// Watches one kind's streamed stderr for the jamf-cli lines that explain an exit 0 without
/// data (spec §9.1): a swallowed 403, an empty blueprint listing, no declaration data,
/// Managed Software Update Plans turned off, or no managed software update data.
final class StderrSignalWatcher: Sendable {
    private struct Flags {
        var forbidden = false
        var noBlueprints = false
        var noDeclarationData = false
        var softwareUpdatePlansOff = false
        var noUpdateData = false
        var updateFetchWarning = false
        var keychainLocked = false
    }
    private let flags = Mutex(Flags())

    var sawKeychainLocked: Bool { flags.withLock { $0.keychainLocked } }
    var sawForbidden: Bool { flags.withLock { $0.forbidden } }
    var sawNoBlueprints: Bool { flags.withLock { $0.noBlueprints } }
    var sawNoDeclarationData: Bool { flags.withLock { $0.noDeclarationData } }
    var sawSoftwareUpdatePlansOff: Bool { flags.withLock { $0.softwareUpdatePlansOff } }
    /// jamf-cli's "no update data" line with no fetch warning before or after it.
    var sawNoUpdateData: Bool { flags.withLock { $0.noUpdateData && !$0.updateFetchWarning } }

    /// A retried attempt is classified on its own stderr, not the first attempt's.
    func reset() {
        flags.withLock { $0 = Flags() }
    }

    func forwarding(
        to onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) -> @Sendable (CLIBridge.LogLine) -> Void {
        { line in
            let text = line.text
            self.flags.withLock { flags in
                if text.contains(FailureCause.forbiddenStderrMarker) { flags.forbidden = true }
                if text.contains(FailureCause.noBlueprintsStderrMarker) {
                    flags.noBlueprints = true
                }
                if text.contains(FailureCause.noDeclarationDataStderrMarker) {
                    flags.noDeclarationData = true
                }
                if text.contains(FailureCause.softwareUpdatePlansOffStderrMarker) {
                    flags.softwareUpdatePlansOff = true
                }
                if text.contains(FailureCause.noUpdateDataStderrMarker) {
                    flags.noUpdateData = true
                }
                if text.contains(FailureCause.updateFetchWarningStderrMarker) {
                    flags.updateFetchWarning = true
                }
                if FailureCause.mentionsLockedKeychain(text) { flags.keychainLocked = true }
            }
            onLine(line)
        }
    }
}
