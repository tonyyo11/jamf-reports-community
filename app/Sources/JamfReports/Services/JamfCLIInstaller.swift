import Darwin
import Foundation

private final class ProcessPipeDrainer: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var isFinishing = false

    init(pipe: Pipe) {
        handle = pipe.fileHandleForReading
    }

    func start() {
        handle.readabilityHandler = { [weak self] fileHandle in
            self?.drainAvailableData(from: fileHandle)
        }
    }

    func cancel() {
        handle.readabilityHandler = nil
    }

    func finish() -> Data {
        handle.readabilityHandler = nil

        lock.lock()
        isFinishing = true
        let remaining = handle.readDataToEndOfFile()
        if !remaining.isEmpty {
            buffer.append(remaining)
        }
        let data = buffer
        lock.unlock()

        return data
    }

    private func drainAvailableData(from fileHandle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }

        guard !isFinishing else { return }

        let data = fileHandle.availableData
        guard !data.isEmpty else {
            fileHandle.readabilityHandler = nil
            return
        }

        buffer.append(data)
    }
}

@MainActor
final class JamfCLIInstaller {
    enum InstallSource: String, Sendable {
        case homebrew
        case githubRelease
        case unknown

        var label: String {
            switch self {
            case .homebrew:      "Homebrew"
            case .githubRelease: "GitHub release"
            case .unknown:       "Unknown source"
            }
        }
    }

    struct Installation: Sendable {
        let path: String
        let resolvedPath: String
        let version: String?
        let source: InstallSource
        let brewPath: String?
    }

    struct UpdateResult: Sendable {
        let succeeded: Bool
        let message: String
    }

    private struct CommandResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var combinedOutput: String {
            [stdout, stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    private static let githubLatestReleaseURL =
        URL(string: "https://api.github.com/repos/Jamf-Concepts/jamf-cli/releases/latest")!

    private static let githubReleasesURL =
        URL(string: "https://github.com/Jamf-Concepts/jamf-cli/releases")!

    private var versionChecked = false
    private var cachedVersion: String?

    var isInstalled: Bool {
        Self.currentInstallation() != nil
    }

    var installedVersion: String? {
        if versionChecked { return cachedVersion }
        versionChecked = true

        cachedVersion = Self.currentInstallation()?.version
        return cachedVersion
    }

    static func installedVersion() -> String? {
        currentInstallation()?.version
    }

    static func currentInstallation() -> Installation? {
        let brew = locateBrew()
        if let located = ExecutableLocator.locate("jamf-cli") {
            let source = installSource(for: located)
            let brewPath = source == .homebrew ? brew?.path : nil
            return Installation(
                path: located.path,
                resolvedPath: located.resolvingSymlinksInPath().path,
                version: installedVersion(at: located),
                source: source,
                brewPath: brewPath
            )
        }

        if let brew,
           let linked = homebrewLinkedJamfCLI(using: brew) {
            return Installation(
                path: linked.path,
                resolvedPath: linked.resolvingSymlinksInPath().path,
                version: installedVersion(at: linked),
                source: .homebrew,
                brewPath: brew.path
            )
        }
        return nil
    }

    static func installedVersion(at binary: URL) -> String? {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--version"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        let text = [
            String(data: out, encoding: .utf8),
            String(data: err, encoding: .utf8),
        ]
        .compactMap { $0 }
        .joined(separator: "\n")

        return parseVersion(from: text)
    }

    func checkForUpdate() async -> UpdateResult {
        guard let installation = Self.currentInstallation() else {
            return UpdateResult(succeeded: false, message: "jamf-cli is not installed.")
        }

        switch installation.source {
        case .homebrew:
            return await Self.checkHomebrewUpdate(for: installation)
        case .githubRelease:
            return await Self.checkGitHubUpdate(for: installation)
        case .unknown:
            return UpdateResult(
                succeeded: false,
                message: "jamf-cli was found at \(installation.path), but the app cannot identify how it was installed."
            )
        }
    }

    func update() async -> UpdateResult {
        guard let installation = Self.currentInstallation() else {
            return UpdateResult(succeeded: false, message: "jamf-cli is not installed.")
        }

        switch installation.source {
        case .homebrew:
            return await Self.updateHomebrew(installation)
        case .githubRelease:
            return await Self.updateGitHubRelease(installation)
        case .unknown:
            return UpdateResult(
                succeeded: false,
                message: "Refusing to update unknown jamf-cli install at \(installation.path)."
            )
        }
    }

    func brewInstallCommand() -> String {
        "brew install Jamf-Concepts/tap/jamf-cli"
    }

    private static func installSource(for binary: URL) -> InstallSource {
        let path = binary.path
        let resolved = binary.resolvingSymlinksInPath().path
        if isHomebrewManaged(path) || isHomebrewManaged(resolved) {
            return .homebrew
        }
        if path == "/usr/local/bin/jamf-cli" || path == "/opt/homebrew/bin/jamf-cli" {
            return .githubRelease
        }
        return .unknown
    }

    private static func isHomebrewManaged(_ path: String) -> Bool {
        path.contains("/Cellar/jamf-cli/")
            || path.contains("/opt/homebrew/opt/jamf-cli/")
            || path.contains("/usr/local/opt/jamf-cli/")
    }

    private static func locateBrew() -> URL? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func homebrewLinkedJamfCLI(using brew: URL) -> URL? {
        let result = runProcessSync(executable: brew, arguments: ["--prefix", "jamf-cli"])
        guard result.exitCode == 0 else { return nil }
        let prefix = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return nil }
        let candidate = URL(fileURLWithPath: prefix)
            .appendingPathComponent("bin")
            .appendingPathComponent("jamf-cli")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    private static func checkHomebrewUpdate(for installation: Installation) async -> UpdateResult {
        guard let brew = brewExecutable(for: installation) else {
            return UpdateResult(succeeded: false, message: "Homebrew install detected, but brew was not found.")
        }
        let update = await runProcess(executable: brew, arguments: ["update"])
        guard update.exitCode == 0 else {
            return UpdateResult(
                succeeded: false,
                message: "brew update failed: \(summarize(update))"
            )
        }

        let outdated = await runProcess(executable: brew, arguments: ["outdated", "--quiet", "jamf-cli"])
        let output = outdated.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            return UpdateResult(
                succeeded: true,
                message: "Homebrew jamf-cli is current at \(installation.version ?? "unknown")."
            )
        }
        return UpdateResult(succeeded: true, message: "Homebrew update available for jamf-cli.")
    }

    private static func updateHomebrew(_ installation: Installation) async -> UpdateResult {
        guard let brew = brewExecutable(for: installation) else {
            return UpdateResult(succeeded: false, message: "Homebrew install detected, but brew was not found.")
        }
        let update = await runProcess(executable: brew, arguments: ["update"])
        guard update.exitCode == 0 else {
            return UpdateResult(
                succeeded: false,
                message: "brew update failed: \(summarize(update))"
            )
        }

        let upgrade = await runProcess(executable: brew, arguments: ["upgrade", "jamf-cli"])
        guard upgrade.exitCode == 0 else {
            return UpdateResult(
                succeeded: false,
                message: "brew upgrade jamf-cli failed: \(summarize(upgrade))"
            )
        }

        let version = installedVersion(at: URL(fileURLWithPath: installation.path)) ?? "unknown"
        return UpdateResult(succeeded: true, message: "Homebrew jamf-cli is updated to \(version).")
    }

    private static func checkGitHubUpdate(for installation: Installation) async -> UpdateResult {
        do {
            let release = try await fetchLatestGitHubRelease()
            guard let local = installation.version else {
                return UpdateResult(
                    succeeded: true,
                    message: "Latest GitHub release is \(release.tagName); local version is unknown."
                )
            }
            if compareVersions(local, release.tagName) == .orderedAscending {
                return UpdateResult(
                    succeeded: true,
                    message: "GitHub release \(release.tagName) is available for \(installation.path)."
                )
            }
            return UpdateResult(succeeded: true, message: "GitHub jamf-cli is current at \(local).")
        } catch {
            return UpdateResult(
                succeeded: false,
                message: "Could not check GitHub releases: \(error.localizedDescription)"
            )
        }
    }

    private static func updateGitHubRelease(_ installation: Installation) async -> UpdateResult {
        do {
            let release = try await fetchLatestGitHubRelease()
            if let local = installation.version,
               compareVersions(local, release.tagName) != .orderedAscending {
                return UpdateResult(succeeded: true, message: "GitHub jamf-cli is current at \(local).")
            }

            guard let asset = preferredAsset(from: release.assets) else {
                return UpdateResult(
                    succeeded: false,
                    message: "No macOS asset found for \(release.tagName). Open \(githubReleasesURL.absoluteString)."
                )
            }

            let tempDir = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let downloaded = try await download(asset: asset, to: tempDir)
            let unpackedBinary = try await resolveJamfCLIBinary(from: downloaded, assetName: asset.name, in: tempDir)
            try replaceDirectBinary(at: URL(fileURLWithPath: installation.path), with: unpackedBinary)

            let version = installedVersion(at: URL(fileURLWithPath: installation.path)) ?? release.tagName
            return UpdateResult(succeeded: true, message: "GitHub jamf-cli is updated to \(version).")
        } catch {
            return UpdateResult(
                succeeded: false,
                message: "GitHub jamf-cli update failed: \(error.localizedDescription)"
            )
        }
    }

    private static func brewExecutable(for installation: Installation) -> URL? {
        if let brewPath = installation.brewPath,
           FileManager.default.isExecutableFile(atPath: brewPath) {
            return URL(fileURLWithPath: brewPath)
        }
        return locateBrew()
    }

    private static func fetchLatestGitHubRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: githubLatestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("JamfReports", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response)
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private static func download(asset: GitHubAsset, to directory: URL) async throws -> URL {
        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("JamfReports", forHTTPHeaderField: "User-Agent")
        let (downloaded, response) = try await URLSession.shared.download(for: request)
        try validateHTTP(response)

        let destination = directory.appendingPathComponent(asset.name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: downloaded, to: destination)
        return destination
    }

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "JamfCLIInstaller",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
            )
        }
    }

    private static func preferredAsset(from assets: [GitHubAsset]) -> GitHubAsset? {
        let machine = hardwareMachine().lowercased()
        let archTerms = machine == "arm64" ? ["arm64", "aarch64"] : ["x86_64", "amd64", "x64"]
        let osTerms = ["darwin", "macos", "mac"]
        let excluded = ["checksum", "checksums", ".sha256", ".sig", ".sbom", ".json"]

        func score(_ asset: GitHubAsset) -> Int? {
            let name = asset.name.lowercased()
            guard !excluded.contains(where: { name.contains($0) }) else { return nil }
            guard osTerms.contains(where: { name.contains($0) }) else { return nil }

            var value = 0
            if archTerms.contains(where: { name.contains($0) }) {
                value += 100
            } else if name.contains("universal") || name.contains("all") {
                value += 70
            } else {
                return nil
            }

            if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
                value += 20
            } else if name.hasSuffix(".zip") {
                value += 10
            } else if name == "jamf-cli" || !name.contains(".") {
                value += 5
            }
            return value
        }

        return assets
            .compactMap { asset in score(asset).map { (asset, $0) } }
            .sorted { $0.1 > $1.1 }
            .first?
            .0
    }

    private static func resolveJamfCLIBinary(
        from downloaded: URL,
        assetName: String,
        in directory: URL
    ) async throws -> URL {
        let lower = assetName.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") {
            let extract = await runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xzf", downloaded.path, "-C", directory.path]
            )
            guard extract.exitCode == 0 else {
                throw NSError(
                    domain: "JamfCLIInstaller",
                    code: Int(extract.exitCode),
                    userInfo: [NSLocalizedDescriptionKey: "tar failed: \(summarize(extract))"]
                )
            }
            return try findExtractedJamfCLI(in: directory)
        }

        if lower.hasSuffix(".zip") {
            let extract = await runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/unzip"),
                arguments: ["-q", downloaded.path, "-d", directory.path]
            )
            guard extract.exitCode == 0 else {
                throw NSError(
                    domain: "JamfCLIInstaller",
                    code: Int(extract.exitCode),
                    userInfo: [NSLocalizedDescriptionKey: "unzip failed: \(summarize(extract))"]
                )
            }
            return try findExtractedJamfCLI(in: directory)
        }

        if downloaded.lastPathComponent == "jamf-cli" {
            return downloaded
        }
        return try findExtractedJamfCLI(in: directory)
    }

    private static func findExtractedJamfCLI(in directory: URL) throws -> URL {
        let fm = FileManager.default
        if let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.lastPathComponent == "jamf-cli" {
                return url
            }
        }
        throw NSError(
            domain: "JamfCLIInstaller",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "download did not contain a jamf-cli binary"]
        )
    }

    private static func replaceDirectBinary(at target: URL, with source: URL) throws {
        let fm = FileManager.default
        let directory = target.deletingLastPathComponent()
        let staged = directory.appendingPathComponent(".jamf-cli.\(UUID().uuidString).tmp")
        if fm.fileExists(atPath: staged.path) {
            try fm.removeItem(at: staged)
        }
        try fm.copyItem(at: source, to: staged)

        let existingMode = (try? fm.attributesOfItem(atPath: target.path)[.posixPermissions]) as? NSNumber
        let mode = existingMode ?? NSNumber(value: Int16(0o755))
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: staged.path)

        _ = try fm.replaceItemAt(target, withItemAt: staged)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directory = root.appendingPathComponent("jamf-cli-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func hardwareMachine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionParts(lhs)
        let right = versionParts(rhs)
        let count = max(left.count, right.count)
        for idx in 0..<count {
            let l = idx < left.count ? left[idx] : 0
            let r = idx < right.count ? right[idx] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func versionParts(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split { !$0.isNumber }
            .compactMap { Int($0) }
    }

    private static func runProcessSync(executable: URL, arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private nonisolated static func runProcess(executable: URL, arguments: [String]) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let stdoutDrainer = ProcessPipeDrainer(pipe: stdout)
            let stderrDrainer = ProcessPipeDrainer(pipe: stderr)
            stdoutDrainer.start()
            stderrDrainer.start()

            process.terminationHandler = { proc in
                let out = stdoutDrainer.finish()
                let err = stderrDrainer.finish()
                continuation.resume(
                    returning: CommandResult(
                        exitCode: proc.terminationStatus,
                        stdout: String(data: out, encoding: .utf8) ?? "",
                        stderr: String(data: err, encoding: .utf8) ?? ""
                    )
                )
            }

            do {
                try process.run()
            } catch {
                stdoutDrainer.cancel()
                stderrDrainer.cancel()
                continuation.resume(
                    returning: CommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
                )
            }
        }
    }

    private static func summarize(_ result: CommandResult) -> String {
        let text = result.combinedOutput
        if text.isEmpty { return "exit \(result.exitCode)" }
        return text.split(separator: "\n").prefix(3).joined(separator: " ")
    }

    private static func parseVersion(from text: String) -> String? {
        let pattern = #"\d+(?:\.\d+)+(?:[-+][A-Za-z0-9.]+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let versionRange = Range(match.range, in: text)
        else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return String(text[versionRange])
    }
}
