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
        case firstReport

        var id: Int { rawValue }
        var number: Int { rawValue + 1 }

        var label: String {
            switch self {
            case .welcome: "Welcome"
            case .installCLI: "Install jamf-cli"
            case .workspace: "Workspace"
            case .authenticate: "Authenticate"
            case .validate: "Validate"
            case .csvMapping: "CSV mapping"
            case .firstReport: "First report"
            }
        }
    }

    enum FlowError: LocalizedError {
        case invalidProfile
        case invalidJamfURL
        case missingJamfCLI
        case missingWorkspace
        case csvOutsideAllowedZones
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidProfile:
                "Profile names must start with a lowercase letter or number and use only lowercase letters, numbers, dots, underscores, or hyphens."
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

    var profileName = ""
    var jamfURL = ""
    var clientID = ""
    var clientSecret = ""

    /// PR-23 T-24: collection cadence preset chosen during onboarding.
    /// Applied to `config.yaml` once the CSV-mapping step writes it.
    /// Onboarding offers only On-prem / Cloud — Custom is opt-in later
    /// via Settings → Performance. Defaults to On-prem (conservative).
    var selectedCollectionPreset: CadencePreset = .onPrem

    var jamfCLIInstalled = false
    var jamfCLIVersion: String?
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
    var csvOutput: [CLIBridge.LogLine] = []
    var firstReportOutput: [CLIBridge.LogLine] = []

    private var installer = JamfCLIInstaller()

    // User data zones accepted by policy for the first CSV export.
    private var allowedCSVRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true),
        ]
    }

    init() {
        refreshJamfCLIStatus()
    }

    var canAdvance: Bool {
        switch currentStep {
        case .welcome:
            true
        case .installCLI:
            jamfCLIInstalled
        case .workspace:
            isProfileNameValid
        case .authenticate:
            isProfileNameValid && isJamfURLValid && !clientID.trimmed.isEmpty
                && !clientSecret.isEmpty && !isRegisteringProfile
        case .validate:
            profileRegistered && !isValidatingConnection
        case .csvMapping:
            (csvScaffolded || csvMappingSkipped) && !isScaffoldingCSV && !isSkippingCSVMapping
        case .firstReport:
            !isRunningFirstReport
        }
    }

    var isProfileNameValid: Bool {
        ProfileService.isValid(profileName.trimmed)
    }

    var isJamfURLValid: Bool {
        normalizedJamfURL != nil
    }

    var workspaceURL: URL? {
        ProfileService.workspaceURL(for: profileName.trimmed)
    }

    var workspacePreviewPath: String {
        "~/Jamf-Reports/\(profileName.trimmed.isEmpty ? "<profile>" : profileName.trimmed)/"
    }

    var brewCommand: String {
        installer.brewInstallCommand()
    }

    func refreshJamfCLIStatus() {
        installer = JamfCLIInstaller()
        jamfCLIInstalled = installer.isInstalled
        jamfCLIVersion = installer.installedVersion
    }

    func nextStep() {
        guard let next = Step(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
        lastError = nil
    }

    func previousStep() {
        guard let previous = Step(rawValue: currentStep.rawValue - 1) else { return }
        if currentStep == .authenticate {
            clearClientSecret()
        }
        currentStep = previous
        lastError = nil
    }

    func createWorkspace() throws {
        let profile = profileName.trimmed
        guard ProfileService.isValid(profile) else { throw FlowError.invalidProfile }
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            throw FlowError.invalidProfile
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
                AppLogger.engine.warning(
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
        guard let binary = CLIBridge().locate("jamf-cli") else { throw FlowError.missingJamfCLI }
        try verifyJamfCLISignatureGate(binary: binary)
        guard let url = normalizedJamfURL else { throw FlowError.invalidJamfURL }
        guard isProfileNameValid else { throw FlowError.invalidProfile }

        isRegisteringProfile = true
        defer { isRegisteringProfile = false }

        // jamf-cli config add-profile only reads the Client ID and Client Secret
        // from a controlling TTY (see golang.org/x/term). Allocate a pty so the
        // GUI can drive the prompts without launching an interactive terminal.
        // The "\n" terminator is what the term reader uses to delimit each value.
        var stdinData = Data((clientID.trimmed + "\n" + clientSecret + "\n").utf8)
        defer {
            stdinData.resetBytes(in: 0..<stdinData.count)
            clearClientSecret()
        }

        let result = try await Self.runWithPTY(
            executable: binary,
            arguments: [
                "config", "add-profile", profileName.trimmed,
                "--url", url.absoluteString,
                "--auth-method", "oauth2",
                "--no-color",
            ],
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
        lastError = nil
    }

    func validateRegisteredProfile() async {
        validationOutput.removeAll()
        validationExitCode = nil
        connectionValidated = false
        lastError = nil

        let profile = profileName.trimmed
        guard ProfileService.isValid(profile) else {
            lastError = FlowError.invalidProfile.localizedDescription
            return
        }

        isValidatingConnection = true
        defer { isValidatingConnection = false }

        let exit = await CLIBridge().validateConnection(profile: profile) { [weak self] line in
            Task { @MainActor in self?.validationOutput.append(line) }
        }

        validationExitCode = exit
        if exit == 0 {
            connectionValidated = true
        } else {
            lastError = "jamf-cli config validate failed for \(profile). Review the URL, client ID, secret, and API role privileges, then retry."
        }
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
            // Remove any prior attempt or skip-seeded config so the user can
            // re-enter the mapping step without leaving a half-written file.
            try? FileManager.default.removeItem(at: outputConfig)

            csvOutput.append(.init(timestamp: Date(), level: .info, text: "[info] reading CSV headers…"))
            let result = try ScaffoldService.matchColumns(from: csvURL, profile: profile)

            let matched = result.columns.count + result.complianceColumns.count
            csvOutput.append(.init(
                timestamp: Date(), level: .ok,
                text: "[ok] matched \(matched) column(s) from CSV"
            ))

            try ScaffoldService.writeConfig(to: outputConfig, result: result, profile: profile)
            csvOutput.append(.init(
                timestamp: Date(), level: .ok,
                text: "[ok] config.yaml written to \(outputConfig.lastPathComponent)"
            ))
            applySelectedPreset(profile: profile)
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
            try ScaffoldService.writeMinimalConfig(to: outputConfig, profile: profile)
            csvOutput.append(.init(
                timestamp: Date(), level: .ok,
                text: "[ok] config.yaml written — edit column mappings before running generate"
            ))
            applySelectedPreset(profile: profile)
            csvMappingSkipped = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// PR-23 T-24: stamp the onboarding preset choice into the freshly
    /// written `config.yaml`. Called only after a config-writing step
    /// succeeds, so `setCadencePreset` mutates a real file.
    ///
    /// A failure here is non-fatal: the workspace and config are already
    /// valid, and `CadenceResolver` defaults to on-prem when the
    /// `collect_cadence` block is absent. The operator can still set the
    /// preset later in Settings → Performance — so this warns rather than
    /// throwing and aborting onboarding.
    private func applySelectedPreset(profile: String) {
        do {
            try ConfigService.setCadencePreset(
                profile: profile, preset: selectedCollectionPreset
            )
            csvOutput.append(.init(
                timestamp: Date(), level: .ok,
                text: "[ok] cadence preset set to \(selectedCollectionPreset.displayName)"
            ))
        } catch {
            AppLogger.engine.warning(
                "OnboardingFlow: failed to apply cadence preset: \(error.localizedDescription, privacy: .private)"
            )
            csvOutput.append(.init(
                timestamp: Date(), level: .warn,
                text: "[warn] could not write cadence preset — set it later in Settings → Performance"
            ))
        }
    }

    func runFirstReport(workspaceStore: WorkspaceStore) async {
        firstReportOutput.removeAll()
        firstReportExitCode = nil
        lastError = nil

        let bridge = CLIBridge()

        isRunningFirstReport = true
        defer { isRunningFirstReport = false }

        let exit = await bridge.generate(profile: profileName.trimmed, csvPath: nil) { [weak self] line in
            Task { @MainActor in self?.firstReportOutput.append(line) }
        }

        firstReportExitCode = exit
        if exit == 0 {
            workspaceStore.reloadFromDisk()
        } else {
            lastError = "Generate exited \(exit) — check the log above."
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
    internal func verifyJamfCLISignatureGate(
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
            AppLogger.engine.info(
                "OnboardingFlow: codesign verification skipped (enforce=false, teamID=\(expectedTeamID == nil ? "nil" : "set", privacy: .public))"
            )
        }
    }

    private var normalizedJamfURL: URL? {
        let value = jamfURL.trimmed
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

    private struct PTYResult: Sendable {
        let exitCode: Int32
        let combined: String
    }

    /// Run a child process with stdin/stdout/stderr attached to a pty so commands
    /// that probe for a controlling terminal (e.g. `jamf-cli config add-profile`,
    /// which reads credentials via `golang.org/x/term`) work without launching a
    /// separate Terminal window.
    private nonisolated static func runWithPTY(
        executable: URL,
        arguments: [String],
        stdin: Data
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

            let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
            let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)

            let process = Process()
            process.executableURL = executable
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

            do {
                try process.run()
            } catch {
                Darwin.close(slave)
                throw FlowError.processFailed("launch failed: \(error.localizedDescription)")
            }

            // Close the slave end in the parent so reads on master see EOF when
            // the child exits.
            Darwin.close(slave)

            // Drain the master in a background task; jamf-cli writes prompts
            // before consuming stdin, so we cannot block on a single sequential
            // read/write pairing.
            let collector = PTYOutputCollector()
            let drain = Task.detached(priority: .userInitiated) {
                while true {
                    let chunk = masterHandle.availableData
                    if chunk.isEmpty { break }
                    await collector.append(chunk)
                }
            }

            // Push credentials in. The child's term reader expects "\n" between
            // values. If the write end has already closed (process exited
            // early), suppress EPIPE.
            stdin.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
                _ = Darwin.write(master, base, bytes.count)
            }

            process.waitUntilExit()
            // Closing the master ends the read loop in the drain task.
            try? masterHandle.close()
            await drain.value

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

    func snapshot() -> String {
        String(data: buffer, encoding: .utf8) ?? ""
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
