import Foundation

// Note: `GenerateOutputType` is defined in `Views/GenerateSheet.swift` because
// it's primarily a UI-state concern. CLIBridge consumes it here.

/// Errors thrown by `CLIBridge` methods.
enum CLIBridgeError: Error, LocalizedError {
    /// The requested operation is not yet wired to a live jamf-cli command.
    /// The associated string names the function and describes what needs to be implemented.
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented(let detail): return "Not implemented: \(detail)"
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
        template: any ReportTemplate = ExecutiveTemplate(),
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> GenerateAllResult {
        var result = GenerateAllResult()

        // Collect fresh snapshots first if requested.
        // Exit 3 = HTTP 401 — hard fail; do not brute-force with bad credentials.
        // Exit 5 = HTTP 403 — permission gap; user must fix API role before retrying.
        // Exit 6 = HTTP 429 — rate-limited; transient, safe to use cached data.
        // All other non-zero codes: warn and continue with cached data.
        if collectFresh {
            let code = await collect(profile: profile, onLine: onLine)
            if code == CLIBridge.exitCodeUnauthorized {
                result.failed.append((.xlsx, code))
                return result
            }
            if code == CLIBridge.exitCodePermissionDenied {
                onLine(CLIBridge.LogLine(timestamp: Date(), level: .warn,
                    text: "[warn] collect permission denied (exit 5) — account may lack API read privileges; using cached data"))
            } else if code == CLIBridge.exitCodeRateLimited {
                onLine(CLIBridge.LogLine(timestamp: Date(), level: .warn,
                    text: "[warn] collect rate-limited (exit 6) — server throttling; using cached data"))
            } else if code != 0 {
                onLine(CLIBridge.LogLine(timestamp: Date(), level: .warn,
                    text: "[warn] collect exited \(code); proceeding with cached data"))
            }
        }

        // XLSX is the canonical workbook output.
        if types.contains(.xlsx) {
            let code: Int32
            if schoolMode {
                code = await schoolGenerate(profile: profile, csvPath: nil, onLine: onLine)
            } else {
                code = await generate(profile: profile, csvPath: nil, template: template, outputDir: outputDir, onLine: onLine)
            }
            if code == 0 {
                result.succeeded.append(.xlsx)
            } else {
                result.failed.append((.xlsx, code))
            }
        }

        // HTML executive summary.
        if types.contains(.html) {
            let outURL = htmlOutputURL(profile: profile, outputDir: outputDir)
            let code = await generateHTML(
                profile: profile,
                outFile: outURL.path,
                template: template,
                onLine: onLine
            )
            if code == 0 {
                result.succeeded.append(.html)
            } else {
                result.failed.append((.html, code))
            }
        }

        // PDF — paginated audit artifact.
        if types.contains(.pdf) {
            let code = await runPDFGeneration(profile: profile, outputDir: outputDir, onLine: onLine)
            if code == 0 {
                result.succeeded.append(.pdf)
            } else {
                result.failed.append((.pdf, code))
            }
        }

        // Tighten permissions on files written above (C-01/C-03/C-04). All paths
        // (ReportEngine XLSX, native HTML, PDF) are now Swift; each respects the
        // process umask, so the sweep normalises any 0644 files to 0600.
        if result.anySucceeded {
            WorkspacePermissionHardener.tighten(profile: profile)
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

    private nonisolated func htmlTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: Date())
    }

    @MainActor
    private func runPDFGeneration(
        profile: String,
        outputDir: URL?,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> Int32 {
        // Stub bridge to PDFExporter / ReportEngine.generatePDF.
        // Returns 2 (not-implemented) so the UI does not register a false success.
        _ = profile
        _ = outputDir
        onLine(CLIBridge.LogLine(
            timestamp: Date(),
            level: .warn,
            text: "[warn] PDF generation is not yet available — XLSX and HTML outputs are fully supported"
        ))
        return 2
    }
}
