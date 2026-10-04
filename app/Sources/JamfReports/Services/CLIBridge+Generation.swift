import Foundation

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
    /// The workspace folder is recorded for `owner`, spelled like `profile` apart
    /// from letter case: on a case-insensitive volume the two share it.
    case profileCaseConflict(profile: String, owner: String)
    /// `config.yaml` exists but could not be parsed. `detail` carries the
    /// decoder's YAML key path + problem (never a filesystem path) so the
    /// user can locate the misconfiguration without log spelunking (#181).
    case configLoadFailed(path: String, detail: String?)
    /// jamf-cli executable was not found on the system.
    case executableNotFound
    /// An argument value is invalid (e.g. leading-dash injection risk).
    case invalidArgument(String)
    /// A required directory could not be created or a file move failed.
    /// `path` is for private logging only — never interpolated into user-visible strings.
    case directoryOperationFailed(path: String)
    /// Another live process — the bundled `--tick` agent — holds the tick lock, so the
    /// collect did not start. Nothing is queued.
    case tickLockHeld
    /// A collect is already running in this app, for any profile, so this one did not start.
    /// Nothing is queued.
    case collectInProgress
    /// jamf-cli is being installed or updated by this app, so the collect did not start: the
    /// binary changes under it otherwise. Nothing is queued.
    case toolUpdateInProgress

    /// True for the ways a collect is turned away before it starts. A refusal is not a
    /// failure: it is shown as information and leaves no Run History record.
    var isCollectRefusal: Bool {
        self == .tickLockHeld || self == .collectInProgress || self == .toolUpdateInProgress
    }

    /// `isCollectRefusal` for an error of unknown type.
    static func isCollectRefusal(_ error: Error) -> Bool {
        (error as? CLIBridgeError)?.isCollectRefusal == true
    }

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
            let why = ProfileName.problem(with: slug)?.explanation ?? ""
            return "Profile name '\(slug)' isn't supported. \(why)"
        case .workspaceMissing(let profile):
            return "Workspace not found for profile '\(profile)'."
        case .profileCaseConflict(let profile, let owner):
            return "The workspace folder for '\(profile)' belongs to profile '\(owner)', which "
                + "differs from it only by letter case. If both name the same Jamf server, set "
                + "jamf_cli.profile to \(profile) in that folder's config.yaml; otherwise add "
                + "this profile again in jamf-cli under a name that differs by more than case."
        case .configLoadFailed(_, let detail):
            // Path omitted: may contain the home directory. The detail is a
            // YAML key path from the decoder, safe to display.
            if let detail {
                return "config.yaml could not be parsed — \(detail). Fix it on the Config "
                    + "page, or restore the default config from there."
            }
            return "config.yaml could not be parsed — the file may be corrupt. The Config "
                + "page can restore the default config."
        case .executableNotFound:
            return "jamf-cli not found — install via Homebrew: brew install jamf-cli"
        case .invalidArgument(let detail):
            return "Invalid argument: \(detail)"
        case .directoryOperationFailed:
            // Path omitted: may contain the home directory or workspace layout.
            return "A required directory could not be created or moved — check available disk space and folder permissions."
        case .tickLockHeld:
            return "A scheduled run is in progress — try again when it finishes"
        case .collectInProgress:
            return "A refresh is already running — try again when it finishes"
        case .toolUpdateInProgress:
            return "jamf-cli is being updated — try again when it finishes"
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
    /// Generate every requested output type from the cached snapshots. Iterates
    /// through ALL requested types, capturing per-type results — does NOT abort
    /// on first failure. A caller that wants fresh data collects first (the
    /// Generate sheet does, through `runCollectThenGenerate`).
    ///
    /// - Parameter schoolMode: When `true`, XLSX generation calls the school-generate
    ///   CLI command instead of the standard generate command. Other output types
    ///   (HTML, PDF) still use their standard paths — school HTML/PDF are not yet wired.
    /// - Parameter aiNarrative: F3 GUI-only AI executive narrative, threaded to the
    ///   XLSX and HTML generators (school/PDF/CSV paths ignore it). Default nil.
    /// - Note: With `html.with_workbook` on, the XLSX step writes the HTML report too, unless
    ///   `types` has `.html`: that run's HTML comes from the HTML step, once.
    func generateAll(
        types: Set<GenerateOutputType>,
        outputDir: URL?,
        profile: String,
        schoolMode: Bool = false,
        template: any ReportTemplate = FullInstanceTemplate(),
        aiNarrative: String? = nil,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> GenerateAllResult {
        await Self.runGenerateAll(
            types: types,
            onLine: onLine,
            generateXLSX: {
                if schoolMode {
                    return try await self.schoolGenerate(profile: profile, csvPath: nil, onLine: onLine)
                }
                // A chosen HTML format is the run's one HTML report; `html.with_workbook`
                // would write a second.
                return try await self.generate(
                    profile: profile, csvPath: nil, template: template,
                    outputDir: outputDir, aiNarrative: aiNarrative,
                    htmlWithWorkbook: !types.contains(.html), onLine: onLine
                )
            },
            generateHTML: {
                let outURL = self.reportFileURL(
                    profile: profile, outputDir: outputDir, type: .html, onLine: onLine)
                return try await self.generateHTML(
                    profile: profile, outFile: outURL.path, template: template,
                    aiNarrative: aiNarrative, onLine: onLine
                )
            },
            generatePDF: {
                let outURL = self.reportFileURL(
                    profile: profile, outputDir: outputDir, type: .pdf, onLine: onLine)
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
    /// (the XLSX/HTML/PDF/CSV generators, the permission sweep) injected as
    /// closures. `generateAll` wires the real `CLIBridge` methods; tests inject
    /// stubs returning synthetic exit codes to exercise the partial-success
    /// branches without a live jamf-cli.
    ///
    /// Contract: every type in `types` ends up in exactly one of
    /// `result.succeeded` or `result.failed`. A generator throw records that
    /// type as failed and execution continues to the next format.
    ///
    /// `CLIBridge` is `final` and its generator methods are intentionally not
    /// behind the `CLICommand`/`CLIExecutor` protocol (ADR-W21 Hybrid scope), so
    /// this closure seam is the minimal injection point — it changes no method
    /// signatures and no call sites (Epic #102, item #3).
    static func runGenerateAll(
        types: Set<GenerateOutputType>,
        onLine: @Sendable @escaping (LogLine) -> Void,
        generateXLSX: () async throws -> Int32,
        generateHTML: () async throws -> Int32,
        generatePDF: () async throws -> Int32,
        generateCSV: () async throws -> Int32,
        tighten: () -> Void
    ) async -> GenerateAllResult {
        var result = GenerateAllResult()

        // XLSX is the canonical workbook output.
        if types.contains(.xlsx) {
            do {
                let code = try await generateXLSX()
                if code == 0 {
                    result.succeeded.append(.xlsx)
                } else {
                    result.failed.append((.xlsx, code))
                }
            } catch {
                onLine(CLIBridge.LogLine(timestamp: Date(), level: .fail,
                    text: "[fatal] generate failed: \(error.localizedDescription)"))
                result.failed.append((.xlsx, -1)) // -1: no process exit code (pre-spawn failure)
                // Continue to next format — do not return.
            }
        }

        // HTML executive summary.
        if types.contains(.html) {
            do {
                let code = try await generateHTML()
                if code == 0 {
                    result.succeeded.append(.html)
                } else {
                    result.failed.append((.html, code))
                }
            } catch {
                onLine(CLIBridge.LogLine(timestamp: Date(), level: .fail,
                    text: "[fatal] html generate failed: \(error.localizedDescription)"))
                result.failed.append((.html, -1)) // -1: no process exit code (pre-spawn failure)
            }
        }

        // PDF paginated report.
        if types.contains(.pdf) {
            do {
                let code = try await generatePDF()
                if code == 0 {
                    result.succeeded.append(.pdf)
                } else {
                    result.failed.append((.pdf, code))
                }
            } catch {
                onLine(CLIBridge.LogLine(timestamp: Date(), level: .fail,
                    text: "[fatal] pdf generate failed: \(error.localizedDescription)"))
                result.failed.append((.pdf, -1)) // -1: no process exit code (pre-spawn failure)
            }
        }

        // CSV inventory export.
        if types.contains(.csv) {
            do {
                let code = try await generateCSV()
                if code == 0 {
                    result.succeeded.append(.csv)
                } else {
                    result.failed.append((.csv, code))
                }
            } catch {
                onLine(CLIBridge.LogLine(timestamp: Date(), level: .fail,
                    text: "[fatal] csv export failed: \(error.localizedDescription)"))
                result.failed.append((.csv, -1)) // -1: no process exit code (pre-spawn failure)
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

    /// `<ExportNaming.stem>_<time>.<ext>` in the folder the Generate sheet chose, else in the
    /// folder the workbook goes to (`WorkspacePaths.reportsDir`), so one Generate puts every
    /// file in one place.
    @MainActor
    private func reportFileURL(
        profile: String, outputDir: URL?, type: GenerateOutputType,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) -> URL {
        let dir = outputDir
            ?? WorkspacePaths.reportsDir(for: profile, onLine: onLine)
            ?? FileManager.default.temporaryDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            let path = dir.path
            let desc = error.localizedDescription
            AppLogger.cli.warning("""
                reportFileURL: could not create \(path, privacy: .private): \
                \(desc, privacy: .private)
                """)
        }
        let stem = ExportNaming.stem(for: type, profile: profile, schoolMode: false)
        let ext = type.rawValue.lowercased()
        return dir.appendingPathComponent("\(stem)_\(htmlTimestamp()).\(ext)")
    }

    private nonisolated func htmlTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: Date())
    }

}
