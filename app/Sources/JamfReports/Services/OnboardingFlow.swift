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
        case missingJRC
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
            case .missingJRC:
                "Could not find jrc on PATH."
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

        // config.yaml is intentionally not written here. The CSV mapping step
        // produces it via `jrc scaffold`; the skip path produces it via
        // `jrc workspace-init`. Writing a placeholder config here would block
        // scaffold (which refuses to overwrite an existing file).
        workspaceCreated = true
        lastError = nil
    }

    func registerJamfCLIProfile() async throws {
        guard let binary = CLIBridge().locate("jamf-cli") else { throw FlowError.missingJamfCLI }
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
            let combined = result.combined.trimmed
            throw FlowError.processFailed(combined.isEmpty ? "jamf-cli exited \(result.exitCode)." : combined)
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
            let bridge = CLIBridge()
            guard let command = bridge.resolveJRCCommand() else { throw FlowError.missingJRC }

            selectedCSVURL = csvURL
            isScaffoldingCSV = true
            defer { isScaffoldingCSV = false }

            let outputConfig = workspace.appendingPathComponent("config.yaml")
            // scaffold refuses to overwrite an existing file. Clear any prior
            // attempt or skip-seeded config so users can re-enter the mapping
            // step without leaving a half-written workspace behind.
            try? FileManager.default.removeItem(at: outputConfig)
            let exit = await bridge.run(
                executable: command.executable,
                arguments: command.arguments + [
                    "scaffold",
                    "--csv", csvURL.path,
                    "--out", outputConfig.path,
                    "--profile", profile,
                ]
            ) { [weak self] line in
                Task { @MainActor in self?.csvOutput.append(line) }
            }

            if exit == 0 {
                csvScaffolded = true
            } else {
                throw FlowError.processFailed("jrc scaffold exited \(exit).")
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Seed a minimal `config.yaml` via `jrc workspace-init` so the user can
    /// skip CSV mapping and still produce a working workspace.
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
        let bridge = CLIBridge()
        guard let command = bridge.resolveJRCCommand() else {
            lastError = FlowError.missingJRC.localizedDescription
            return
        }

        isSkippingCSVMapping = true
        defer { isSkippingCSVMapping = false }

        let parent = workspace.deletingLastPathComponent()
        let exit = await bridge.run(
            executable: command.executable,
            arguments: command.arguments + [
                "workspace-init",
                "--profile", profile,
                "--workspace-root", parent.path,
                "--workspace-name", workspace.lastPathComponent,
            ]
        ) { [weak self] line in
            Task { @MainActor in self?.csvOutput.append(line) }
        }

        if exit == 0 {
            csvMappingSkipped = true
        } else {
            lastError = "jrc workspace-init exited \(exit)."
        }
    }

    func runFirstReport(workspaceStore: WorkspaceStore) async {
        firstReportOutput.removeAll()
        firstReportExitCode = nil
        lastError = nil

        let bridge = CLIBridge()
        guard bridge.resolveJRCCommand() != nil else {
            lastError = FlowError.missingJRC.localizedDescription
            return
        }

        isRunningFirstReport = true
        defer { isRunningFirstReport = false }

        let exit = await bridge.generate(profile: profileName.trimmed, csvPath: nil) { [weak self] line in
            Task { @MainActor in self?.firstReportOutput.append(line) }
        }

        firstReportExitCode = exit
        if exit == 0 {
            workspaceStore.reloadFromDisk()
        } else {
            lastError = "jrc generate exited \(exit)."
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

    private func clearClientSecret() {
        let count = clientSecret.count
        clientSecret = String(repeating: "\0", count: count)
        clientSecret.removeAll(keepingCapacity: false)
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
