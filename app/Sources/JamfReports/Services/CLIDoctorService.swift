import Foundation

// MARK: - Model

/// Decoded `jamf-cli doctor --output json` report: the resolved profile, its
/// credential-resolution state (secrets fingerprinted by jamf-cli, never raw),
/// and a read-only HEAD connectivity probe of the configured URL.
///
/// Distinct from `DoctorReport`/`ConfigDoctorService`, which diagnose the local
/// `config.yaml`. This one diagnoses the jamf-cli *connection* (the "why is my
/// 401 firing / why did no profile resolve" surface).
///
/// Every field is optional: `doctor` omits whole blocks when there is nothing
/// to report (no `profile` when none resolves, no `connectivity` when no URL is
/// configured). A tolerant decode keeps a partial diagnostic usable — which is
/// exactly the situation `doctor` exists to surface.
struct CLIDoctorReport: Sendable, Equatable, Codable {

    struct Profile: Sendable, Equatable, Codable {
        var name: String?
        var url: String?
        var effectiveUrl: String?
        var authMethod: String?
        var credentials: [Credential]?
    }

    struct Credential: Sendable, Equatable, Codable {
        var field: String?
        var resolved: Bool?
        var fingerprint: String?
    }

    struct Connectivity: Sendable, Equatable, Codable {
        var url: String?
        var statusCode: Int?
        var latencyMs: Int?
    }

    var version: String?
    var configPath: String?
    var configPresent: Bool?
    var profile: Profile?
    var connectivity: Connectivity?

    /// One-line health verdict the UI maps to an icon/colour. Derivation order
    /// (most-blocking first): no profile resolved → unreachable server →
    /// auth rejected → unresolved credentials → healthy.
    enum Health: Sendable, Equatable {
        case noProfile
        case unreachable
        case unauthorized
        case credentialsUnresolved
        case healthy
    }

    /// True only when at least one credential is listed and every listed one
    /// resolved. An empty/absent credential list is treated as unresolved —
    /// a profile with no resolvable credentials cannot authenticate.
    var credentialsAllResolved: Bool {
        guard let creds = profile?.credentials, !creds.isEmpty else { return false }
        return creds.allSatisfy { $0.resolved == true }
    }

    var health: Health {
        guard let profile, !(profile.name ?? "").isEmpty else { return .noProfile }
        // No status (nil or 0) means the HEAD probe never reached the server.
        let status = connectivity?.statusCode ?? 0
        if status == 0 { return .unreachable }
        if status == 401 || status == 403 { return .unauthorized }
        if !credentialsAllResolved { return .credentialsUnresolved }
        // 2xx/3xx reachable, or a non-auth 4xx/5xx (server answered) — with
        // credentials resolved we call it healthy; the panel still shows the
        // raw status code for any non-2xx case.
        return .healthy
    }
}

// MARK: - Service

/// Runs `jamf-cli doctor` for a workspace profile and decodes the result.
///
/// Mirrors `CapabilityService`: `@MainActor @Observable`, injected
/// `CLIExecutor`, pure `nonisolated static` parser, fully testable without a
/// live binary. Binary location is delegated to the executor so `run()` itself
/// is exercisable with a mock (a `binaryNotFound` throw maps to `.notInstalled`).
@MainActor
@Observable
final class CLIDoctorService {

    enum Outcome: Sendable, Equatable {
        case notInstalled
        case report(CLIDoctorReport)
        case failed(reason: String)
    }

    private let executor: CLIExecutor

    init(executor: CLIExecutor) {
        self.executor = executor
    }

    func run(profile: String) async -> Outcome {
        do {
            let data = try await executor.execute(.proDoctor(profile: profile))
            guard let report = Self.parse(data) else {
                return .failed(reason: "Could not parse jamf-cli doctor output.")
            }
            return .report(report)
        } catch CLIExecutorError.binaryNotFound {
            return .notInstalled
        } catch CLIExecutorError.invalidProfile {
            return .failed(reason: "Invalid profile name.")
        } catch let CLIExecutorError.nonZeroExit(_, stderr) {
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(reason: trimmed.isEmpty ? "jamf-cli doctor failed." : trimmed)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Decode a `doctor --output json` payload. Returns nil only when the bytes
    /// are not valid doctor JSON.
    nonisolated static func parse(_ data: Data) -> CLIDoctorReport? {
        try? JSONDecoder().decode(CLIDoctorReport.self, from: data)
    }
}
