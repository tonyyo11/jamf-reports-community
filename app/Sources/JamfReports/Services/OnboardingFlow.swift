import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class OnboardingFlow {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome = 0
        case installCLI
        case workspace
        case authenticate
        case validate
        case csvMapping
        case addProducts
        case firstReport
        // Jamf School-only path step. Added at the end so the Jamf Pro path's
        // rawValues (and everything keyed off them) stay byte-identical.
        case schoolConnect

        var id: Int { rawValue }
        var number: Int { rawValue + 1 }

        var label: String {
            switch self {
            case .welcome: "Welcome"
            case .installCLI: "Install jamf-cli"
            case .workspace: "Workspace"
            case .authenticate: "Authenticate"
            case .validate: "Validate"
            case .addProducts: "Add products"
            case .csvMapping: "CSV mapping"
            case .firstReport: "First report"
            case .schoolConnect: "Connect School"
            }
        }
    }

    /// Which product this onboarding run is setting up.
    ///
    /// `.pro` is the default and lenient fallback — every existing entry point
    /// (Settings "Add connection", the sidebar "Add workspace…", and every test
    /// that constructs `OnboardingFlow()`) resolves to `.pro`, so the Jamf Pro
    /// flow is unchanged. `.school` is chosen only from the first-launch chooser's
    /// "Connect Jamf School" card, which sets `pendingProductPath` before the
    /// view constructs the flow.
    enum ProductPath: String, Sendable {
        case pro
        case school
    }

    /// Handoff from `FirstLaunchChooserView` to a freshly-constructed
    /// `OnboardingFlow`. The chooser and the flow's `init` both run on the main
    /// actor, so this MainActor-isolated static is a race-free one-shot: the
    /// chooser sets it, `init()` consumes and clears it. Nil (the default) means
    /// the Jamf Pro path, so nothing existing changes.
    static var pendingProductPath: ProductPath?

    // MARK: - Connection types

    enum ProConnectionType: String, CaseIterable, Identifiable {
        case oauth2
        case platformGateway

        var id: String { rawValue }
        var label: String {
            switch self {
            case .oauth2: "Standard (OAuth2)"
            case .platformGateway: "Platform Gateway"
            }
        }
    }

    /// What setup knows about the installed jamf-cli. It starts at `.checking` and leaves it
    /// only when the probe answers, so the install step never says "not detected" about a
    /// probe that is still running.
    enum JamfCLIStatus: Equatable, Sendable {
        case checking
        case installed(version: String?)
        case missing
    }

    /// Finds jamf-cli and reads its version. It launches child processes and waits on them,
    /// so the flow only calls it off the main actor, never during a SwiftUI update.
    typealias InstallationProbe = @Sendable () -> JamfCLIInstaller.Installation?

    enum FlowError: LocalizedError {
        case invalidProfile
        case profileCaseConflict(existing: String)
        case invalidJamfURL
        case missingJamfCLI
        case missingWorkspace
        case csvOutsideAllowedZones
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile:
                "Use a name without a line break or tab, that doesn't start or end with a space, "
                    + "and is short enough to be a folder name."
            case .profileCaseConflict(let existing):
                "A workspace named \(existing) already exists, and a name that differs from it "
                    + "only by letter case would share its folder. Choose a different name."
            case .invalidJamfURL:
                "Jamf Pro URL must start with https:// and include a valid host."
            case .missingJamfCLI:
                "Could not find jamf-cli on PATH."
            case .missingWorkspace:
                "Create the workspace before running this step."
            case .csvOutsideAllowedZones:
                "Choose a CSV from ~/Documents, ~/Downloads, or ~/Desktop."
            case .processFailed(let message):
                message
            }
        }
    }

    var currentStep: Step = .welcome

    /// The product this run is setting up. Drives `stepSequence` and the
    /// firstReport routing. Defaults to `.pro`; set from `pendingProductPath`
    /// in `init`.
    var productPath: ProductPath = .pro

    // MARK: - Jamf Pro fields

    var proConnectionType: ProConnectionType = .oauth2

    var profileName = ""
    var jamfURL = ""
    var clientID = ""
    var clientSecret = ""
    /// True when the secure field has keystrokes but `clientSecret` is not yet finalized.
    var secretFieldHasText = false

    /// The Platform API scope level: which flag `config add-profile` sends. Organization level is
    /// not offered: it sends no scope header, and every call the app makes needs one.
    enum PlatformScope: String, CaseIterable, Sendable {
        case environment, tenant

        var label: String {
            switch self {
            case .environment: "Environment"
            case .tenant: "Tenant (legacy)"
            }
        }

        var idFieldLabel: String {
            switch self {
            case .environment: "Environment ID"
            case .tenant: "Tenant ID"
            }
        }

        /// GA default is environment; a detected pre-1.28 jamf-cli would reject
        /// `--environment-id` (exit 2), so it starts on the legacy flag instead.
        static func defaultScope(forCLIVersion version: String?) -> PlatformScope {
            JamfCLIInstaller.supportsEnvironmentScope(version) ? .environment : .tenant
        }
    }

    // Platform Gateway additional fields
    var gatewayURL = "https://us.api.jamfcloud.com"
    var platformScope: PlatformScope = .environment
    /// True once the user picked a scope, so a probe that finishes later keeps their choice.
    private(set) var platformScopeChosen = false
    var platformScopeID = ""
    var platformClientID = ""
    var platformClientSecret = ""
    var platformSecretFieldHasText = false

    // MARK: - Jamf Protect fields

    var protectEnabled = false
    var protectURL = ""
    var protectClientID = ""
    var protectClientSecret = ""
    var protectSecretFieldHasText = false
    var protectProfileName = ""
    var isConnectingProtect = false
    var protectConnected = false
    var protectConnectionError: String?
    /// What recording the connection in config.yaml did not keep (a backup was made).
    var protectConfigNote: String?

    // MARK: - Jamf School fields

    var schoolEnabled = false
    var schoolURL = ""
    var schoolNetworkID = ""
    var schoolAPIKey = ""
    var schoolAPIKeyFieldHasText = false
    var schoolProfileName = ""
    var isConnectingSchool = false
    var schoolConnected = false
    var schoolConnectionError: String?
    /// What recording the connection in config.yaml did not keep (a backup was made).
    var schoolConfigNote: String?

    // MARK: - State flags

    private(set) var jamfCLIStatus: JamfCLIStatus = .checking
    var workspaceCreated = false
    var profileRegistered = false
    var connectionValidated = false
    var selectedCSVURL: URL?
    var csvScaffolded = false
    var csvMappingSkipped = false
    var firstReportExitCode: Int32?

    var isRegisteringProfile = false
    var isValidatingConnection = false
    var isScaffoldingCSV = false
    var isSkippingCSVMapping = false
    var isRunningFirstReport = false

    var lastError: String?
    var validationOutput: [CLIBridge.LogLine] = []
    var validationExitCode: Int32?
    /// The gateway's answer about a Platform API profile's scope ID; nil for OAuth2 profiles
    /// and before validation.
    var connectionCheck: ConnectionCheck.Verdict?
    var csvOutput: [CLIBridge.LogLine] = []
    var firstReportOutput: [CLIBridge.LogLine] = []

    private let installer = JamfCLIInstaller()
    private let installationProbe: InstallationProbe

    // User data zones accepted by policy for the first CSV export.
    private var allowedCSVRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true),
        ]
    }

    /// Runs no subprocess: `@State` builds this during a view update, and a child-process wait
    /// there spins the main run loop into a nested layout that aborts AttributeGraph. The
    /// jamf-cli probe is `refreshJamfCLIStatus()`, which a view starts from `.task`.
    init(
        installationProbe: @escaping InstallationProbe = { JamfCLIInstaller.currentInstallation() }
    ) {
        self.installationProbe = installationProbe
        if let pending = Self.pendingProductPath {
            productPath = pending
            Self.pendingProductPath = nil
        }
    }

    var jamfCLIInstalled: Bool {
        if case .installed = jamfCLIStatus { return true }
        return false
    }

    var jamfCLIVersion: String? {
        if case .installed(let version) = jamfCLIStatus { return version }
        return nil
    }

    var isCheckingJamfCLI: Bool { jamfCLIStatus == .checking }

    /// The ordered steps for the active `productPath`.
    ///
    /// The Jamf Pro sequence is exactly the pre-existing rawValue order, so
    /// sequence-indexed navigation is byte-identical to the old rawValue+1
    /// stepping. The Jamf School sequence skips the Pro-only Authenticate /
    /// Validate / Add-products steps and inserts `.schoolConnect` AFTER
    /// `.csvMapping` — the same reason `.addProducts` follows `.csvMapping` on
    /// the Pro path: the CSV step rewrites `config.yaml`, so the product-connect
    /// step (which merges `school_cli` into it) must run last of the two, or its
    /// keys would be clobbered.
    var stepSequence: [Step] {
        switch productPath {
        case .pro:
            [.welcome, .installCLI, .workspace, .authenticate, .validate,
             .csvMapping, .addProducts, .firstReport]
        case .school:
            [.welcome, .installCLI, .workspace, .csvMapping, .schoolConnect, .firstReport]
        }
    }

    /// 1-based position of `currentStep` within `stepSequence`.
    var stepPosition: Int { (stepSequence.firstIndex(of: currentStep) ?? 0) + 1 }

    /// Total number of steps in the active path.
    var stepCount: Int { stepSequence.count }

    var canAdvance: Bool {
        switch currentStep {
        case .welcome:
            true
        case .installCLI:
            jamfCLIInstalled
        case .workspace:
            isProfileNameValid
        case .authenticate:
            switch proConnectionType {
            case .oauth2:
                isProfileNameValid && isJamfURLValid && !clientID.trimmed.isEmpty
                    && (!clientSecret.isEmpty || secretFieldHasText) && !isRegisteringProfile
            case .platformGateway:
                isProfileNameValid && isGatewayURLValid
                    && !platformScopeID.trimmed.isEmpty
                    && !platformClientID.trimmed.isEmpty
                    && (!platformClientSecret.isEmpty || platformSecretFieldHasText)
                    && !isRegisteringProfile
            }
        case .validate:
            profileRegistered && !isValidatingConnection
        case .addProducts:
            // Both products are optional — always advanceable.
            !isConnectingProtect && !isConnectingSchool
        case .schoolConnect:
            // A School-only workspace needs a real, successful School
            // connection: only then is `school_cli` written and detection
            // resolves to Jamf School. Advancing without it would leave a
            // Pro-detected empty config.
            schoolConnected && !isConnectingSchool
        case .csvMapping:
            (csvScaffolded || csvMappingSkipped) && !isScaffoldingCSV && !isSkippingCSVMapping
        case .firstReport:
            !isRunningFirstReport
        }
    }

    /// Whether the School connect fields are complete enough to attempt a
    /// connection (used by the Connect button; canAdvance requires the
    /// connection to have actually succeeded).
    var canAttemptSchoolConnect: Bool {
        isSchoolURLValid
            && !schoolNetworkID.trimmed.isEmpty
            && (!schoolAPIKey.isEmpty || schoolAPIKeyFieldHasText)
            && !isConnectingSchool
    }

    var isProfileNameValid: Bool {
        ProfileService.isValid(profileName.trimmed)
    }

    /// What a validated field shows under it. A field nothing has been typed into shows its
    /// rule as a hint: marking it red reports a mistake the user has not made yet.
    enum FieldFeedback: Equatable {
        case hint, valid, invalid
    }

    static func feedback(for value: String, isValid: Bool) -> FieldFeedback {
        if value.trimmed.isEmpty { return .hint }
        return isValid ? .valid : .invalid
    }

    var isJamfURLValid: Bool {
        normalizedJamfURL != nil
    }

    var workspaceURL: URL? {
        ProfileService.workspaceURL(for: profileName.trimmed)
    }

    /// Where onboarding will create the workspace. Resolves through the
    /// configured root so it agrees with `workspaceURL` directly above — the
    /// two used to answer the same question differently once the root moved.
    var workspacePreviewPath: String {
        let name = profileName.trimmed.isEmpty ? "<profile>" : profileName.trimmed
        return WorkspaceRootStore.displayPath(profile: name) + "/"
    }

    var brewCommand: String {
        installer.brewInstallCommand()
    }

    /// Looks for jamf-cli off the main actor, then publishes the answer and, unless the user
    /// already picked one, the Platform API scope that version defaults to.
    func refreshJamfCLIStatus() async {
        jamfCLIStatus = .checking
        let probe = installationProbe
        let installation = await Task.detached(priority: .userInitiated) { probe() }.value
        if let installation {
            jamfCLIStatus = .installed(version: installation.version)
        } else {
            jamfCLIStatus = .missing
        }
        if !platformScopeChosen {
            platformScope = PlatformScope.defaultScope(forCLIVersion: installation?.version)
        }
    }

    func choosePlatformScope(_ scope: PlatformScope) {
        platformScope = scope
        platformScopeChosen = true
    }

    func nextStep() {
        let sequence = stepSequence
        guard let idx = sequence.firstIndex(of: currentStep), idx + 1 < sequence.count else {
            return
        }
        currentStep = sequence[idx + 1]
        lastError = nil
    }

    func previousStep() {
        let sequence = stepSequence
        guard let idx = sequence.firstIndex(of: currentStep), idx > 0 else { return }
        if currentStep == .authenticate {
            clearClientSecret()
            clearPlatformSecrets()
        }
        if currentStep == .addProducts {
            clearProductSecrets()
        }
        if currentStep == .schoolConnect {
            clearSchoolAPIKey()
            // Backing into csvMapping re-runs scaffold/skip, which rewrites
            // config.yaml and clobbers the school_cli block — require the
            // connect step to be redone so the block is rewritten too.
            schoolConnected = false
            schoolConnectionError = nil
        }
        currentStep = sequence[idx - 1]
        lastError = nil
    }

    func createWorkspace() throws {
        let profile = profileName.trimmed
        guard ProfileService.isValid(profile) else { throw FlowError.invalidProfile }
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            throw FlowError.invalidProfile
        }
        // Checked before jamf-cli has a profile by this name: the connection
        // scaffold would otherwise overwrite that workspace's config.yaml.
        if let existing = ProfileService.caseVariantWorkspace(of: profile) {
            throw FlowError.profileCaseConflict(existing: existing)
        }

        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: Int16(0o700))]
        let paths = [
            ProfileService.workspacesRoot(),
            workspace,
            workspace.appendingPathComponent("csv-inbox", isDirectory: true),
            workspace.appendingPathComponent("jamf-cli-data", isDirectory: true),
            workspace.appendingPathComponent("Generated Reports", isDirectory: true),
            workspace.appendingPathComponent("automation", isDirectory: true),
            workspace.appendingPathComponent("automation/logs", isDirectory: true),
            workspace.appendingPathComponent("snapshots", isDirectory: true),
        ]

        for url in paths {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: attrs)
            try? fm.setAttributes(attrs, ofItemAtPath: url.path)
        }

        // Spotlight exclusion (security audit C-02): without this marker, the
        // workspace contents (device serials, usernames, compliance findings)
        // get indexed and become queryable system-wide via `mdfind`, leak via
        // universal search, and end up in iCloud / Time Machine metadata.
        // `.metadata_never_index` is the documented opt-out for `mdimport`.
        // SF-9: mirror the defensive write pattern in
        // `WorkspaceMigration.dropNeverIndexMarker`. A silent `try?` here meant
        // a write failure left `workspaceCreated = true` while Spotlight could
        // still index the workspace contents.
        let neverIndex = workspace.appendingPathComponent(".metadata_never_index")
        if !fm.fileExists(atPath: neverIndex.path) {
            do {
                try Data().write(to: neverIndex, options: .atomic)
                try? fm.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o600))],
                    ofItemAtPath: neverIndex.path
                )
            } catch {
                AppLogger.auth.warning(
                    "OnboardingFlow: failed to write .metadata_never_index: \(error.localizedDescription, privacy: .private)"
                )
            }
        }

        // Backfill: tighten any 0644 artifacts a previous version of the app
        // (or a prior CLI run with default umask) left behind. Cheap because
        // newly created workspaces have no files; expensive only on a long-
        // standing workspace, which is exactly when we want to do it (audit
        // C-03 documented an inflection on 2026-05-01 where some writers got
        // the chmod and others didn't).
        WorkspacePermissionHardener.tighten(profile: profile)

        // config.yaml is intentionally not written here. The CSV mapping step
        // produces it via ScaffoldService.writeConfig; the skip path produces it via
        // ScaffoldService.writeMinimalConfig. Writing a placeholder here would block
        // scaffold (which refuses to overwrite an existing file).
        workspaceCreated = true
        lastError = nil
    }

    func registerJamfCLIProfile() async throws {
        switch proConnectionType {
        case .oauth2:
            try await registerOAuth2Profile()
        case .platformGateway:
            try await registerPlatformGatewayProfile()
        }
        // Update credentials can switch a profile's auth method or scope level. Collect and
        // the health strip read both through ProfileAuthMethod's process-lifetime cache,
        // which kept the old answer, and skipped kinds, until Settings opened or a relaunch.
        ProfileAuthMethod.invalidateCache()
    }

    private func registerOAuth2Profile() async throws {
        guard let binary = CLIBridge().locate("jamf-cli") else { throw FlowError.missingJamfCLI }
        try Self.signatureGate(binary: binary)
        guard let url = normalizedJamfURL else { throw FlowError.invalidJamfURL }
        guard isProfileNameValid else { throw FlowError.invalidProfile }

        isRegisteringProfile = true
        defer { isRegisteringProfile = false }

        // jamf-cli config add-profile only reads the Client ID and Client Secret
        // from a controlling TTY (see golang.org/x/term). Allocate a pty so the
        // GUI can drive the prompts without launching an interactive terminal.
        // The "\n" terminator is what the term reader uses to delimit each value.
        var stdinData = Self.proOAuth2Stdin(clientID: clientID.trimmed, clientSecret: clientSecret)
        defer {
            stdinData.resetBytes(in: 0..<stdinData.count)
            clearClientSecret()
        }

        let noVerify = await noVerifyFlag(binary: binary)
        let result = try await Self.runWithPTY(
            executable: binary,
            arguments: Self.proOAuth2Arguments(
                profile: profileName.trimmed, url: url.absoluteString, noVerify: noVerify
            ),
            stdin: stdinData
        )

        guard result.exitCode == 0 else {
            let combined = redactedCredentialOutput(result.combined.trimmed)
            let message = combined.isEmpty ? "jamf-cli exited \(result.exitCode)." : combined
            throw FlowError.processFailed(message)
        }

        profileRegistered = true
        connectionValidated = false
        validationExitCode = nil
        validationOutput.removeAll()
        connectionCheck = nil
        lastError = nil
    }

    private func registerPlatformGatewayProfile() async throws {
        guard let binary = CLIBridge().locate("jamf-cli") else { throw FlowError.missingJamfCLI }
        try Self.signatureGate(binary: binary)
        guard isProfileNameValid else { throw FlowError.invalidProfile }
        guard isGatewayURLValid else { throw FlowError.invalidJamfURL }

        isRegisteringProfile = true
        defer { isRegisteringProfile = false }

        var stdinData = Self.platformGatewayStdin(
            clientID: platformClientID.trimmed, clientSecret: platformClientSecret
        )
        defer {
            stdinData.resetBytes(in: 0..<stdinData.count)
            clearPlatformSecrets()
        }

        let noVerify = await noVerifyFlag(binary: binary)
        let result = try await Self.runWithPTY(
            executable: binary,
            arguments: Self.platformGatewayArguments(
                profile: profileName.trimmed,
                gatewayURL: gatewayURL.trimmed,
                scope: platformScope,
                scopeID: platformScopeID.trimmed,
                noVerify: noVerify
            ),
            stdin: stdinData
        )

        guard result.exitCode == 0 else {
            let redacted = platformRedactedOutput(result.combined.trimmed)
            let message = redacted.isEmpty ? "jamf-cli exited \(result.exitCode)." : redacted
            throw FlowError.processFailed(message)
        }

        profileRegistered = true
        connectionValidated = false
        validationExitCode = nil
        validationOutput.removeAll()
        connectionCheck = nil
        lastError = nil
    }

    // MARK: - Add-products registration (Protect / School)

    func registerProtectProfile() async {
        protectConnected = false
        protectConnectionError = nil
        protectConfigNote = nil

        let name = protectProfileName.trimmed
        guard ProfileService.isValid(name) else {
            protectConnectionError = FlowError.invalidProfile.localizedDescription
            return
        }
        guard let binary = CLIBridge().locate("jamf-cli") else {
            protectConnectionError = FlowError.missingJamfCLI.localizedDescription
            return
        }
        // The client secret goes to this binary, so it passes the same signature gate as
        // the Jamf Pro paths.
        do {
            try Self.signatureGate(binary: binary)
        } catch {
            protectConnectionError = error.localizedDescription
            return
        }
        // S1: reject http:// URLs before any secret reaches the PTY.
        // Mirrors the Platform Gateway guard at registerPlatformGatewayProfile().
        guard isProtectURLValid else {
            protectConnectionError = FlowError.invalidJamfURL.localizedDescription
            return
        }

        isConnectingProtect = true
        defer { isConnectingProtect = false }

        var stdinData = Self.protectStdin(
            clientID: protectClientID.trimmed, clientSecret: protectClientSecret
        )
        defer {
            stdinData.resetBytes(in: 0..<stdinData.count)
            clearProtectSecret()
        }

        do {
            let result = try await Self.runWithPTY(
                executable: binary,
                arguments: Self.protectArguments(
                    profile: name, url: protectURL.trimmed
                ),
                stdin: stdinData
            )
            guard result.exitCode == 0 else {
                let redacted = protectRedactedOutput(result.combined.trimmed)
                let msg = redacted.isEmpty ? "jamf-cli exited \(result.exitCode)." : redacted
                protectConnectionError = msg
                return
            }
        } catch {
            protectConnectionError = error.localizedDescription
            return
        }

        do {
            try recordProtectConnection(profileSlug: profileName.trimmed, protectProfileName: name)
        } catch {
            protectConnectionError = "Connected, but config update failed: \(error.localizedDescription)"
        }
    }

    /// Writes protect.enabled + protect.profile into the workspace config after setup
    /// succeeded, and keeps what the write did not keep as `protectConfigNote`.
    func recordProtectConnection(profileSlug: String, protectProfileName: String) throws {
        protectConfigNote = try writeProtectConfig(
            profileSlug: profileSlug, protectProfileName: protectProfileName).statusLine
        protectConnected = true
        protectEnabled = true
    }

    func registerSchoolProfile() async {
        schoolConnected = false
        schoolConnectionError = nil
        schoolConfigNote = nil

        let name = schoolProfileName.trimmed
        guard ProfileService.isValid(name) else {
            schoolConnectionError = FlowError.invalidProfile.localizedDescription
            return
        }
        guard let binary = CLIBridge().locate("jamf-cli") else {
            schoolConnectionError = FlowError.missingJamfCLI.localizedDescription
            return
        }
        // The API key goes to this binary, so it passes the same signature gate as the
        // Jamf Pro paths.
        do {
            try Self.signatureGate(binary: binary)
        } catch {
            schoolConnectionError = error.localizedDescription
            return
        }
        // S1: reject http:// URLs before any secret reaches the PTY.
        // Mirrors the Platform Gateway guard at registerPlatformGatewayProfile().
        guard isSchoolURLValid else {
            schoolConnectionError = FlowError.invalidJamfURL.localizedDescription
            return
        }

        isConnectingSchool = true
        defer { isConnectingSchool = false }

        var stdinData = Self.schoolStdin(
            networkID: schoolNetworkID.trimmed, apiKey: schoolAPIKey
        )
        defer {
            stdinData.resetBytes(in: 0..<stdinData.count)
            clearSchoolAPIKey()
        }

        do {
            let result = try await Self.runWithPTY(
                executable: binary,
                arguments: Self.schoolArguments(
                    profile: name, url: schoolURL.trimmed
                ),
                stdin: stdinData
            )
            guard result.exitCode == 0 else {
                let redacted = schoolRedactedOutput(result.combined.trimmed)
                let msg = redacted.isEmpty ? "jamf-cli exited \(result.exitCode)." : redacted
                schoolConnectionError = msg
                return
            }
        } catch {
            schoolConnectionError = error.localizedDescription
            return
        }

        do {
            try recordSchoolConnection(profileSlug: profileName.trimmed, schoolProfileName: name)
        } catch {
            schoolConnectionError = "Connected, but config update failed: \(error.localizedDescription)"
        }
    }

    /// Writes school_cli.enabled + school_cli.profile into the workspace config after setup
    /// succeeded, and keeps what the write did not keep as `schoolConfigNote`.
    func recordSchoolConnection(profileSlug: String, schoolProfileName: String) throws {
        schoolConfigNote = try writeSchoolConfig(
            profileSlug: profileSlug, schoolProfileName: schoolProfileName).statusLine
        schoolConnected = true
        schoolEnabled = true
    }

    /// Connect Jamf School as the workspace's PRIMARY product (School-only path).
    ///
    /// On the Jamf School path the workspace profile itself is the School
    /// jamf-cli profile — there is no separate Pro profile — so the School
    /// setup uses `profileName` and `writeSchoolConfig` wires
    /// `school_cli.enabled/profile = <profileName>` into that workspace's
    /// config.yaml, which is exactly what `ProfileProductType.detect` reads to
    /// route the workspace to Jamf School. Reuses the same PTY machinery,
    /// fields, and redaction as the Add-products Connect School button.
    func connectSchoolAsPrimary() async {
        schoolProfileName = profileName.trimmed
        await registerSchoolProfile()
    }

    /// jamf-cli 1.29 checks a new profile's credentials against the server before
    /// writing it. `--no-verify` keeps Save a local write on every version, so the
    /// Validate step stays the connection check and a placeholder pair still
    /// registers. The flag is unknown before 1.29 (exit 2), hence the gate.
    private func noVerifyFlag(binary: URL) async -> Bool {
        JamfCLIInstaller.supportsSpecDerivedNames(await installedCLIVersion(binary: binary))
    }

    /// The probe's version when it has one. Otherwise a fresh read, off the main actor, because
    /// a registration can start before the probe returns or after it found no version.
    private func installedCLIVersion(binary: URL) async -> String? {
        if let jamfCLIVersion { return jamfCLIVersion }
        return await Task.detached(priority: .userInitiated) {
            JamfCLIInstaller.installedVersion(at: binary)
        }.value
    }

    // MARK: - Pure argument builders (testable without PTY)

    /// Arguments for `jamf-cli config add-profile` using OAuth2 auth. The name goes last,
    /// after `--`, so one starting with `-` is not read as a flag.
    static func proOAuth2Arguments(
        profile: String, url: String, noVerify: Bool = false
    ) -> [String] {
        var args = ["config", "add-profile",
                    "--url", url,
                    "--auth-method", "oauth2",
                    "--no-color"]
        if noVerify { args.append("--no-verify") }
        return args + ["--", profile]
    }

    /// stdin bytes for OAuth2 profile registration (clientID\nclientSecret\n).
    ///
    /// Bytes are appended directly to avoid creating a temporary String that holds
    /// the secret in plaintext. The returned Data is wiped via `resetBytes` in the
    /// caller's `defer`. Residual COW limitation: the `clientSecret` String property
    /// itself may survive in a CoW-shared buffer after `clearClientSecret()`; the
    /// authoritative zero of the actually-transmitted bytes is the `stdinData.resetBytes`
    /// defer in `registerOAuth2Profile`.
    static func proOAuth2Stdin(clientID: String, clientSecret: String) -> Data {
        var data = Data()
        data.append(contentsOf: clientID.utf8)
        data.append(0x0A)
        data.append(contentsOf: clientSecret.utf8)
        data.append(0x0A)
        return data
    }

    /// Arguments for `jamf-cli config add-profile` using Platform Gateway auth. Sends exactly one
    /// scope flag (`--environment-id` / `--tenant-id`); the flags are mutually exclusive. The
    /// name goes last, after `--`, as for OAuth2.
    static func platformGatewayArguments(
        profile: String, gatewayURL: String, scope: PlatformScope, scopeID: String,
        noVerify: Bool = false
    ) -> [String] {
        var args = ["config", "add-profile",
                     "--auth-method", "platform"]
        switch scope {
        case .environment: args += ["--environment-id", scopeID]
        case .tenant: args += ["--tenant-id", scopeID]
        }
        args += ["--url", gatewayURL, "--no-color"]
        if noVerify { args.append("--no-verify") }
        return args + ["--", profile]
    }

    /// stdin bytes for Platform Gateway profile registration (clientID\nclientSecret\n).
    ///
    /// See `proOAuth2Stdin` for the COW residual-limitation note that applies equally here.
    static func platformGatewayStdin(clientID: String, clientSecret: String) -> Data {
        var data = Data()
        data.append(contentsOf: clientID.utf8)
        data.append(0x0A)
        data.append(contentsOf: clientSecret.utf8)
        data.append(0x0A)
        return data
    }

    /// Arguments for `jamf-cli protect setup`.
    static func protectArguments(profile: String, url: String) -> [String] {
        ["protect", "setup",
         "--profile-name", profile,
         "--url", url,
         "--no-color"]
    }

    /// stdin bytes for Protect setup (clientID\nclientSecret\n).
    ///
    /// See `proOAuth2Stdin` for the COW residual-limitation note that applies equally here.
    static func protectStdin(clientID: String, clientSecret: String) -> Data {
        var data = Data()
        data.append(contentsOf: clientID.utf8)
        data.append(0x0A)
        data.append(contentsOf: clientSecret.utf8)
        data.append(0x0A)
        return data
    }

    /// Arguments for `jamf-cli school setup`.
    static func schoolArguments(profile: String, url: String) -> [String] {
        ["school", "setup",
         "--profile-name", profile,
         "--url", url,
         "--no-color"]
    }

    /// stdin bytes for School setup (networkID\napiKey\nn\n).
    ///
    /// The trailing `n\n` is a defensive answer to the optional
    /// "Configure Platform API access?" prompt.
    ///
    /// See `proOAuth2Stdin` for the COW residual-limitation note that applies equally here.
    static func schoolStdin(networkID: String, apiKey: String) -> Data {
        var data = Data()
        data.append(contentsOf: networkID.utf8)
        data.append(0x0A)
        data.append(contentsOf: apiKey.utf8)
        data.append(0x0A)
        data.append(contentsOf: "n\n".utf8)
        return data
    }

    func validateRegisteredProfile() async {
        validationOutput.removeAll()
        validationExitCode = nil
        connectionValidated = false
        connectionCheck = nil
        lastError = nil

        let profile = profileName.trimmed
        guard ProfileService.isValid(profile) else {
            lastError = FlowError.invalidProfile.localizedDescription
            return
        }

        isValidatingConnection = true
        defer { isValidatingConnection = false }

        let exit: Int32
        do {
            exit = try await CLIBridge().validateConnection(profile: profile) { [weak self] line in
                Task { @MainActor in self?.validationOutput.append(line) }
            }
        } catch {
            validationExitCode = -1
            lastError = error.localizedDescription
            return
        }

        validationExitCode = exit
        guard exit == 0 else {
            lastError = "jamf-cli config validate failed for \(profile). Review the URL, "
                + "client ID, secret, and API role privileges, then retry."
            return
        }
        guard proConnectionType == .platformGateway else {
            connectionValidated = true
            return
        }
        applyConnectionCheck(await runConnectionCheck(profile: profile))
    }

    private func runConnectionCheck(profile: String) async -> ConnectionCheck.Verdict {
        guard let binary = ExecutableLocator.locate("jamf-cli"),
              let runner = ConnectionCheck.liveRunner() else {
            return .undecided(exitCode: nil)
        }
        let specNames = JamfCLIInstaller.supportsSpecDerivedNames(
            await installedCLIVersion(binary: binary)
        )
        return await ConnectionCheck.run(profile: profile, specNames: specNames, runner: runner)
    }

    /// A rejected or unconfirmed ID stays unvalidated; an ID the gateway recognised validates even
    /// when no Jamf Pro answered, which the banner reports as a warning.
    func applyConnectionCheck(_ verdict: ConnectionCheck.Verdict) {
        connectionCheck = verdict
        switch verdict {
        case .accepted, .noJamfPro: connectionValidated = true
        case .rejectedID, .undecided: connectionValidated = false
        }
    }

    /// "Continue without validating" after a failed validation. For a Platform API profile,
    /// not after the gateway rejected the ID (spec §10.4).
    var offersContinueWithoutValidating: Bool {
        guard !connectionValidated, canAdvance, let exit = validationExitCode else { return false }
        guard proConnectionType == .platformGateway, exit == 0 else { return exit != 0 }
        if case .undecided = connectionCheck { return true }
        return false
    }

    func scaffoldCSV(from url: URL) async {
        selectedCSVURL = nil
        csvScaffolded = false
        csvMappingSkipped = false
        csvOutput.removeAll()
        lastError = nil

        do {
            let csvURL = try validatedCSVURL(url)
            guard let workspace = workspaceURL else { throw FlowError.missingWorkspace }
            let profile = profileName.trimmed
            guard ProfileService.isValid(profile) else { throw FlowError.invalidProfile }

            selectedCSVURL = csvURL
            isScaffoldingCSV = true
            defer { isScaffoldingCSV = false }

            let outputConfig = workspace.appendingPathComponent("config.yaml")
            // It may be a config.yaml typed by hand, so it is copied aside first.
            try keepCopy(of: outputConfig)
            // Remove any prior attempt or skip-seeded config so the user can
            // re-enter the mapping step without leaving a half-written file.
            try? FileManager.default.removeItem(at: outputConfig)

            csvOutput.append(.init(timestamp: Date(), level: .info, text: "[info] reading CSV headers…"))
            let result = try ScaffoldService.matchColumns(from: csvURL, profile: profile)

            let familyLabel: String
            let matchedCount: Int
            switch result.family {
            case .mobile:
                familyLabel = "mobile device export"
                matchedCount = result.mobileColumns.count
            case .computers:
                familyLabel = "computer export"
                matchedCount = result.columns.count + result.complianceColumns.count
            case nil:
                familyLabel = "export (family unknown)"
                matchedCount = result.columns.count + result.complianceColumns.count
            }
            csvOutput.append(.init(
                timestamp: Date(), level: .ok,
                text: "[ok] Detected \(familyLabel) — matched \(matchedCount) column(s)"
            ))

            try ScaffoldService.writeConfig(to: outputConfig, result: result, profile: profile)
            SharedConfigPin.confirmWrittenConfig(at: outputConfig, profile: profile)
            csvOutput.append(.init(
                timestamp: Date(), level: .ok,
                text: "[ok] config.yaml written to \(outputConfig.lastPathComponent)"
            ))
            csvScaffolded = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Seed a minimal `config.yaml` so the user can skip CSV mapping and still produce
    /// a working workspace.
    func skipCSVMapping() async {
        selectedCSVURL = nil
        csvScaffolded = false
        csvMappingSkipped = false
        csvOutput.removeAll()
        lastError = nil

        let profile = profileName.trimmed
        guard ProfileService.isValid(profile) else {
            lastError = FlowError.invalidProfile.localizedDescription
            return
        }
        guard let workspace = workspaceURL else {
            lastError = FlowError.missingWorkspace.localizedDescription
            return
        }

        isSkippingCSVMapping = true
        defer { isSkippingCSVMapping = false }

        let outputConfig = workspace.appendingPathComponent("config.yaml")
        csvOutput.append(.init(timestamp: Date(), level: .info, text: "[info] writing minimal config.yaml…"))
        do {
            try keepCopy(of: outputConfig)
            try ScaffoldService.writeMinimalConfig(to: outputConfig, profile: profile)
            SharedConfigPin.confirmWrittenConfig(at: outputConfig, profile: profile)
            csvOutput.append(.init(
                timestamp: Date(), level: .ok,
                text: "[ok] minimal config.yaml written — jamf-cli data is enough; add a CSV "
                    + "later from Data Sources for per-device sheets"
            ))
            csvMappingSkipped = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Copies an existing config.yaml aside before setup replaces it, and says where.
    private func keepCopy(of config: URL) throws {
        guard let backup = try ConfigService.backUp(config) else { return }
        csvOutput.append(.init(
            timestamp: Date(), level: .info,
            text: "[info] kept a copy of the existing config.yaml as \(backup.lastPathComponent)"
        ))
    }

    /// One first-report stage (collect or generate) for a profile, streaming log lines.
    typealias FirstReportStep = (
        String, @escaping @Sendable (CLIBridge.LogLine) -> Void
    ) async throws -> Int32

    /// Runs the first report. The Jamf Pro path collects (refresh + inventory
    /// tiers only) before generating, so a fresh workspace with no CSV has
    /// cached data to render — `generate` alone throws `noCachedData` on a
    /// brand-new workspace. The per-device scan tier is skipped here so a
    /// large fleet's first report doesn't wait on it; it runs later on
    /// schedule or via Collect now. The Jamf School path is unchanged:
    /// `schoolGenerate` fetches its own data at generate time.
    ///
    /// `collect` / `generate` default to the real `CLIBridge` calls; tests
    /// inject spies to prove ordering without spawning jamf-cli.
    func runFirstReport(
        workspaceStore: WorkspaceStore,
        collect: @escaping FirstReportStep = { profile, onLine in
            try await CLIBridge().collect(
                profile: profile, tiers: [.refresh, .inventory], force: true, onLine: onLine
            )
        },
        generate: @escaping FirstReportStep = { profile, onLine in
            try await CLIBridge.holdingGenerate {
                try await CLIBridge().generate(profile: profile, csvPath: nil, onLine: onLine)
            }
        }
    ) async {
        firstReportOutput.removeAll()
        firstReportExitCode = nil
        lastError = nil

        isRunningFirstReport = true
        defer { isRunningFirstReport = false }

        let profile = profileName.trimmed
        let onLine: @Sendable (CLIBridge.LogLine) -> Void = { [weak self] line in
            Task { @MainActor in self?.firstReportOutput.append(line) }
        }

        if productPath == .school {
            let exit: Int32
            do {
                exit = try await CLIBridge().schoolGenerate(
                    profile: profile, csvPath: nil, onLine: onLine)
            } catch {
                firstReportExitCode = -1
                lastError = error.localizedDescription
                return
            }
            finishFirstReport(exit: exit, workspaceStore: workspaceStore)
            return
        }

        let collectExit: Int32
        do {
            collectExit = try await collect(profile, onLine)
        } catch {
            firstReportExitCode = -1
            lastError = error.localizedDescription
            return
        }
        guard collectExit == 0 else {
            firstReportExitCode = collectExit
            lastError = "Collect exited \(collectExit) — check the log above."
            return
        }

        let exit: Int32
        do {
            exit = try await generate(profile, onLine)
        } catch {
            firstReportExitCode = -1
            lastError = error.localizedDescription
            return
        }
        finishFirstReport(exit: exit, workspaceStore: workspaceStore)
    }

    /// Shared "generate finished" bookkeeping for both product paths.
    private func finishFirstReport(exit: Int32, workspaceStore: WorkspaceStore) {
        firstReportExitCode = exit
        if exit == 0 {
            finishSetup(in: workspaceStore)
        } else {
            lastError = "Generate exited \(exit) — check the log above."
        }
    }

    /// Point the app at the profile setup just created. Demo mode is left
    /// through `setDemoMode(false)`: clearing its flag directly, as setup did,
    /// skipped the cleanup of what earlier builds wrote under the demo
    /// profile. The exception is a new profile named like the demo's, whose
    /// fresh workspace and schedules that cleanup would delete.
    func finishSetup(in workspaceStore: WorkspaceStore) {
        if workspaceStore.demoMode && profileName.trimmed != DemoData.org.profile {
            workspaceStore.setDemoMode(false)
        } else {
            UserDefaults.standard.removeObject(forKey: WorkspaceStore.forceDemoModeKey)
            workspaceStore.reloadFromDisk()
        }
    }

    /// Verifies the jamf-cli binary's code signature before credentials are passed to it.
    ///
    /// Extracted from `registerJamfCLIProfile` so the gate logic can be exercised
    /// in tests without spawning a PTY or requiring a live jamf-cli binary. The
    /// defaulted parameters reflect production behaviour; tests override them.
    ///
    /// - Parameters:
    ///   - binary: The resolved URL of the jamf-cli binary to inspect.
    ///   - enforce: Whether the gate is active. Defaults to `JamfCLIIdentity.enforceSignatureCheck`.
    ///   - expectedTeamID: The Team ID the binary must be signed by. Defaults to
    ///     `JamfCLIIdentity.expectedTeamID`.
    ///   - verify: Closure that performs the actual signature check. Defaults to
    ///     `CodeSignVerifier.verify(url:expectedTeamID:)`.
    /// - Throws: `FlowError.processFailed` when enforcement is on and verification fails.
    ///
    /// `nonisolated`, so `runWithPTY` can repeat the gate at launch off the main actor.
    nonisolated static func signatureGate(
        binary: URL,
        enforce: Bool = JamfCLIIdentity.enforceSignatureCheck,
        expectedTeamID: String? = JamfCLIIdentity.expectedTeamID,
        verify: (URL, String) -> Bool = { CodeSignVerifier.verify(url: $0, expectedTeamID: $1) }
    ) throws {
        if enforce {
            guard let teamID = expectedTeamID, verify(binary, teamID) else {
                throw FlowError.processFailed(
                    "jamf-cli signature verification failed — binary may be untrusted"
                )
            }
        } else {
            // SF-7: audit-log the skip so reviewers can confirm which gate was off.
            AppLogger.auth.info(
                "OnboardingFlow: codesign verification skipped (enforce=false, teamID=\(expectedTeamID == nil ? "nil" : "set", privacy: .public))"
            )
        }
    }

    var isGatewayURLValid: Bool { normalizedURL(gatewayURL.trimmed) != nil }
    var isProtectURLValid: Bool { normalizedURL(protectURL.trimmed) != nil }
    var isSchoolURLValid: Bool { normalizedURL(schoolURL.trimmed) != nil }

    private var normalizedJamfURL: URL? { normalizedURL(jamfURL.trimmed) }

    private func normalizedURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host,
              !host.isEmpty,
              let url = components.url
        else { return nil }
        return url
    }

    private func validatedCSVURL(_ url: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard allowedCSVRoots.contains(where: { resolved.path.hasPrefix($0.path + "/") || resolved.path == $0.path })
        else {
            throw FlowError.csvOutsideAllowedZones
        }
        return resolved
    }

    /// P9-A-07: Accept finalized credential bytes from `SecureSecretField`.
    ///
    /// The field calls this once on focus-loss or Return, passing UTF-8 bytes
    /// read directly from `NSSecureTextField.stringValue`. The public
    /// `clientSecret` property is updated only at finalization — not on every
    /// keystroke — minimizing the window during which `@Observable` diffing can
    /// snapshot the in-progress string.
    func setClientSecret(_ data: Data) {
        clientSecret = String(data: data, encoding: .utf8) ?? ""
    }

    private func clearClientSecret() {
        let count = clientSecret.count
        if count > 0 {
            clientSecret = String(repeating: "\0", count: count)
        }
        clientSecret.removeAll(keepingCapacity: false)
        clientSecret = ""
        secretFieldHasText = false
    }

    // MARK: - Platform Gateway credential management

    func setPlatformClientSecret(_ data: Data) {
        platformClientSecret = String(data: data, encoding: .utf8) ?? ""
    }

    private func clearPlatformSecrets() {
        let count = platformClientSecret.count
        if count > 0 {
            platformClientSecret = String(repeating: "\0", count: count)
        }
        platformClientSecret.removeAll(keepingCapacity: false)
        platformClientSecret = ""
        platformSecretFieldHasText = false
    }

    // MARK: - Protect credential management

    func setProtectClientSecret(_ data: Data) {
        protectClientSecret = String(data: data, encoding: .utf8) ?? ""
    }

    private func clearProtectSecret() {
        let count = protectClientSecret.count
        if count > 0 {
            protectClientSecret = String(repeating: "\0", count: count)
        }
        protectClientSecret.removeAll(keepingCapacity: false)
        protectClientSecret = ""
        protectSecretFieldHasText = false
    }

    // MARK: - School credential management

    func setSchoolAPIKey(_ data: Data) {
        schoolAPIKey = String(data: data, encoding: .utf8) ?? ""
    }

    private func clearSchoolAPIKey() {
        let count = schoolAPIKey.count
        if count > 0 {
            schoolAPIKey = String(repeating: "\0", count: count)
        }
        schoolAPIKey.removeAll(keepingCapacity: false)
        schoolAPIKey = ""
        schoolAPIKeyFieldHasText = false
    }

    private func clearProductSecrets() {
        clearProtectSecret()
        clearSchoolAPIKey()
    }

    /// Wipe every typed-but-unsubmitted secret. Credential sheets call this on
    /// dismissal: the per-register defers only run when a register was
    /// attempted, so a cancel would otherwise release plaintext un-zeroed.
    func clearAllSecrets() {
        clearClientSecret()
        clearPlatformSecrets()
        clearProductSecrets()
    }

    // MARK: - Config wiring helpers

    /// `protect.enabled` and `protect.profile`, through the scoped writer: every other key in
    /// the block stays, and a comment there is copied out first and named in the report.
    @discardableResult
    internal func writeProtectConfig(
        profileSlug: String, protectProfileName: String
    ) throws -> ConfigSaveReport {
        try Self.writeProductBlock("protect", profile: protectProfileName, for: profileSlug)
    }

    /// `school_cli.enabled` and `school_cli.profile`, the same way as `writeProtectConfig`.
    @discardableResult
    internal func writeSchoolConfig(
        profileSlug: String, schoolProfileName: String
    ) throws -> ConfigSaveReport {
        try Self.writeProductBlock("school_cli", profile: schoolProfileName, for: profileSlug)
    }

    private static func writeProductBlock(
        _ key: String, profile name: String, for profileSlug: String
    ) throws -> ConfigSaveReport {
        try ConfigService.saveBlock(key: key, profile: profileSlug) { root in
            var block = root.value(for: key)?.mapping ?? YAMLCodec.YAMLMapping(entries: [])
            block.set("enabled", value: .scalar(.bool(true)))
            block.set("profile", value: .scalar(.string(name)))
            root.set(key, value: .mapping(block))
        }.report
    }

    // MARK: - Per-product redaction helpers

    private func platformRedactedOutput(_ text: String) -> String {
        var redacted = text
        if !platformClientSecret.isEmpty {
            redacted = redacted.replacingOccurrences(of: platformClientSecret, with: "[redacted]")
        }
        let id = platformClientID.trimmed
        if id.count >= 8 {
            redacted = redacted.replacingOccurrences(of: id, with: "[redacted]")
        }
        return redacted
    }

    private func protectRedactedOutput(_ text: String) -> String {
        var redacted = text
        if !protectClientSecret.isEmpty {
            redacted = redacted.replacingOccurrences(of: protectClientSecret, with: "[redacted]")
        }
        let id = protectClientID.trimmed
        if id.count >= 8 {
            redacted = redacted.replacingOccurrences(of: id, with: "[redacted]")
        }
        return redacted
    }

    private func schoolRedactedOutput(_ text: String) -> String {
        var redacted = text
        if !schoolAPIKey.isEmpty {
            redacted = redacted.replacingOccurrences(of: schoolAPIKey, with: "[redacted]")
        }
        let id = schoolNetworkID.trimmed
        if id.count >= 4 {
            redacted = redacted.replacingOccurrences(of: id, with: "[redacted]")
        }
        return redacted
    }

    private func redactedCredentialOutput(_ text: String) -> String {
        var redacted = text
        if !clientSecret.isEmpty {
            redacted = redacted.replacingOccurrences(of: clientSecret, with: "[redacted]")
        }
        let trimmedClientID = clientID.trimmed
        if trimmedClientID.count >= 8 {
            redacted = redacted.replacingOccurrences(of: trimmedClientID, with: "[redacted]")
        }
        return redacted
    }

    struct PTYResult: Sendable {
        let exitCode: Int32
        let combined: String
    }

    /// Seconds `runWithPTY` waits for output before it writes the next line anyway.
    nonisolated static let ptyPromptGrace: TimeInterval = 2

    /// `data` cut after each newline, so each value can go in on its own; a last value with no
    /// newline is kept as is.
    nonisolated static func ptyLines(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0x0A {
            lines.append(data[start...index])
            start = data.index(after: index)
        }
        if start < data.endIndex { lines.append(data[start...]) }
        return lines
    }

    /// Run a child process with stdin/stdout/stderr attached to a pty so commands
    /// that probe for a controlling terminal (e.g. `jamf-cli config add-profile`,
    /// which reads credentials via `golang.org/x/term`) work without launching a
    /// separate Terminal window.
    ///
    /// The signature gate runs again here, on the symlink-resolved path that is then launched,
    /// immediately before `process.run()`: the registration-time gate is followed by a
    /// version probe of up to 60 s and the PTY setup, which is long enough to swap the binary.
    ///
    /// `timeout` bounds the whole run: a child still running then is terminated and the call
    /// throws `FlowError.processFailed("jamf-cli did not finish within N s")`. `stdin` is written
    /// one line at a time, in the order given: a line goes in once the child has printed
    /// something since the previous line, or `ptyPromptGrace` seconds after the previous line
    /// for a child that prints no prompt. The order is the caller's; it is not matched to prompt
    /// text.
    nonisolated static func runWithPTY(
        executable: URL,
        arguments: [String],
        stdin: Data,
        enforce: Bool = JamfCLIIdentity.enforceSignatureCheck,
        expectedTeamID: String? = JamfCLIIdentity.expectedTeamID,
        verify: @escaping @Sendable (URL, String) -> Bool = {
            CodeSignVerifier.verify(url: $0, expectedTeamID: $1)
        },
        timeout: TimeInterval = 120
    ) async throws -> PTYResult {
        try await Task.detached(priority: .userInitiated) {
            let master = Darwin.posix_openpt(O_RDWR | O_NOCTTY)
            guard master >= 0 else {
                throw FlowError.processFailed("posix_openpt failed: errno \(errno)")
            }
            guard Darwin.grantpt(master) == 0 else {
                Darwin.close(master)
                throw FlowError.processFailed("grantpt failed: errno \(errno)")
            }
            guard Darwin.unlockpt(master) == 0 else {
                Darwin.close(master)
                throw FlowError.processFailed("unlockpt failed: errno \(errno)")
            }
            guard let slaveCStr = Darwin.ptsname(master) else {
                Darwin.close(master)
                throw FlowError.processFailed("ptsname failed: errno \(errno)")
            }
            let slavePath = String(cString: slaveCStr)
            let slave = Darwin.open(slavePath, O_RDWR | O_NOCTTY)
            guard slave >= 0 else {
                Darwin.close(master)
                throw FlowError.processFailed("open(slave) failed: errno \(errno)")
            }

            // Disable echo on the slave so the secret written to stdin is not
            // reflected back into the captured PTY output buffer. Without this
            // the no-leak guarantee depends entirely on string-match redaction.
            var term = termios()
            if Darwin.tcgetattr(slave, &term) == 0 {
                term.c_lflag &= ~tcflag_t(ECHO)
                _ = Darwin.tcsetattr(slave, TCSANOW, &term)
            }

            let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
            let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)

            let process = Process()
            let launchURL = executable.resolvingSymlinksInPath()
            process.executableURL = launchURL
            process.arguments = arguments
            // SF-10/B-13: this is the most security-sensitive Process site —
            // it streams the user's client secret over the PTY into jamf-cli.
            // A hostile DYLD_INSERT_LIBRARIES, SSL_CERT_FILE, or rogue
            // JAMF_CLI_* in the parent env could redirect or capture the
            // secret. Pin a minimal env before launch.
            process.environment = CLIBridge.environmentForJamfCLI()
            process.standardInput = slaveHandle
            process.standardOutput = slaveHandle
            process.standardError = slaveHandle
            let box = TimedProcessBox()
            box.set(process)
            process.terminationHandler = { [box] _ in box.disarmTimeout() }

            do {
                try signatureGate(
                    binary: launchURL, enforce: enforce,
                    expectedTeamID: expectedTeamID, verify: verify)
            } catch {
                Darwin.close(slave)
                throw error
            }
            do {
                try process.run()
            } catch {
                Darwin.close(slave)
                throw FlowError.processFailed("launch failed: \(error.localizedDescription)")
            }

            box.armTimeout(timeout)

            // Close the slave end in the parent so reads on master see EOF when
            // the child exits.
            Darwin.close(slave)

            // Drain the master in a background task; jamf-cli writes prompts
            // before consuming stdin, so we cannot block on a single sequential
            // read/write pairing. read(2) rather than FileHandle.availableData: the
            // loop must end on its own when the child is gone (EOF, or EIO once no
            // slave end is open), because closing the handle under a blocked
            // reader raises NSFileHandleOperationException on macOS 26.
            let collector = PTYOutputCollector()
            let drain = Task.detached(priority: .userInitiated) {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(master, $0.baseAddress, $0.count)
                    }
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { break }
                    await collector.append(Data(buffer[0..<count]))
                }
            }

            // Push credentials in, one line per prompt. The child's term reader expects "\n"
            // between values. If the write end has already closed (process exited early),
            // suppress EPIPE.
            var seenBytes = 0
            for line in ptyLines(stdin) {
                let deadline = Date().addingTimeInterval(ptyPromptGrace)
                while process.isRunning, !box.didTimeOut, Date() < deadline,
                    await collector.byteCount() <= seenBytes {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                guard process.isRunning, !box.didTimeOut else { break }
                // Counted before the write, so a prompt that arrives during it still counts.
                seenBytes = await collector.byteCount()
                line.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                    guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
                    _ = Darwin.write(master, base, bytes.count)
                }
            }

            process.waitUntilExit()
            // The child's exit closes the last slave end, which ends the drain.
            await drain.value
            try? masterHandle.close()
            if box.didTimeOut {
                throw FlowError.processFailed(
                    "jamf-cli did not finish within \(Int(timeout.rounded())) s")
            }

            let combined = await collector.snapshot()
            return PTYResult(exitCode: process.terminationStatus, combined: combined)
        }.value
    }
}

private actor PTYOutputCollector {
    private var buffer = Data()

    func append(_ data: Data) {
        buffer.append(data)
    }

    func byteCount() -> Int {
        buffer.count
    }

    func snapshot() -> String {
        String(data: buffer, encoding: .utf8) ?? ""
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
