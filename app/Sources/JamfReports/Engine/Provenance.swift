import Foundation

// MARK: - Provenance

/// Captures the who/when/where of a report generation run.
///
/// Stored in `summary.json` and rendered in the Cover sheet and HTML report footer.
/// All fields are optional except `runID`, `generatedAt`, and `operatorUserHost` so
/// that missing jamf-cli data or overview snapshots degrade gracefully.
struct Provenance: Codable, Sendable {
    /// UUID generated fresh at run start — uniquely identifies this report.
    let runID: String
    /// Timestamp when the report was generated.
    let generatedAt: Date
    /// Workspace profile slug (e.g. `"prod"` or `"acme-prod"`).
    let profile: String
    /// Version string captured from `jamf-cli --version` (first non-empty line).
    /// `nil` when jamf-cli is absent or `--version` fails.
    let jamfCLIVersion: String?
    /// Tenant URL extracted from the cached `overview` JSON snapshot.
    /// `nil` when no overview snapshot is available.
    let jamfTenantURL: String?
    /// `"username@hostname"` of the operator who ran the report.
    let operatorUserHost: String

    enum CodingKeys: String, CodingKey {
        case runID, generatedAt, profile, jamfCLIVersion, jamfTenantURL, operatorUserHost
    }
}

// MARK: - Factory

extension Provenance {

    /// Build a `Provenance` for the current run.
    ///
    /// - Parameters:
    ///   - profile: Active workspace profile slug.
    ///   - jamfCLIURL: Path to the jamf-cli binary, or `nil` to skip version capture.
    ///   - dataDir: Workspace data directory; used to read the cached `overview` snapshot.
    /// - Returns: A fully populated `Provenance`.
    static func current(
        profile: String,
        jamfCLIURL: URL?,
        dataDir: URL
    ) async -> Provenance {
        let runID = UUID().uuidString
        let generatedAt = Date()
        let operatorUserHost = buildOperatorString()
        let jamfCLIVersion = await captureJamfCLIVersion(jamfCLIURL: jamfCLIURL)
        let jamfTenantURL = readTenantURL(dataDir: dataDir)

        return Provenance(
            runID: runID,
            generatedAt: generatedAt,
            profile: profile,
            jamfCLIVersion: jamfCLIVersion,
            jamfTenantURL: jamfTenantURL,
            operatorUserHost: operatorUserHost
        )
    }

    // MARK: - Private helpers

    private static func buildOperatorString() -> String {
        let user = NSUserName()
        // Host.current().localizedName is main-actor-isolated in newer SDK; use ProcessInfo.
        let host = ProcessInfo.processInfo.hostName
            .components(separatedBy: ".").first ?? ProcessInfo.processInfo.hostName
        return "\(user)@\(host)"
    }

    /// Runs `jamf-cli --version` and returns the first non-empty line of output.
    /// Returns `nil` on any failure (missing binary, non-zero exit, no output,
    /// or codesign-gate rejection).
    ///
    /// M-01: routes through `CLIBridge.codesignGate` before spawning so a
    /// tampered `jamf-cli` cannot execute even for an apparently-innocuous
    /// `--version` probe. The gate logs to `AppLogger.cli` on rejection;
    /// there is no streaming `LogLine` consumer at this layer (Provenance is
    /// async metadata capture, not a Runs-feed run), so the `onLine` closure
    /// is a no-op.
    static func captureJamfCLIVersion(jamfCLIURL: URL?) async -> String? {
        guard let url = jamfCLIURL else { return nil }
        if CLIBridge.codesignGate(executable: url, onLine: CLIBridge.noOpOnLine) != nil {
            return nil
        }
        return await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = url
            proc.arguments = ["--version"]
            // SF-10/B-13: minimal env for jamf-cli — see `CLIBridge`.
            proc.environment = CLIBridge.environmentForJamfCLI()
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()   // discard stderr

            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let version = output
                    .components(separatedBy: .newlines)
                    .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                continuation.resume(returning: version)
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Reads the tenant URL from the cached `overview` JSON snapshot in `dataDir`.
    /// Looks for `"jamf_url"` or `"url"` keys in any overview row.
    private static func readTenantURL(dataDir: URL) -> String? {
        let fm = FileManager.default
        let candidates: [URL] = {
            var result: [URL] = []
            let subdir = dataDir.appendingPathComponent("overview", isDirectory: true)
            if fm.fileExists(atPath: subdir.path),
               let files = try? fm.contentsOfDirectory(
                at: subdir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
               ) {
                result.append(contentsOf: files.filter {
                    $0.pathExtension == "json"
                    && $0.lastPathComponent.lowercased() != SnapshotManifest.fileName
                })
            }
            return result
        }()

        guard let newest = candidates.max(by: { lhs, rhs in
            let lMod = (try? lhs.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rMod = (try? rhs.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lMod < rMod
        }),
              let data = try? Data(contentsOf: newest),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        for row in rows {
            if let url = row["jamf_url"] as? String, !url.isEmpty { return url }
            if let url = row["url"] as? String, !url.isEmpty, url.hasPrefix("http") { return url }
        }
        return nil
    }
}

// MARK: - Date encoding

extension Provenance {

    /// Creates a new ISO 8601 date formatter. Called once per encode/decode rather than
    /// stored as a static to avoid `ISO8601DateFormatter`'s non-Sendable mutable state.
    private static func makeDateFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runID, forKey: .runID)
        try container.encode(Provenance.makeDateFormatter().string(from: generatedAt),
                             forKey: .generatedAt)
        try container.encode(profile, forKey: .profile)
        try container.encodeIfPresent(jamfCLIVersion, forKey: .jamfCLIVersion)
        try container.encodeIfPresent(jamfTenantURL, forKey: .jamfTenantURL)
        try container.encode(operatorUserHost, forKey: .operatorUserHost)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runID = try container.decode(String.self, forKey: .runID)
        let dateStr = try container.decode(String.self, forKey: .generatedAt)
        generatedAt = Provenance.makeDateFormatter().date(from: dateStr) ?? Date.distantPast
        profile = try container.decode(String.self, forKey: .profile)
        jamfCLIVersion = try container.decodeIfPresent(String.self, forKey: .jamfCLIVersion)
        jamfTenantURL = try container.decodeIfPresent(String.self, forKey: .jamfTenantURL)
        operatorUserHost = try container.decode(String.self, forKey: .operatorUserHost)
    }
}
