import Foundation

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
        /// Rule 1: the integration's scope level or ID does not match what was sent, or no scope
        /// ID was sent.
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
        /// `platform.compliance_benchmarks` lists titles and none of them can be collected: the
        /// tenant lists none of them, or each one is shared by two benchmarks or starts with
        /// "-". `names` holds the configured titles. Recorded by collect, never classified.
        case noConfiguredBenchmark
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
    /// `pro report ddm-status` prints this and exits 0 when no declaration report came back.
    static let noDeclarationDataStderrMarker = "No DDM declaration data found."

    /// Retrying within the hour cannot help (spec §9.5): the credential, its scope ID, its
    /// permissions, the environment's data or the config has to change first. Edge blocks stay
    /// retryable.
    var isPermanent: Bool {
        switch kind {
        case .scopeRejected, .unknownEnvironment, .notServed, .missingPermission,
             .noDeclarationData, .noConfiguredBenchmark: true
        case .edgeBlocked, .other: false
        }
    }

    /// Plain-language cause for log lines and the health banner.
    var label: String {
        switch kind {
        case .scopeRejected: "the gateway rejected the integration's scope level or ID"
        case .unknownEnvironment: "the gateway does not recognise the environment ID"
        case .edgeBlocked: "blocked at the Jamf gateway edge"
        case .notServed: "not served through this connection"
        case .missingPermission:
            names.isEmpty
                ? "missing permission"
                : "missing permission: " + names.joined(separator: "; ")
        case .noDeclarationData:
            "no DDM declaration data: the environment has none, or each device's report was "
                + "refused (Deployment > Declarations reporting)"
        case .noConfiguredBenchmark:
            names.isEmpty
                ? "no benchmark in platform.compliance_benchmarks can be collected"
                : "no benchmark in platform.compliance_benchmarks can be collected: "
                    + names.joined(separator: "; ")
        case .other: "exit \(exitCode)"
        }
    }

    static func classify(
        exitCode: Int32, stdout: Data, sawForbiddenOnStderr: Bool = false,
        sawNoDeclarationDataOnStderr: Bool = false
    ) -> FailureCause {
        let envelope = JamfCLIErrorEnvelope.parse(stdout)
        let message = envelope?.message ?? ""
        let hint = envelope?.hint ?? ""
        let cappedHint = hint.isEmpty
            ? nil
            : String(decoding: hint.utf8.prefix(hintByteLimit), as: UTF8.self)
        func cause(_ kind: Kind, _ names: [String] = []) -> FailureCause {
            FailureCause(kind: kind, names: names, hint: cappedHint, exitCode: exitCode)
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
/// data (spec §9.1): a swallowed 403, an empty blueprint listing, or no declaration data.
final class StderrSignalWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var forbidden = false
    private var noBlueprints = false
    private var noDeclarationData = false

    var sawForbidden: Bool { lock.withLock { forbidden } }
    var sawNoBlueprints: Bool { lock.withLock { noBlueprints } }
    var sawNoDeclarationData: Bool { lock.withLock { noDeclarationData } }

    /// A retried attempt is classified on its own stderr, not the first attempt's.
    func reset() {
        lock.withLock {
            forbidden = false
            noBlueprints = false
            noDeclarationData = false
        }
    }

    func forwarding(
        to onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void
    ) -> @Sendable (CLIBridge.LogLine) -> Void {
        { line in
            let text = line.text
            self.lock.withLock {
                if text.contains(FailureCause.forbiddenStderrMarker) { self.forbidden = true }
                if text.contains(FailureCause.noBlueprintsStderrMarker) {
                    self.noBlueprints = true
                }
                if text.contains(FailureCause.noDeclarationDataStderrMarker) {
                    self.noDeclarationData = true
                }
            }
            onLine(line)
        }
    }
}
