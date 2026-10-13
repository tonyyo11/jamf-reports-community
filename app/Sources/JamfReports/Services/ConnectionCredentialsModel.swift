import Foundation
import Observation

/// Registers jamf-cli profiles for a Connection's environments with one client ID and secret:
/// Add environments (new IDs) and Update credentials for all (every member, with its own ID).
/// The registration is onboarding's (`OnboardingFlow.registerPlatformProfile`) and each ID goes
/// through `ConnectionCheck`. The secret lives here from `setSecret` until the run ends or the
/// sheet closes, and is never logged.
@MainActor
@Observable
final class ConnectionCredentialsModel {
    struct JamfCLIContext: Sendable {
        let binary: URL
        let version: String?
    }

    struct Registration: Sendable {
        let profile: String
        let gatewayURL: String
        let scope: OnboardingFlow.PlatformScope
        let scopeID: String
        let clientID: String
        let clientSecret: String
    }

    /// Everything outside the model: jamf-cli, the file system and the store. Tests inject all
    /// of it, so no test launches jamf-cli.
    struct Dependencies {
        var jamfCLI: @Sendable () async -> JamfCLIContext?
        var register: @Sendable (JamfCLIContext, Registration) async throws -> Void
        var check: @Sendable (JamfCLIContext, String) async -> ConnectionCheck.Verdict
        var existingProfiles: @MainActor () -> [String]
        var workspaceConflict: @MainActor (String) -> String?
        /// Creates the profile's workspace; true when it wrote a config.yaml.
        var provisionWorkspace: @MainActor (String) throws -> Bool
        var store: ConnectionStore
    }

    enum Outcome: Equatable {
        case refused(ConnectionEnvironments.Refusal)
        case registrationFailed(String)
        /// Jamf Pro answered. `workspaceNote` is set when the workspace could not be made.
        case added(jamfProVersion: String?, workspaceNote: String?)
        case updated(jamfProVersion: String?)
        case notJamfPro
        case rejected(FailureCause.Kind)
        case notConfirmed(exitCode: Int32?)
        case skipped(String)
    }

    struct Row: Identifiable, Equatable {
        let id = UUID()
        let label: String
        let profile: String
        let outcome: Outcome
        /// True for a profile this run registered for a new ID, false for a member's own.
        var isNew = true

        /// A profile Add environments registered for an ID it did not add. The app has no
        /// remove-profile call, so it stays in jamf-cli.
        var leavesProfileRegistered: Bool {
            guard isNew else { return false }
            switch outcome {
            case .notJamfPro, .rejected, .notConfirmed: return true
            case .refused, .registrationFailed, .added, .updated, .skipped: return false
            }
        }

        var suggestsJamfSchool: Bool { outcome == .notJamfPro }

        var isSuccess: Bool {
            switch outcome {
            case .added, .updated: true
            default: false
            }
        }
    }

    enum Mode: Equatable {
        case addEnvironments
        case updateAll
    }

    let connection: Connection
    let mode: Mode
    var clientID = ""
    var idsText = ""
    var secretFieldHasText = false
    private(set) var clientSecret = ""
    private(set) var rows: [Row] = []
    private(set) var isRunning = false
    private(set) var hasRun = false
    /// A profile was registered or a member added, so the caller reloads its lists.
    private(set) var didChange = false
    private(set) var runError: String?

    private let deps: Dependencies

    init(connection: Connection, mode: Mode, dependencies: Dependencies) {
        self.connection = connection
        self.mode = mode
        self.deps = dependencies
    }

    // MARK: - Gateway

    /// The gateway URL of the connection's region; nil for a region this build has no host for.
    var gatewayURL: String? {
        GatewayRegion(rawValue: connection.region.rawValue)?.url
    }

    var scope: OnboardingFlow.PlatformScope {
        connection.level == .tenant ? .tenant : .environment
    }

    // MARK: - Secret

    func setSecret(_ data: Data) {
        clientSecret = String(data: data, encoding: .utf8) ?? ""
    }

    /// Overwrites the secret before dropping it; the field's own copy is cleared by the sheet.
    func clearSecret() {
        let count = clientSecret.count
        if count > 0 { clientSecret = String(repeating: "\0", count: count) }
        clientSecret.removeAll(keepingCapacity: false)
        clientSecret = ""
        secretFieldHasText = false
    }

    /// The one dismissal path: a typed secret that was never submitted is wiped too.
    func close() {
        clearSecret()
    }

    // MARK: - Input

    var entries: [ConnectionEnvironments.Entry] {
        ConnectionEnvironments.parse(idsText, firstNumber: connection.members.count + 1)
    }

    var plan: [ConnectionEnvironments.Planned] {
        ConnectionEnvironments.plan(
            entries: entries, connection: connection,
            existingProfiles: deps.existingProfiles(), workspaceConflict: deps.workspaceConflict)
    }

    var canRun: Bool {
        guard !isRunning, gatewayURL != nil, !clientID.trimmingCharacters(in: .whitespaces).isEmpty,
              !clientSecret.isEmpty || secretFieldHasText else { return false }
        switch mode {
        case .addEnvironments: return !entries.isEmpty
        case .updateAll: return !connection.members.isEmpty
        }
    }

    // MARK: - Run

    func run() async {
        guard canRun, let gatewayURL else { return }
        isRunning = true
        rows = []
        runError = nil
        defer {
            clearSecret()
            isRunning = false
            hasRun = true
        }
        guard let context = await deps.jamfCLI() else {
            runError = "Could not find jamf-cli. Install it from the sidebar's setup step."
            return
        }
        let secret = clientSecret
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .addEnvironments:
            await addEnvironments(context, gatewayURL: gatewayURL, clientID: id, secret: secret)
        case .updateAll:
            await updateAll(context, gatewayURL: gatewayURL, clientID: id, secret: secret)
        }
        ProfileAuthMethod.invalidateCache()
    }

    private func addEnvironments(
        _ context: JamfCLIContext, gatewayURL: String, clientID: String, secret: String
    ) async {
        for planned in plan {
            let label = planned.entry.label
            if let refusal = planned.refusal {
                rows.append(Row(label: label, profile: planned.profile, outcome: .refused(refusal)))
                continue
            }
            let request = Registration(
                profile: planned.profile, gatewayURL: gatewayURL, scope: scope,
                scopeID: planned.entry.scopeID, clientID: clientID, clientSecret: secret)
            let outcome = await registerAndCheck(context, request) { verdict in
                self.outcomeForNew(planned, verdict: verdict)
            }
            rows.append(Row(label: label, profile: planned.profile, outcome: outcome))
        }
    }

    private func updateAll(
        _ context: JamfCLIContext, gatewayURL: String, clientID: String, secret: String
    ) async {
        for member in connection.members {
            guard !member.scopeID.isEmpty else {
                rows.append(Row(
                    label: member.label, profile: member.profile,
                    outcome: .skipped("No ID is recorded for this profile. Use Update credentials "
                        + "on its own workspace."),
                    isNew: false))
                continue
            }
            let request = Registration(
                profile: member.profile, gatewayURL: gatewayURL, scope: scope,
                scopeID: member.scopeID, clientID: clientID, clientSecret: secret)
            let outcome = await registerAndCheck(context, request) { verdict in
                self.outcomeForExisting(member, verdict: verdict)
            }
            rows.append(Row(
                label: member.label, profile: member.profile, outcome: outcome, isNew: false))
        }
    }

    /// Registers, then checks the ID. A failed registration is the outcome; otherwise
    /// `decide` turns the verdict into one.
    private func registerAndCheck(
        _ context: JamfCLIContext, _ request: Registration,
        decide: (ConnectionCheck.Verdict) -> Outcome
    ) async -> Outcome {
        do {
            try await deps.register(context, request)
        } catch {
            return .registrationFailed(error.localizedDescription)
        }
        didChange = true
        return decide(await deps.check(context, request.profile))
    }

    private func outcomeForNew(
        _ planned: ConnectionEnvironments.Planned, verdict: ConnectionCheck.Verdict
    ) -> Outcome {
        switch verdict {
        case .accepted(let version):
            return .added(jamfProVersion: version, workspaceNote: addMember(planned))
        case .noJamfPro: return .notJamfPro
        case .rejectedID(let kind): return .rejected(kind)
        case .undecided(let exitCode): return .notConfirmed(exitCode: exitCode)
        }
    }

    /// Makes the workspace and records the member. A workspace that could not be made does not
    /// stop the member: the credentials work, and the sidebar can add the workspace later.
    private func addMember(_ planned: ConnectionEnvironments.Planned) -> String? {
        var note: String?
        do {
            _ = try deps.provisionWorkspace(planned.profile)
        } catch {
            note = "The workspace could not be created: \(error.localizedDescription)"
        }
        let member = Connection.Member(
            profile: planned.profile, scopeID: planned.entry.scopeID,
            label: planned.entry.label, product: .pro)
        do {
            try deps.store.addMember(member, toConnection: connection.id)
        } catch {
            AppLogger.auth.warning(
                """
                AddEnvironments: could not record a member: \
                \(error.localizedDescription, privacy: .private)
                """)
            note = (note.map { $0 + " " } ?? "") + "It could not be recorded in the connection."
        }
        return note
    }

    private func outcomeForExisting(
        _ member: Connection.Member, verdict: ConnectionCheck.Verdict
    ) -> Outcome {
        switch verdict {
        case .accepted(let version):
            refreshProduct(member, .pro)
            return .updated(jamfProVersion: version)
        case .noJamfPro:
            refreshProduct(member, .unknown)
            return .notJamfPro
        case .rejectedID(let kind): return .rejected(kind)
        case .undecided(let exitCode): return .notConfirmed(exitCode: exitCode)
        }
    }

    private func refreshProduct(_ member: Connection.Member, _ product: Connection.Member.Product) {
        do {
            try deps.store.recordMember(
                profile: member.profile, scopeID: member.scopeID, product: product,
                region: connection.region, level: connection.level)
        } catch {
            AppLogger.auth.warning(
                """
                UpdateCredentials: could not refresh a member: \
                \(error.localizedDescription, privacy: .private)
                """)
        }
    }
}

extension ConnectionCredentialsModel.Row {
    /// Plain words for the results list. Names the profile where jamf-cli still holds one the
    /// connection does not use, with the command that removes it.
    var message: String {
        switch outcome {
        case .refused(let refusal):
            return "Not registered. \(refusal.message)"
        case .registrationFailed(let text):
            return "jamf-cli could not register \(profile): \(text)"
        case .added(let version, let note):
            let base = "Added. Jamf Pro " + (version.map { "\($0) " } ?? "") + "answered."
            return note.map { "\(base) \($0)" } ?? base
        case .updated(let version):
            return "Credentials updated. Jamf Pro " + (version.map { "\($0) " } ?? "") + "answered."
        case .notJamfPro:
            return (isNew ? "Not added to the connection. " : "")
                + "No Jamf Pro answers for this ID, so its MDM is probably Jamf School: Jamf "
                + "School is read with a School API key, in its own Jamf School workspace. "
                + removalHint
        case .rejected(let kind):
            return ConnectionCheck.Verdict.rejectedID(kind).message + " " + removalHint
        case .notConfirmed(let exitCode):
            let cause = exitCode == CLIBridge.exitCodeTimedOut
                ? "no answer within \(Int(ConnectionCheck.timeout)) seconds"
                : exitCode.map { "exit \($0)" } ?? "jamf-cli did not run"
            return (isNew ? "Not added: " : "") + "the check could not confirm the ID (\(cause)). "
                + "Check the client ID, secret and API privileges. " + removalHint
        case .skipped(let reason):
            return reason
        }
    }

    private var removalHint: String {
        guard leavesProfileRegistered else { return "" }
        return "The jamf-cli profile \(profile) stays registered; remove it with "
            + "jamf-cli config remove-profile \(ProfileName.shellWord(profile)) if you do not "
            + "need it."
    }
}
