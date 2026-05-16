import Darwin
import Foundation
import CryptoKit

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
        var updateAvailable: Bool = false
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

    /// Hosts allowed to serve a `jamf-cli` release asset. Even though the URL
    /// comes from a GitHub API response over TLS, we re-validate the host
    /// because a tampered API response or an MITM-altered redirect could
    /// otherwise point the download at an attacker-controlled origin.
    static let trustedAssetHosts: Set<String> = [
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    /// B-07: Apple Developer Team ID Jamf signs `jamf-cli` with. The SHA-256
    /// checksum we already verify only proves integrity against the same
    /// release's `*.checksums.txt` — a tag/branch swap or a compromised
    /// maintainer key would replace both. Codesign verification proves
    /// authenticity (Apple-issued Developer ID required).
    ///
    /// To look up Jamf's actual team ID, run on a known-good binary:
    ///     codesign -dv --verbose=4 /opt/homebrew/bin/jamf-cli 2>&1 | grep TeamIdentifier
    /// then update `expectedJamfTeamID` below. If Jamf rotates its signing
    /// identity, this constant needs to be bumped at the same time.
    ///
    /// Confirmed via `codesign -dv --verbose=4 /usr/local/bin/jamf-cli` against
    /// jamf-cli 1.16.1 — `Authority=Developer ID Application: JAMF Software
    /// (483DWKW443)`. If Jamf rotates its signing identity, this constant must
    /// be bumped at the same time as the rotation lands in a release.
    static let expectedJamfTeamID: String = "483DWKW443"
    static let enforceCodesignVerification: Bool = true

    /// Minimum supported jamf-cli version. Bumping this is a documentation +
    /// soft-warning change — the app does NOT hard-fail on older binaries
    /// because most code paths still work; we surface a Settings notice so
    /// users on older releases know to update.
    ///
    /// Floor history:
    /// - 2026-04: 1.14.0 — when CoreDashboard's W21 work removed pre-v1.4
    ///   patch-status fallbacks (`installed/total` shape).
    /// - 2026-05-08: 1.16.1 — to pick up the `pro device <id>` platform-
    ///   section nil-guard (PR #185) which fixes partial DeviceDetail decodes
    ///   when scope/deploymentState/target are nil.
    static let minimumSupportedVersion: String = "1.16.1"

    /// Returns true when `installedVersion` is below `minimumSupportedVersion`.
    /// Returns false if the installed version is unknown/unparseable so we
    /// don't nag users when version detection itself failed.
    static func isBelowMinimumSupported(_ installedVersion: String?) -> Bool {
        guard let installedVersion,
              !versionParts(installedVersion).isEmpty else { return false }
        return compareVersions(installedVersion, minimumSupportedVersion) == .orderedAscending
    }

    /// Errors raised by `validateAsset(host:name:)` when a release asset
    /// fails the host allow-list, control-char/path-traversal scrub, or
    /// archive-suffix pattern. See P9-A-08 in the security audit.
    enum AssetValidationError: Error, LocalizedError, CustomStringConvertible {
        case untrustedHost(String?)
        case invalidName(String)

        var errorDescription: String? { description }

        // String interpolation hits this; tests assert the string contains
        // "untrusted host" or "invalid asset name" so the description must
        // include that exact wording.
        var description: String {
            switch self {
            case .untrustedHost(let h): "Untrusted host: \(h ?? "<nil>")"
            case .invalidName(let n):    "Invalid asset name: \(n)"
            }
        }
    }

    /// Validates a release asset before download. Throws `AssetValidationError`
    /// when the host is not on the trusted list OR the filename contains
    /// path separators / `..` / NUL / control chars OR doesn't match the
    /// strict `jamf-cli*.{tar.gz,tgz,zip}` pattern. Tests cover all three
    /// rejection paths.
    static func validateAsset(host: String?, name: String) throws {
        guard let host, trustedAssetHosts.contains(host.lowercased()) else {
            throw AssetValidationError.untrustedHost(host)
        }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw AssetValidationError.invalidName(name)
        }
        if name.contains("/") || name.contains("\\") || name.contains("..") {
            throw AssetValidationError.invalidName(name)
        }
        let pattern = #"^jamf-cli[0-9A-Za-z._-]*\.(tar\.gz|tgz|zip)$"#
        if name.range(of: pattern, options: .regularExpression) == nil {
            throw AssetValidationError.invalidName(name)
        }
    }

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
        // M-01: refuse to spawn a tampered jamf-cli even for `--version`.
        // Returning nil drops the discovered version to "unknown", which
        // the upgrade path (`updateGitHubRelease`) already treats as a
        // signal to perform a fresh install via `installFromGitHub` —
        // so a rejected binary is replaced rather than re-executed.
        if CLIBridge.codesignGate(executable: binary, onLine: { _ in }) != nil {
            return nil
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--version"]
        // SF-10/B-13: minimal env for jamf-cli invocations.
        process.environment = CLIBridge.environmentForJamfCLI()

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

    /// Default install location for the direct-download path. `~/.local/bin/`
    /// is on most users' PATH (XDG-style) and avoids sudo. See
    /// `ADR-W23-jamf-cli-direct-installer.md` for the location rationale.
    static var defaultDirectInstallURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("jamf-cli")
    }

    /// Returns true when the parent directory of `defaultDirectInstallURL` is
    /// on the current process's PATH. Used after install to surface a
    /// remediation toast if the user's shell rc would not pick up the binary.
    static func defaultDirectInstallDirIsOnPATH() -> Bool {
        let dir = defaultDirectInstallURL.deletingLastPathComponent().path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").contains { String($0) == dir }
    }

    /// First-time install via direct GitHub download. Verifies the asset
    /// checksum against the release's `*.checksums.txt` and refuses on
    /// mismatch or when the checksums asset is missing. Writes to
    /// `~/.local/bin/jamf-cli`. See ADR-W23-jamf-cli-direct-installer.md.
    func firstTimeInstall() async -> UpdateResult {
        await Self.installFromGitHub(target: Self.defaultDirectInstallURL)
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
        return UpdateResult(succeeded: true, message: "Homebrew update available for jamf-cli.", updateAvailable: true)
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
                    message: "GitHub release \(release.tagName) is available for \(installation.path).",
                    updateAvailable: true
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
        if let local = installation.version {
            do {
                let release = try await fetchLatestGitHubRelease()
                if compareVersions(local, release.tagName) != .orderedAscending {
                    return UpdateResult(
                        succeeded: true, message: "GitHub jamf-cli is current at \(local)."
                    )
                }
                // Version is outdated; reuse the already-fetched release to avoid
                // a redundant network round-trip inside _performInstall.
                return await _performInstall(
                    target: URL(fileURLWithPath: installation.path),
                    release: release
                )
            } catch {
                return UpdateResult(
                    succeeded: false,
                    message: "Could not check GitHub releases: \(error.localizedDescription)"
                )
            }
        }
        return await installFromGitHub(target: URL(fileURLWithPath: installation.path))
    }

    /// Shared entry point for first-time installs. Fetches the latest GitHub
    /// release, then delegates to `_performInstall`. On first-time install the
    /// parent directory is created with mode 0755.
    static func installFromGitHub(target: URL) async -> UpdateResult {
        do {
            let release = try await fetchLatestGitHubRelease()
            return await _performInstall(target: target, release: release)
        } catch {
            return UpdateResult(
                succeeded: false,
                message: "GitHub jamf-cli install failed: \(error.localizedDescription)"
            )
        }
    }

    /// Downloads, verifies, and installs the release binary at `target`.
    /// Called by `installFromGitHub` (first-time) and `updateGitHubRelease`
    /// (upgrade, with the release already fetched from the version-check step).
    private static func _performInstall(target: URL, release: GitHubRelease) async -> UpdateResult {
        do {
            guard let asset = preferredAsset(from: release.assets) else {
                return UpdateResult(
                    succeeded: false,
                    message: "No macOS asset found for \(release.tagName). Open \(githubReleasesURL.absoluteString)."
                )
            }

            try validateAsset(host: asset.browserDownloadURL.host, name: asset.name)

            let tempDir = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let downloaded = try await download(asset: asset, to: tempDir)
            try await verifyAssetChecksum(
                asset: asset,
                downloaded: downloaded,
                release: release,
                tempDir: tempDir
            )
            let unpackedBinary = try await resolveJamfCLIBinary(
                from: downloaded, assetName: asset.name, in: tempDir
            )
            // B-07: codesign authenticity check before staging the binary.
            // SHA-256 verification above proves integrity against the release's
            // own checksums file; codesign proves Apple-issued Developer ID
            // signed with `expectedJamfTeamID`. Gated until the team ID is
            // confirmed against a known-good Jamf binary.
            if Self.enforceCodesignVerification && !Self.expectedJamfTeamID.isEmpty {
                guard CodeSignVerifier.verify(
                    url: unpackedBinary,
                    expectedTeamID: Self.expectedJamfTeamID
                ) else {
                    throw NSError(
                        domain: "JamfCLIInstaller",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey:
                            "jamf-cli codesign verification failed: signature missing,"
                            + " invalid, or not issued by team \(Self.expectedJamfTeamID)."]
                    )
                }
            } else {
                // SF-7: surface the skip in install-audit logs so reviewers can
                // confirm which gate was off (the feature flag, or the team ID).
                AppLogger.engine.info(
                    "JamfCLIInstaller: codesign verification skipped (enforce=\(Self.enforceCodesignVerification, privacy: .public), teamID=\(Self.expectedJamfTeamID.isEmpty ? "empty" : "set", privacy: .public))"
                )
            }
            try ensureParentDirectoryExists(for: target)
            try replaceDirectBinary(at: target, with: unpackedBinary)

            let version = installedVersion(at: target) ?? release.tagName
            return UpdateResult(
                succeeded: true,
                message: "jamf-cli \(version) installed at \(target.path)."
            )
        } catch {
            return UpdateResult(
                succeeded: false,
                message: "GitHub jamf-cli install failed: \(error.localizedDescription)"
            )
        }
    }

    /// Verify the SHA256 of `downloaded` against the matching line in the
    /// release's `*.checksums.txt` asset. Refuses (throws) when the checksums
    /// asset is missing, the matching line is absent, or the digests differ.
    private static func verifyAssetChecksum(
        asset: GitHubAsset,
        downloaded: URL,
        release: GitHubRelease,
        tempDir: URL
    ) async throws {
        guard let checksumsAsset = preferredChecksumsAsset(from: release.assets) else {
            throw NSError(
                domain: "JamfCLIInstaller",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Release \(release.tagName) does not publish a checksums file;"
                    + " refusing to install unverified asset."]
            )
        }

        // The checksums asset name does not match the binary-asset regex
        // (it's `*.txt`, not `*.{tar.gz,tgz,zip}`), so we re-use the trusted
        // host allow-list directly rather than `validateAsset(...)`.
        let checksumsHost = checksumsAsset.browserDownloadURL.host?.lowercased()
        guard let checksumsHost, trustedAssetHosts.contains(checksumsHost) else {
            throw NSError(
                domain: "JamfCLIInstaller",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey:
                    "Checksums asset host is not in the trusted allow-list;"
                    + " refusing to download from \(checksumsAsset.browserDownloadURL.host ?? "<nil>")."]
            )
        }

        let checksumsFile = try await download(asset: checksumsAsset, to: tempDir)
        let text = (try? String(contentsOf: checksumsFile, encoding: .utf8)) ?? ""
        guard let expected = extractChecksum(forAsset: asset.name, in: text) else {
            throw NSError(
                domain: "JamfCLIInstaller",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "No SHA256 entry for \(asset.name) in \(checksumsAsset.name);"
                    + " refusing to install."]
            )
        }

        let actual = try sha256Hex(of: downloaded)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw NSError(
                domain: "JamfCLIInstaller",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "Asset checksum mismatch for \(asset.name) — possible"
                    + " tampering or corrupted download (expected \(expected),"
                    + " got \(actual))."]
            )
        }
    }

    /// Pick the checksums file from a release's assets. Matches case-insensitive
    /// names containing both "checksum" and ending with `.txt` — covers the
    /// common upstream naming conventions (`checksums.txt`,
    /// `jamf-cli_v1.14.0_checksums.txt`).
    private static func preferredChecksumsAsset(from assets: [GitHubAsset]) -> GitHubAsset? {
        assets.first { asset in
            let lower = asset.name.lowercased()
            return lower.contains("checksum") && lower.hasSuffix(".txt")
        }
    }

    /// Parse a checksums file body (one `<hex> <space(s)> <filename>` line per
    /// asset) and return the digest for `assetName`, or nil if absent.
    static func extractChecksum(forAsset assetName: String, in body: String) -> String? {
        for line in body.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { continue }
            // Last whitespace-separated token is the filename; strip the
            // optional "*" leading marker for binary-mode shasum output.
            var filename = String(parts.last!)
            if filename.hasPrefix("*") { filename.removeFirst() }
            if filename == assetName {
                return String(parts.first!)
            }
        }
        return nil
    }

    /// SHA256 hex digest of a file. Loads the full file into RAM; acceptable
    /// because release assets are <50 MB and this runs once per install.
    static func sha256Hex(of file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func ensureParentDirectoryExists(for target: URL) throws {
        let parent = target.deletingLastPathComponent()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                throw NSError(
                    domain: "JamfCLIInstaller",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey:
                        "\(parent.path) exists but is not a directory."]
                )
            }
            return
        }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o755))]
        )
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
        try await preflightArchive(at: downloaded.path, assetName: assetName)
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

    /// Lists the entries of an archive without extracting them, and rejects any
    /// entry whose path resolves outside the extract directory. Catches "zip
    /// slip" / "tar slip" attacks (entries like `../../../etc/passwd` or
    /// absolute paths) that SHA-256 verification alone cannot detect because a
    /// malicious-but-checksum-matching archive would still pass integrity.
    /// Plain-binary downloads (no archive suffix) are passed through.
    static func preflightArchive(at path: String, assetName: String) async throws {
        let lower = assetName.lowercased()
        let executable: URL
        let arguments: [String]
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") {
            executable = URL(fileURLWithPath: "/usr/bin/tar")
            arguments = ["-tzf", path]
        } else if lower.hasSuffix(".zip") {
            executable = URL(fileURLWithPath: "/usr/bin/unzip")
            arguments = ["-Z", "-1", path]
        } else {
            return
        }

        let listing = await runProcess(executable: executable, arguments: arguments)
        guard listing.exitCode == 0 else {
            throw NSError(
                domain: "JamfCLIInstaller",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey:
                    "Archive listing failed for \(assetName): \(summarize(listing))"]
            )
        }

        for raw in listing.stdout.split(whereSeparator: \.isNewline) {
            let entry = String(raw).trimmingCharacters(in: .whitespaces)
            if entry.isEmpty { continue }
            try Self.rejectUnsafeArchiveEntry(entry)
        }
    }

    /// Pure helper: rejects an archive entry name that would escape the
    /// extract directory. Split out so it can be unit-tested without
    /// constructing real archives.
    static func rejectUnsafeArchiveEntry(_ entry: String) throws {
        if entry.hasPrefix("/") {
            throw NSError(
                domain: "JamfCLIInstaller",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey:
                    "Archive entry rejected (absolute path): \(entry)"]
            )
        }
        // Catches `..`, `../foo`, `foo/../bar`, and tar verbose `name -> ../target` symlinks.
        if entry.contains("..") {
            throw NSError(
                domain: "JamfCLIInstaller",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey:
                    "Archive entry rejected (traversal): \(entry)"]
            )
        }
        if entry.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw NSError(
                domain: "JamfCLIInstaller",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey:
                    "Archive entry rejected (control character in name)"]
            )
        }
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

    /// SF-10: `environment` is opt-in because callers run a mix of brew, tar,
    /// unzip, and jamf-cli — each needs a different env scope. Pass
    /// `CLIBridge.environmentForJamfCLI()` for jamf-cli invocations, leave
    /// nil to inherit the parent (current behavior for brew/tar/unzip, where
    /// the parent's PATH is required to find Homebrew prefixes).
    private static func runProcessSync(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

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

    /// See `runProcessSync` — same `environment` semantics.
    private nonisolated static func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            if let environment { process.environment = environment }

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
