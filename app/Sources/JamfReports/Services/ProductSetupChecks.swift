import Foundation

/// What runs after `protect setup` or `school setup`, which save credentials without trying them
/// and make the new profile jamf-cli's default.
enum ProductSetupChecks {

    enum Product: Sendable {
        case protect, school

        var name: String { self == .protect ? "Jamf Protect" : "Jamf School" }
        var credentials: String {
            self == .protect ? "client ID and secret" : "network ID and API key"
        }
    }

    enum Verdict: Equatable, Sendable {
        /// The read answered with these credentials.
        case accepted
        /// The read failed; the connection is not recorded.
        case failed(String)
        /// Signed in, or could not tell: the connection is recorded with this note.
        case note(String)
    }

    /// One small read the collect also makes, so it needs no privilege the app does not.
    static func credentialArguments(_ product: Product, profile: String) -> [String] {
        switch product {
        case .protect:
            ["-p", profile, "--no-input", "protect", "plans", "list", "--output", "json"]
        case .school:
            ["-p", profile, "--no-input", "school", "locations", "list", "--output", "json"]
        }
    }

    static func verdict(_ attempt: ConnectionCheck.Attempt?, product: Product) -> Verdict {
        guard let attempt else {
            return .note(
                "The \(product.name) credentials were not checked: jamf-cli did not start.")
        }
        switch attempt.exitCode {
        case 0:
            return .accepted
        case CLIBridge.exitCodeTimedOut:
            return .note("The \(product.name) credentials were not checked: no answer within "
                + "\(Int(ConnectionCheck.timeout)) seconds.")
        case CLIBridge.exitCodePermissionDenied:
            return .note("\(product.name) accepted the credentials, but they lack a permission "
                + "the reports read.")
        case CLIBridge.exitCodeRateLimited:
            return .note("The \(product.name) credentials were not checked: the server is "
                + "throttling requests.")
        default:
            let detail = JamfCLIErrorEnvelope.parse(attempt.stdout)?.message
                .map { "exit \(attempt.exitCode): \(String(LogRedactor.redact($0).prefix(200)))" }
                ?? "exit \(attempt.exitCode)"
            // School and Protect answer a rejected login with exit 1, so a failure is not
            // proof the credentials are wrong; the profile stays and connecting again replaces it.
            return .failed("jamf-cli saved the profile, but reading \(product.name) with it "
                + "failed (\(detail)). Check the \(product.credentials) and connect again.")
        }
    }

    static func checkCredentials(
        _ product: Product, profile: String, runner: ConnectionCheck.Runner
    ) async -> Verdict {
        verdict(await runner(credentialArguments(product, profile: profile)), product: product)
    }

    /// The notes that are present, in order, as one line; nil when none is.
    static func joined(_ notes: String?...) -> String? {
        let present = notes.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " ")
    }

    /// jamf-cli's default profile from its config file, which `set-default` writes; `readable`
    /// is false when the file could not be read.
    static func defaultProfile() -> (readable: Bool, name: String?) {
        guard let rows = ProfileService.readConfigFile(at: ProfileService.defaultConfigFileURL)
        else { return (false, nil) }
        return (true, rows.first(where: \.isDefault)?.name)
    }

    /// `config set-default` back to `previous`; nil when there was no default or it was this one.
    static func setDefaultArguments(previous: String?, setUp: String) -> [String]? {
        guard let previous, previous != setUp else { return nil }
        return ["config", "set-default", "--", previous]
    }

    /// Puts back the default `setUp` replaced. Returns a note when it could not.
    static func restoreDefault(
        previous: (readable: Bool, name: String?), setUp: String, binary: URL
    ) async -> String? {
        guard previous.readable else {
            return "jamf-cli may now use \(setUp) as its default profile; check with "
                + "jamf-cli config list."
        }
        let previous = previous.name
        guard let arguments = setDefaultArguments(previous: previous, setUp: setUp),
              let previous else { return nil }
        let outcome = await JamfCLIProbe.runOutcomeAsync(
            executable: binary, arguments: arguments)
        if case .completed(let output) = outcome, output.exitCode == 0 { return nil }
        return "jamf-cli now uses \(setUp) as its default profile. To use \(previous) again: "
            + "jamf-cli config set-default -- " + ProfileName.shellWord(previous)
    }
}
