import Foundation

// Note: `GenerateOutputType` is defined in `Views/GenerateSheet.swift` because
// it's primarily a UI-state concern. CLIBridge consumes it here.

/// Errors thrown by `CLIBridge` methods for app-internal pre-spawn failures.
///
/// These cases replace the `-1` sentinel that previously collapsed six distinct
/// failure causes into an undifferentiated exit code. Real jamf-cli exit codes
/// (1–6, with named constants on `CLIBridge`) are unaffected.
///
/// `errorDescription` is intentionally path-safe: no home directory, workspace
/// path, or hostname is interpolated into the user-visible string. The full
/// context is logged via `AppLogger` at the throw site.
enum CLIBridgeError: Error, LocalizedError, Equatable, Sendable {
    /// The requested operation is not yet wired to a live jamf-cli command.
    case notImplemented(String)
    /// jamf-cli's code signature failed verification — the binary may be tampered.
    case codesignRejected
    /// The process launch itself threw (e.g. `Process.run()` failed, bad executable path).
    case launchFailed(reason: String)
    /// The profile slug is invalid (fails `ProfileService.isValid`).
    case invalidProfile(String)
    /// The workspace directory does not exist for the given profile.
    case workspaceMissing(profile: String)
    /// `config.yaml` exists but could not be parsed.
    case configLoadFailed(path: String)
    /// `.csvAssisted` mode requires a CSV in `csv-inbox/` but none was found.
    case csvMissing(profile: String)
    /// jamf-cli executable was not found on the system.
    case executableNotFound
    /// An argument value is invalid (e.g. leading-dash injection risk).
    case invalidArgument(String)
    /// A required directory could not be created or a file move failed.
    /// `path` is for private logging only — never interpolated into user-visible strings.
    case directoryOperationFailed(path: String)

    var errorDescription: String? {
        switch self {
        case .notImplemented(let detail):
            return "Not implemented: \(detail)"
        case .codesignRejected:
            return "jamf-cli signature verification failed — reinstall jamf-cli via Homebrew."
        case .launchFailed:
            // Reason omitted: may contain a system path or sandbox detail.
            return "Could not launch jamf-cli — check that jamf-cli is installed and the executable is intact."
        case .invalidProfile(let slug):
            return "Invalid profile name '\(slug)'."
        case .workspaceMissing(let profile):
            return "Workspace not found for profile '\(profile)'."
        case .configLoadFailed:
            // Path omitted: may contain the home directory.
            return "config.yaml could not be parsed — the file may be corrupt."
        case .csvMissing(let profile):
            return "csv-assisted mode requires a CSV in csv-inbox/ for profile '\(profile)' — none found."
        case .executableNotFound:
            return "jamf-cli not found — install via Homebrew: brew install jamf-cli"
        case .invalidArgument(let detail):
            return "Invalid argument: \(detail)"
        case .directoryOperationFailed:
            // Path omitted: may contain the home directory or workspace layout.
            return "A required directory could not be created or moved — check available disk space and folder permissions."
        }
    }
}

/// Per-type result of a `generateAll` run.
/// Tracks successful and failed output types independently so the UI
/// can report partial success (e.g. "XLSX written, HTML failed").
struct GenerateAllResult: Sendable {
    var succeeded: [GenerateOutputType] = []
    var failed: [(type: GenerateOutputType, exitCode: Int32)] = []

    var allSucceeded: Bool { failed.isEmpty }
    var anySucceeded: Bool { !succeeded.isEmpty }
}

@MainActor
extension CLIBridge {
    /// Run the full generate cycle for a given set of output types.
    /// Iterates through ALL requested types, capturing per-type results —
    /// does NOT abort on first failure.
    ///
    /// - Parameter schoolMode: When `true`, XLSX generation calls the school-generate
    ///   CLI command instead of the standard generate command. Other output types
    ///   (HTML, PDF) still use their standard paths — school HTML/PDF are not yet wired.
    func generateAll(
        types: Set<GenerateOutputType>,
        collectFresh: Bool,
        outputDir: URL?,
        profile: String,
        schoolMode: Bool = false,
        template: any ReportTemplate = FullInstanceTemplate(),
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> GenerateAllResult {
        await Self.runGenerateAll(
            types: types,
            collectFresh: collectFresh,
            profile: profile,
            onLine: onLine,
            collect: { try await self.collect(profile: profile, onLine: onLine) },
            generateXLSX: {
                if schoolMode {
                    return try await self.schoolGenerate(profile: profile, csvPath: nil, onLine: onLine)
                }
                return try await self.generate(
                    profile: profile, csvPath: nil, template: template,
                    outputDir: outputDir, onLine: onLine
                )
            },
            generateHTML: {
                let outURL = self.htmlOutputURL(profile: profile, outputDir: outputDir)
                return try await self.generateHTML(
                    profile: profile, outFile: outURL.path, template: template, onLine: onLine
                )
            },
            generatePDF: {
                let outURL = self.pdfOutputURL(profile: profile, outputDir: outputDir)
                return try await self.generatePDF(
                    profile: profile, outFile: outURL.path, template: template, onLine: onLine
                )
            },
            generateCSV: {
                return try await self.exportInventoryCSV(
                    profile: profile, outFile: nil, onLine: onLine
                )
            },
            tighten: { WorkspacePermissionHardener.tighten(profile: profile) }
        )
    }

    /// Orchestration core of `generateAll`, with the side-effecting operations
    /// (`collect`, the XLSX/HTML generators, the permission sweep) injected as
    /// closures. `generateAll` wires the real `CLIBridge` methods; tests inject
    /// stubs returning synthetic exit codes to exercise the collect-fallback
    /// (exit 3/5/6) and partial-success branches without a live jamf-cli.
    ///
    /// `CLIBridge` is `final` and its generator methods are intentionally not
    /// behind the `CLICommand`/`CLIExecutor` protocol (ADR-W21 Hybrid scope), so
    /// this closure seam is the minimal injection point — it changes no method
    /// signatures and no call sites (Epic #102, item #3).
    static func runGenerateAll(
        types: Set<GenerateOutputType>,
        collectFresh: Bool,
        profile: String,
        onLine: @Sendable @escaping (LogLine) -> Void,
        collect: () async throws -> Int32,
        generateXLSX: () async throws -> Int32,
        generateHTML: () async throws -> Int32,
        generatePDF: () async throws -> Int32,
        generateCSV: () async throws -> Int32,
        tighten: () -> Void,
        cacheAge: (() async -> String)? = nil
    ) async -> GenerateAllResult {
        // Cache-age lookup is injectable so tests can exercise both the
        // warn-and-proceed (cache exists) and fatal (no cache) branches
        // without touching the real filesystem. Empty string = no cache.
        let resolveCacheAge: () async -> String =
            cacheAge ?? { await Self.describeCacheAge(for: profile) }
        var result = GenerateAllResult()

        // Collect fresh snapshots first if requested.
        // Exit 3 = HTTP 401 — hard fail; do not brute-force with bad credentials.
        // Exit 5 = HTTP 403 — permission gap; user must fix API role before retrying.
        // Exit 6 = HTTP 429 — rate-limited; transient, safe to use cached data.
        // All other non-zero codes: warn and continue with cached data.
        if collectFresh {
            let code: Int32
            do {
                code = try await collect()
            } catch {
                onLine(CLIBridge.LogLine(timestamp: Date(), level: .fail,
                    text: "[fatal] collect failed: \(error.localizedDescription)"))
                result.failed.append((.xlsx, -1)) // -1: no process exit code (pre-spawn failure)
                return result
            }
            if code == CLIBridge.exitCodeUnauthorized {
                result.failed.append((.xlsx, code))
                return result
            }
            if code == CLIBridge.exitCodePermissionDenied {
                let cacheAge = await resolveCacheAge()
                if cacheAge.isEmpty {
                    onLine(CLIBridge.LogLine(timestamp: Date(), level: .fail,
                        text: "[fatal] collect permission denied (exit 5) and no cached data available"))
                    result.failed.append((.xlsx, code))
                    return result
                } else {
                    onLine(CLIBridge.LogLine(timestamp: Date(), level: .warn,
                        text: "[warn] collect permission denied (exit 5) — generating from cached data that is \(cacheAge)"))
                }
            } else if code == CLIBridge.exitCodeRateLimited {
                let cacheAge = await resolveCacheAge()
                if cacheAge.isEmpty {
                    onLine(CLIBridge.LogLine(timestamp: Date(), level: .fail,
                        text: "[fatal] collect rate-limited (exit 6) and no cached data available"))
                    result.failed.append((.xlsx, code))
                    return result
                } else {
                    onLine(CLIBridge.LogLine(timestamp: Date(), level: .warn,
                        text: "[warn] collect rate-limited (exit 6) — generating from cached data that is \(cacheAge)"))
                }
            } else if code != 0 {
                let cacheAge = await resolveCacheAge()
                if cacheAge.isEmpty {
                    onLine(CLIBridge.LogLine(timestamp: Date(), level: .fail,
                        text: "[fatal] collect failed (exit \(code)) and no cached data available"))
                    result.failed.append((.xlsx, code))
                    return result
                } else {
                    onLine(CLIBridge.LogLine(timestamp: Date(), level: .warn,
                        text: "[warn] collect exited \(code); proceeding with cached data that is \(cacheAge)"))
                }
            }
        }

        // XLSX is the canonical workbook output.
        if types.contains(.xlsx) {
            let code: Int32
            do {
                code = try await generateXLSX()
            } catch {
                onLine(CLIBridge.LogLine(timestamp: Date(), level: .fail,
                    text: "[fatal] generate failed: \(error.localizedDescription)"))
                result.failed.append((.xlsx, -1)) // -1: no process exit code (pre-spawn failure)
                return result
            }
            if code == 0 {
                result.succeeded.append(.xlsx)
            } else {
                result.failed.append((.xlsx, code))
            }
        }

        // HTML executive summary.
        if types.contains(.html) {
            let code: Int32
            do {
                code = try await generateHTML()
            } catch {
                onLine(CLIBridge.LogLine(timestamp: Date(), level: .fail,
                    text: "[fatal] html generate failed: \(error.localizedDescription)"))
                result.failed.append((.html, -1)) // -1: no process exit code (pre-spawn failure)
                return result
            }
            if code == 0 {
                result.succeeded.append(.html)
            } else {
                result.failed.append((.html, code))
            }
        }

        // PDF paginated report.
        if types.contains(.pdf) {
            let code: Int32
            do {
                code = try await generatePDF()
            } catch {
                onLine(CLIBridge.LogLine(timestamp: Date(), level: .fail,
                    text: "[fatal] pdf generate failed: \(error.localizedDescription)"))
                result.failed.append((.pdf, -1)) // -1: no process exit code (pre-spawn failure)
                return result
            }
            if code == 0 {
                result.succeeded.append(.pdf)
            } else {
                result.failed.append((.pdf, code))
            }
        }

        // CSV inventory export.
        if types.contains(.csv) {
            let code: Int32
            do {
                code = try await generateCSV()
            } catch {
                onLine(CLIBridge.LogLine(timestamp: Date(), level: .fail,
                    text: "[fatal] csv export failed: \(error.localizedDescription)"))
                result.failed.append((.csv, -1)) // -1: no process exit code (pre-spawn failure)
                return result
            }
            if code == 0 {
                result.succeeded.append(.csv)
            } else {
                result.failed.append((.csv, code))
            }
        }

        // Tighten permissions on files written above (C-01/C-03/C-04). All paths
        // (ReportEngine XLSX, native HTML, PDF) are now Swift; each respects the
        // process umask, so the sweep normalises any 0644 files to 0600.
        if result.anySucceeded {
            tighten()
        }

        return result
    }

    /// List the Extension Attributes configured on the active jamf-cli tenant.
    ///
    /// Not yet wired — throws `CLIBridgeError.notImplemented` so callers can surface
    /// a meaningful error instead of silently showing an empty list.
    /// Wire to `jamf-cli -p <profile> pro computer-extension-attributes list --output json`
    /// when that command is available.
    nonisolated func listExtensionAttributes(profile: String) async throws -> [ExtensionAttribute] {
        throw CLIBridgeError.notImplemented(
            "listExtensionAttributes: wire jamf-cli pro computer-extension-attributes list --output json"
        )
    }

    // MARK: - Private helpers

    @MainActor
    private func htmlOutputURL(profile: String, outputDir: URL?) -> URL {
        let dir: URL
        if let outputDir {
            dir = outputDir
        } else if let workspace = ProfileService.workspaceURL(for: profile) {
            dir = workspace.appendingPathComponent("Generated Reports", isDirectory: true)
        } else {
            dir = FileManager.default.temporaryDirectory
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            AppLogger.cli.warning("htmlOutputURL: could not create output directory \(dir.path): \(error)")
        }
        let stem = "jamf_report_\(profile)_\(htmlTimestamp())"
        return dir.appendingPathComponent("\(stem).html")
    }

    @MainActor
    private func pdfOutputURL(profile: String, outputDir: URL?) -> URL {
        let dir: URL
        if let outputDir {
            dir = outputDir
        } else if let workspace = ProfileService.workspaceURL(for: profile) {
            dir = workspace.appendingPathComponent("Generated Reports", isDirectory: true)
        } else {
            dir = FileManager.default.temporaryDirectory
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            AppLogger.cli.warning("pdfOutputURL: could not create output directory \(dir.path): \(error)")
        }
        let stem = "jamf_report_\(profile)_\(htmlTimestamp())"
        return dir.appendingPathComponent("\(stem).pdf")
    }

    private nonisolated func htmlTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: Date())
    }

    /// Describes the age of the newest cached snapshot for the given profile.
    /// Returns an empty string if no cached data exists at all.
    private static func describeCacheAge(for profile: String) async -> String {
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else {
            return ""
        }

        guard let enumerator = FileManager.default.enumerator(
            at: dataDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ""
        }

        var newestDate: Date?
        while let item = enumerator.nextObject() {
            guard let fileURL = item as? URL else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate else {
                continue
            }

            if let current = newestDate {
                if mtime > current {
                    newestDate = mtime
                }
            } else {
                newestDate = mtime
            }
        }

        guard let newestDate else {
            return ""  // Empty string signals no cached data
        }

        let ageSeconds = Date().timeIntervalSince(newestDate)
        let ageDays = ageSeconds / (24 * 3600)

        if ageDays >= 1 {
            return String(format: "%.1f days old", ageDays)
        } else {
            let ageHours = ageSeconds / 3600
            return String(format: "%.1f hours old", ageHours)
        }
    }

}
