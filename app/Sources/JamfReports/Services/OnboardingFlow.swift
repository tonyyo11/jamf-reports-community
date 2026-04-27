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
    var firstReportExitCode: Int32?

    var isRegisteringProfile = false
    var isValidatingConnection = false
    var isScaffoldingCSV = false
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
            csvScaffolded && !isScaffoldingCSV
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

        let configURL = workspace.appendingPathComponent("config.yaml")
        if !fm.fileExists(atPath: configURL.path) {
            if let bundled = Bundle.module.url(forResource: "config.example", withExtension: "yaml") {
                try fm.copyItem(at: bundled, to: configURL)
            } else {
                try Self.minimalConfig(profile: profile).write(
                    to: configURL,
                    atomically: true,
                    encoding: .utf8
                )
            }
            try? fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: configURL.path)
        }

        workspaceCreated = true
        lastError = nil
    }

    func registerJamfCLIProfile() async throws {
        guard let binary = CLIBridge().locate("jamf-cli") else { throw FlowError.missingJamfCLI }
        guard let url = normalizedJamfURL else { throw FlowError.invalidJamfURL }
        guard isProfileNameValid else { throw FlowError.invalidProfile }

        isRegisteringProfile = true
        defer { isRegisteringProfile = false }

        var secretData = Data((clientSecret + "\n").utf8)
        defer {
            secretData.resetBytes(in: 0..<secretData.count)
            clearClientSecret()
        }

        let result = try await Self.runProcess(
            executable: binary,
            arguments: [
                "profile", "add",
                "--name", profileName.trimmed,
                "--url", url.absoluteString,
                "--client-id", clientID.trimmed,
            ],
            stdin: secretData
        )

        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmed
            throw FlowError.processFailed(stderr.isEmpty ? "jamf-cli exited \(result.exitCode)." : stderr)
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
        csvOutput.removeAll()
        lastError = nil

        do {
            let csvURL = try validatedCSVURL(url)
            guard let workspace = workspaceURL else { throw FlowError.missingWorkspace }
            let bridge = CLIBridge()
            guard let command = bridge.resolveJRCCommand() else { throw FlowError.missingJRC }

            selectedCSVURL = csvURL
            isScaffoldingCSV = true
            defer { isScaffoldingCSV = false }

            let outputConfig = workspace.appendingPathComponent("config.yaml")
            let exit = await bridge.run(
                executable: command.executable,
                arguments: command.arguments + ["scaffold", "--csv", csvURL.path, "--out", outputConfig.path]
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

    private static func minimalConfig(profile: String) -> String {
        """
        # Generated by Jamf Reports onboarding.
        jamf_cli:
          data_dir: "jamf-cli-data"
          profile: "\(profile)"
          use_cached_data: true
          allow_live_overview: true

        output:
          output_dir: "Generated Reports"
          timestamp_outputs: true
          archive_enabled: true
          archive_dir: ""
          keep_latest_runs: 10

        charts:
          enabled: true
          save_png: true
          embed_in_xlsx: true
          historical_csv_dir: "snapshots"
          archive_current_csv: true

        columns: {}
        security_agents: []
        custom_eas: []
        compliance:
          failures_count_column: ""
          failures_list_column: ""
        """
    }

    private struct ProcessResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private nonisolated static func runProcess(
        executable: URL,
        arguments: [String],
        stdin: Data
    ) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            let input = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = input

            try process.run()
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()

            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            let err = stderr.fileHandleForReading.readDataToEndOfFile()
            return ProcessResult(
                exitCode: process.terminationStatus,
                stdout: String(data: out, encoding: .utf8) ?? "",
                stderr: String(data: err, encoding: .utf8) ?? ""
            )
        }.value
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
