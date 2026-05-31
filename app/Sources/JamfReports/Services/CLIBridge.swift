import Foundation

/// Resolve CLI binaries from GUI launches, where `Process` does not inherit a
/// login-shell PATH. `jamf-cli` may be installed by Homebrew or directly from a
/// GitHub/pkg release into `/usr/local/bin`.
enum ExecutableLocator {
    private static let candidatePaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    static func locate(_ binary: String) -> URL? {
        for dir in candidatePaths {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(binary)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        // CWD fallback removed: first-launch onboarding pipes the Jamf Pro API
        // secret to jamf-cli stdin; launching from a directory containing a
        // planted `jamf-cli` would otherwise hand the secret to that binary.
        return nil
    }
}

/// Wraps invocations of `jamf-cli` for live API flows and native Swift engine calls.
/// All GUI flows (generate, collect, backup, audit, deviceDetail, schoolGenerate, etc.)
/// delegate to `ReportEngine` or native service implementations — no Python required.
///
/// The bridge is intentionally async-boundary-safe: it never blocks the main thread,
/// streams stdout/stderr into a callback so the Runs screen can render lines as they
/// arrive, and reports the final exit code so callers can color the `EXIT n` pill.
@MainActor
@Observable
final class CLIBridge {

    enum LogLevel: String, Sendable {
        case info, ok, warn, fail

        /// Centralized log line classification. Matches `[ok]`, `[warn]`, `[fatal]`,
        /// `[error]`, `[fail]`, and `traceback` patterns from ReportEngine and jamf-cli.
        static func from(line: String) -> LogLevel {
            let l = line.lowercased()
            if l.contains("[ok]") { return .ok }
            if l.contains("[warn]") { return .warn }
            if l.contains("[fatal]") || l.contains("[error]") || l.contains("[fail]") || l.contains("traceback") {
                return .fail
            }
            return .info
        }
    }
    struct LogLine: Sendable, Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: LogLevel
        let text: String
    }

    /// A no-op `onLine` handler for call sites that do not need log streaming.
    /// Use this constant instead of an inline `{ _ in }` closure so the intent
    /// is explicit and the constant type is guaranteed to match the parameter.
    /// `nonisolated` so it can be referenced from nonisolated static functions
    /// (e.g. `codesignGate` call sites in `LaunchAgentWriter`, `ProfileService`).
    nonisolated static let noOpOnLine: @Sendable (LogLine) -> Void = { _ in }

    struct CachedJSONSnapshot: Sendable {
        let data: Data
        let modified: Date
    }

    func locate(_ binary: String) -> URL? {
        ExecutableLocator.locate(binary)
    }

    var isJamfCLIAvailable: Bool { locate("jamf-cli") != nil }

    nonisolated func cachedJSONSnapshots(
        profile: String,
        type: String,
        limit: Int = 2
    ) async -> [CachedJSONSnapshot] {
        await Task.detached(priority: .utility) {
            guard ProfileService.isValid(profile),
                  let dataDir = try? WorkspacePaths.dataDir(for: profile) else {
                AppLogger.cli.warning(
                    "cachedJSONSnapshots: could not enumerate \(type, privacy: .public) for \(profile, privacy: .public)"
                )
                return []
            }
            let dir = dataDir.appendingPathComponent(type, isDirectory: true)
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
            } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
                return []  // Expected on first run before any snapshots exist
            } catch {
                AppLogger.cli.warning(
                    "cachedJSONSnapshots: could not enumerate \(type, privacy: .public) for \(profile, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return []
            }

            return entries
                .filter { $0.pathExtension == "json" }
                .compactMap { url -> (url: URL, modified: Date)? in
                    let modified = (try? url.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ))?.contentModificationDate ?? Date.distantPast
                    return (url, modified)
                }
                .sorted { $0.modified > $1.modified }
                .prefix(max(limit, 0))
                .compactMap { item -> CachedJSONSnapshot? in
                    guard let data = try? Data(contentsOf: item.url) else { return nil }
                    // S-01: reject truncated / malformed snapshots so a
                    // partially-written file from a crash mid-write does
                    // not render green in AuditView, HealthCheckView, or
                    // CustomizationWizard. Structural JSON probe is the
                    // cheapest check that catches every case the
                    // downstream decoder would. Default JSONSerialization
                    // rejects bare fragments (strings, numbers, null) at
                    // the top level — every jamf-cli output is an array
                    // or object, so a fragment is by definition truncated.
                    guard (try? JSONSerialization.jsonObject(with: data, options: [])) != nil else {
                        AppLogger.cli.warning(
                            "cachedJSONSnapshots: rejecting corrupted JSON \(item.url.lastPathComponent, privacy: .public)"
                        )
                        return nil
                    }
                    return CachedJSONSnapshot(data: data, modified: item.modified)
                }
        }.value
    }

    /// Run an arbitrary command, streaming each line through `onLine`. Returns the
    /// process exit code. Marked `nonisolated` so it can be awaited off the main actor.
    ///
    /// - Parameter environment: Process environment. Defaults to
    ///   `environmentForJamfCLI()` (S-02) so callers that omit the
    ///   argument do not inherit the parent's `DYLD_INSERT_LIBRARIES`,
    ///   `SSL_CERT_FILE`, or other dyld-relevant variables.
    nonisolated func run(
        executable: URL,
        arguments: [String],
        cwd: URL? = nil,
        environment: [String: String] = CLIBridge.environmentForJamfCLI(),
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        // M-01: re-verify jamf-cli signature before each spawn so a
        // post-onboarding binary swap on a user-writable path
        // (/opt/homebrew/bin) cannot receive credentials.
        if let gateError = Self.codesignGate(executable: executable, onLine: onLine) {
            throw gateError
        }

        // Gate the continuation resume on BOTH stdout EOF and stderr EOF in addition
        // to process termination. Resuming in terminationHandler alone races the final
        // readabilityHandler deliveries — they run on different GCD queues, so under
        // load the last stdout/stderr chunk can drop from the live Runs feed (same race
        // fixed in runAndCapture via CaptureCompletion).
        final class RunCompletion: @unchecked Sendable {
            private let lock = NSLock()
            private var stdoutAtEOF = false
            private var stderrAtEOF = false
            private var exitCode: Int32?
            private var resumed = false
            private let continuation: CheckedContinuation<Int32, Error>

            init(_ continuation: CheckedContinuation<Int32, Error>) {
                self.continuation = continuation
            }

            func markStdoutEOF() { finish { $0.stdoutAtEOF = true } }
            func markStderrEOF() { finish { $0.stderrAtEOF = true } }
            func markTerminated(_ code: Int32) { finish { $0.exitCode = code } }

            /// Process never spawned — resume with a thrown error immediately,
            /// bypassing the EOF wait (no child means pipes never deliver EOF).
            func failWithLaunchError(_ error: CLIBridgeError) {
                let shouldResume: Bool
                lock.lock()
                shouldResume = !resumed
                if shouldResume { resumed = true }
                lock.unlock()
                if shouldResume { continuation.resume(throwing: error) }
            }

            private func finish(_ mutate: (RunCompletion) -> Void) {
                var pending: Int32?
                lock.lock()
                mutate(self)
                if !resumed, stdoutAtEOF, stderrAtEOF, let exitCode {
                    resumed = true
                    pending = exitCode
                }
                lock.unlock()
                if let pending { continuation.resume(returning: pending) }
            }
        }

        // Lock-protected box so the task-cancellation handler's terminate() call
        // never races against the continuation body's set() call. onCancel fires
        // concurrently on whatever thread cancels the Task — there is no
        // happens-before between the operation and onCancel closures.
        // Terminating a not-yet-launched process is a documented no-op, so the
        // already-cancelled-at-entry case is safe: onCancel fires first (reads
        // nil), body spawns, process runs to completion normally. A belt-and-
        // suspenders isCancelled check after run() catches that edge and terminates.
        final class ProcessBox: @unchecked Sendable {
            private let lock = NSLock()
            private var process: Process?
            func set(_ p: Process) { lock.lock(); process = p; lock.unlock() }
            func terminate() { lock.lock(); let p = process; lock.unlock(); p?.terminate() }
        }
        let box = ProcessBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let completion = RunCompletion(continuation)
                let process = Process()
                box.set(process)
                process.executableURL = executable
                process.arguments = arguments
                if let cwd { process.currentDirectoryURL = cwd }
                process.environment = environment

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        completion.markStdoutEOF()
                        return
                    }
                    guard let s = String(data: data, encoding: .utf8) else { return }
                    for line in s.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
                        onLine(.init(timestamp: Date(), level: LogLevel.from(line: String(line)), text: String(line)))
                    }
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        completion.markStderrEOF()
                        return
                    }
                    guard let s = String(data: data, encoding: .utf8) else { return }
                    for line in s.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
                        onLine(.init(timestamp: Date(), level: .warn, text: String(line)))
                    }
                }

                process.terminationHandler = { proc in
                    completion.markTerminated(proc.terminationStatus)
                }

                do {
                    try process.run()
                    // Belt-and-suspenders: if cancellation arrived before run()
                    // (onCancel fired first, read nil, returned without terminating),
                    // terminate the now-running process ourselves.
                    if Task.isCancelled { process.terminate() }
                } catch {
                    // C-11: mirror to OSLog so post-mortem forensics see launch
                    // failures even when the in-app stream is gone.
                    AppLogger.cli.error(
                        "CLIBridge.run: process launch failed: \(error.localizedDescription, privacy: .private)"
                    )
                    onLine(.init(timestamp: Date(), level: .fail, text: "[fatal] \(error.localizedDescription)"))
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    completion.failWithLaunchError(.launchFailed(reason: error.localizedDescription))
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
    /// Run an arbitrary command, streaming each line through `onLine` and returning
    /// the collected stdout + the process exit code.
    ///
    /// - Parameter environment: see ``run(executable:arguments:cwd:environment:onLine:)``.
    nonisolated func runAndCapture(
        executable: URL,
        arguments: [String],
        cwd: URL? = nil,
        environment: [String: String] = CLIBridge.environmentForJamfCLI(),
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> (Int32, Data) {
        final class DataBox: @unchecked Sendable {
            var data = Data()
            let lock = NSLock()
            func append(_ newData: Data) {
                lock.lock()
                data.append(newData)
                lock.unlock()
            }
        }
        let box = DataBox()

        // M-01: same gate as `run` — verify before spawn.
        if let gateError = Self.codesignGate(executable: executable, onLine: onLine) {
            throw gateError
        }

        // Resumes the async continuation only once BOTH the stdout pipe has
        // reached EOF (an empty `availableData` delivery) and the process has
        // terminated. Resuming on `terminationHandler` alone races the final
        // `readabilityHandler` delivery — they run on different GCD queues — so
        // under CI load the continuation can resume before the last stdout chunk
        // is appended, truncating the captured payload to empty (Epic #102).
        final class CaptureCompletion: @unchecked Sendable {
            private let lock = NSLock()
            private var stdoutAtEOF = false
            private var exitCode: Int32?
            private var resumed = false
            private let continuation: CheckedContinuation<Int32, Error>

            init(_ continuation: CheckedContinuation<Int32, Error>) {
                self.continuation = continuation
            }

            func markStdoutEOF() { finish { $0.stdoutAtEOF = true } }

            func markTerminated(_ code: Int32) { finish { $0.exitCode = code } }

            /// Process never spawned — resume with a thrown error immediately,
            /// bypassing the EOF wait (no child means the stdout pipe will never
            /// deliver EOF).
            func failWithLaunchError(_ error: CLIBridgeError) {
                let shouldResume: Bool
                lock.lock()
                shouldResume = !resumed
                if shouldResume { resumed = true }
                lock.unlock()
                if shouldResume { continuation.resume(throwing: error) }
            }

            private func finish(_ mutate: (CaptureCompletion) -> Void) {
                var pending: Int32?
                lock.lock()
                mutate(self)
                if !resumed, stdoutAtEOF, let exitCode {
                    resumed = true
                    pending = exitCode
                }
                lock.unlock()
                if let pending { continuation.resume(returning: pending) }
            }
        }

        // Locked process box for task-cancellation — same pattern as run().
        final class ProcessBox: @unchecked Sendable {
            private let lock = NSLock()
            private var process: Process?
            func set(_ p: Process) { lock.lock(); process = p; lock.unlock() }
            func terminate() { lock.lock(); let p = process; lock.unlock(); p?.terminate() }
        }
        let processBox = ProcessBox()

        let code = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let completion = CaptureCompletion(continuation)
                let process = Process()
                processBox.set(process)
                process.executableURL = executable
                process.arguments = arguments
                if let cwd { process.currentDirectoryURL = cwd }
                process.environment = environment

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        // Empty delivery == EOF: the child closed its stdout write end,
                        // and every preceding non-empty chunk has already been appended
                        // (a DispatchSource delivers in order). Capture is now complete.
                        handle.readabilityHandler = nil
                        completion.markStdoutEOF()
                        return
                    }
                    // stdout is the structured payload (typically JSON) consumed by the
                    // report engine — do NOT stream it to onLine, only capture it. Progress
                    // messages from jamf-cli arrive on stderr and are streamed below.
                    box.append(data)
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
                    for line in s.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
                        onLine(.init(timestamp: Date(), level: .warn, text: String(line)))
                    }
                }

                process.terminationHandler = { proc in
                    stderr.fileHandleForReading.readabilityHandler = nil
                    completion.markTerminated(proc.terminationStatus)
                }

                do {
                    try process.run()
                    if Task.isCancelled { process.terminate() }
                } catch {
                    // C-11: mirror to OSLog — see `run()` above.
                    AppLogger.cli.error(
                        "CLIBridge.runAndCapture: process launch failed: \(error.localizedDescription, privacy: .private)"
                    )
                    onLine(.init(timestamp: Date(), level: .fail, text: "[fatal] \(error.localizedDescription)"))
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    completion.failWithLaunchError(.launchFailed(reason: error.localizedDescription))
                }
            }
        } onCancel: {
            processBox.terminate()
        }
        return (code, box.data)
    }

    /// Fluent helper for the most common CLI flows the GUI surfaces.
    func generate(
        profile: String,
        csvPath: String?,
        template: any ReportTemplate = ExecutiveTemplate(),
        outputDir: URL? = nil,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        guard await ensureWorkspace(profile: profile, onLine: onLine) != nil else {
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            let msg = "error: workspace URL unexpectedly nil for profile '\(profile)' after ensureWorkspace — this is a programmer error"
            onLine(LogLine(timestamp: Date(), level: .fail, text: msg))
            AppLogger.cli.error("\(msg)")
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let configURL = workspace.appendingPathComponent("config.yaml")
        guard let config = loadConfig(at: configURL, onLine: onLine) else {
            throw CLIBridgeError.configLoadFailed(path: configURL.path)
        }
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] could not resolve data_dir for \(profile)"))
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let engine = ReportEngine(config: config, dataDir: dataDir)
        let csvURL = csvPath.map { URL(fileURLWithPath: $0) }
        let defaultURL = engine.resolveOutputURL(stem: "report", profile: profile)
        let outputURL = outputDir.map { $0.appendingPathComponent(defaultURL.lastPathComponent) } ?? defaultURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: outputURL.deletingLastPathComponent().path) {
            do {
                try fm.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                let dirPath = outputURL.deletingLastPathComponent().path
                AppLogger.cli.error(
                    "generate: could not create output dir: \(dirPath, privacy: .private) — \(error, privacy: .private)"
                )
                onLine(.init(timestamp: Date(), level: .fail,
                    text: "[error] could not create output directory: \(error.localizedDescription)"))
                throw CLIBridgeError.directoryOperationFailed(path: dirPath)
            }
        }
        do {
            let failures = try await engine.generate(
                csvURL: csvURL, outputURL: outputURL, template: template, onLine: onLine
            )
            if failures.isEmpty {
                onLine(.init(timestamp: Date(), level: .ok,
                             text: "[ok] report written: \(outputURL.lastPathComponent)"))
            } else {
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[partial] Report written with \(failures.count) sheet failure(s): " +
                                   outputURL.lastPathComponent))
                for f in failures {
                    onLine(.init(timestamp: Date(), level: .warn,
                                 text: "  failed sheet: \(f.sheet): \(f.error)"))
                }
            }
            tightenOnSuccess(0, profile: profile)
            return 0
        } catch {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] generate failed: \(error.localizedDescription)"))
            // Engine-layer failure: no CLIBridgeError case — return 1 (real non-zero exit).
            tightenOnSuccess(1, profile: profile)
            return 1
        }
    }

    /// Load config.yaml, distinguishing file-missing from parse-failure.
    ///
    /// File-missing is a legitimate first-run state; defaults are returned silently.
    /// File-exists-but-unparseable indicates corruption or tampering; the caller
    /// receives `nil` and must abort the operation.
    ///
    /// Detection mechanism: `FileManager.fileExists` is checked before calling
    /// `ConfigLoader.load`. The `catch` branch is reached only when the file exists
    /// but cannot be decoded — there is no ambiguity between the two cases.
    ///
    /// - Parameters:
    ///   - url: Absolute URL of `config.yaml` within the workspace.
    ///   - onLine: Progress callback; receives a `[error]` line on parse failure.
    /// - Returns: A decoded and defaulted `ReportConfig` on success or file-missing;
    ///   `nil` when the file exists but cannot be parsed.
    private func loadConfig(
        at url: URL,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) -> ReportConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ReportConfig()
        }
        do {
            return try ConfigLoader.load(from: url)
        } catch {
            let msg = "[error] config.yaml parse failed — aborting: \(error.localizedDescription)"
            AppLogger.cli.error("\(msg, privacy: .private)")
            onLine(.init(timestamp: Date(), level: .fail, text: msg))
            return nil
        }
    }

    /// Tighten workspace permissions after every CLI write (MFS-1). Extends
    /// the Wave 1 sweep from `generateAll` to the standalone
    /// collect/audit/inventory/backup/html/school-generate paths so each
    /// writer leaves files at 0600 / dirs at 0700.
    ///
    /// Runs on every exit code, not just success: the underlying writer may
    /// write some files then crash (non-zero exit), and those files would
    /// otherwise keep their default-umask 0644 perms indefinitely. The cost
    /// of a tree walk on a failed run is negligible compared to the security
    /// gain. The caller's `exitCode` parameter is retained for the log entry
    /// so forensic review can correlate the sweep with the underlying run.
    func tightenOnSuccess(_ exitCode: Int32, profile: String) {
        let result = WorkspacePermissionHardener.tighten(profile: profile)
        AppLogger.cli.info(
            """
            tightenOnSuccess profile=\(profile, privacy: .public) \
            exit=\(exitCode) touched=\(result.touched) \
            failed=\(result.failed) enumerated=\(result.enumerated)
            """
        )
    }

    /// Run school-generate for Jamf School tenants via the Swift engine.
    func schoolGenerate(
        profile: String,
        csvPath: String?,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        guard await authGuard(profile: profile, onLine: onLine) else {
            return Self.exitCodeUnauthorized
        }
        guard await ensureWorkspace(profile: profile, onLine: onLine) != nil else {
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            let msg = "error: workspace URL unexpectedly nil for profile '\(profile)' after ensureWorkspace — this is a programmer error"
            onLine(LogLine(timestamp: Date(), level: .fail, text: msg))
            AppLogger.cli.error("\(msg)")
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let configURL = workspace.appendingPathComponent("config.yaml")
        guard let config = loadConfig(at: configURL, onLine: onLine) else {
            throw CLIBridgeError.configLoadFailed(path: configURL.path)
        }
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] could not resolve data_dir for \(profile)"))
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let engine = ReportEngine(config: config, dataDir: dataDir)
        let csvURL = csvPath.map { URL(fileURLWithPath: $0) }
        let outputURL = engine.resolveOutputURL(stem: "school-report", profile: profile)
        let fm = FileManager.default
        if !fm.fileExists(atPath: outputURL.deletingLastPathComponent().path) {
            do {
                try fm.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                let dirPath = outputURL.deletingLastPathComponent().path
                AppLogger.cli.error(
                    "schoolGenerate: could not create output dir: \(dirPath, privacy: .private) — \(error, privacy: .private)"
                )
                onLine(.init(timestamp: Date(), level: .fail,
                    text: "[error] could not create output directory: \(error.localizedDescription)"))
                throw CLIBridgeError.directoryOperationFailed(path: dirPath)
            }
        }
        do {
            let failures = try await ReportEngine.schoolGenerate(
                config: config,
                csvURL: csvURL,
                dataDir: dataDir,
                outputURL: outputURL
            )
            if failures.isEmpty {
                onLine(.init(timestamp: Date(), level: .ok,
                             text: "[ok] school report written: \(outputURL.lastPathComponent)"))
            } else {
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[partial] School report written with \(failures.count) sheet failure(s): " +
                                   outputURL.lastPathComponent))
                for f in failures {
                    onLine(.init(timestamp: Date(), level: .warn,
                                 text: "  failed sheet: \(f.sheet): \(f.error)"))
                }
            }
            tightenOnSuccess(0, profile: profile)
            return 0
        } catch {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] school-generate failed: \(error.localizedDescription)"))
            // Engine-layer failure: no CLIBridgeError case — return 1 (real non-zero exit).
            tightenOnSuccess(1, profile: profile)
            return 1
        }
    }

    /// Run a jamf-cli collect for `profile`.
    ///
    /// `tiers` (PR-23 T-16) narrows which `CollectionTier`s are fetched.
    /// Defaults to all three — the GUI manual-refresh path wants everything
    /// that's due. `RefreshCoordinator` passes `[.refresh]` for its
    /// profile-switch backfill so it doesn't pull every list endpoint.
    func collect(
        profile: String,
        tiers: Set<CollectionTier> = Set(CollectionTier.allCases),
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        guard await authGuard(profile: profile, onLine: onLine) else {
            return Self.exitCodeUnauthorized
        }
        guard await ensureWorkspace(profile: profile, onLine: onLine) != nil else {
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        // Honor the Settings "Skip expensive collections" toggle. UserDefaults
        // backs the @AppStorage in SettingsView, so this is a direct read.
        // Scheduled collects run from main.swift and pass skipExpensive=false
        // unconditionally — the toggle only affects manual GUI refreshes.
        let skipExpensive = UserDefaults.standard.bool(forKey: "skipExpensiveCollections")
        do {
            try await ReportEngine.collect(
                profile: profile,
                workspacePaths: WorkspacePaths.self,
                tiers: tiers,
                skipExpensive: skipExpensive,
                onLine: onLine
            )
            tightenOnSuccess(0, profile: profile)
            return 0
        } catch ReportEngineError.jamfCLINotFound {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] jamf-cli not found — install via Homebrew: brew install jamf-cli"))
            throw CLIBridgeError.executableNotFound
        } catch {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] collect failed: \(error.localizedDescription)"))
            // Engine-layer failure: return 1 (real non-zero exit).
            tightenOnSuccess(1, profile: profile)
            return 1
        }
    }

    func collectThenGenerate(
        profile: String,
        csvPath: String?,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        // Auth is checked inside collect(); skipping a separate probe here avoids calling
        // jamf-cli pro auth token twice for the combined collect+generate flow.
        onLine(.init(timestamp: Date(), level: .info, text: "[info] collecting jamf-cli snapshots for \(profile)"))
        let collectExit = try await collect(profile: profile, onLine: onLine)
        guard collectExit == 0 else { return collectExit }

        onLine(.init(timestamp: Date(), level: .info, text: "[info] generating report from cached snapshots"))
        return try await generate(profile: profile, csvPath: csvPath, onLine: onLine)
    }

    // MARK: - jamf-cli exit codes (jamf-cli Error Handling & Exit Codes spec)
    nonisolated static let exitCodeUsage: Int32 = 2          // bad flags / missing args — indicates a caller bug
    nonisolated static let exitCodeUnauthorized: Int32 = 3   // HTTP 401 — invalid or expired credentials
    nonisolated static let exitCodeNotFound: Int32 = 4       // HTTP 404 — resource does not exist
    nonisolated static let exitCodePermissionDenied: Int32 = 5  // HTTP 403 — account lacks required API privileges
    nonisolated static let exitCodeRateLimited: Int32 = 6    // HTTP 429 — server throttling; transient, self-resolving

    /// Guards a live-API operation by probing `pro auth token` first.
    ///
    /// Resolves the profile's auth method via `jamf-cli config list` (falls back to local
    /// workspace discovery if jamf-cli is absent). Skips the probe for Jamf School profiles
    /// (`authMethod == "apikey"`) — school uses API-key auth with no bearer token to inspect.
    ///
    /// Returns `true` when it's safe to proceed. On failure, emits a `[error]` log
    /// line with a remediation hint and returns `false` — callers must return
    /// a non-zero exit code immediately without running any further API calls.
    nonisolated func authGuard(
        profile: String,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> Bool {
        let authMethod = ProfileService.discoverLocal()
            .first(where: { $0.name == profile })?
            .authMethod ?? ""
        guard !CLIBridge.shouldSkipAuthProbe(for: authMethod) else { return true }
        let status = await tokenStatus(for: profile)
        if let status, status.isValid, !status.isExpired { return true }
        if ExecutableLocator.locate("jamf-cli") == nil {
            onLine(.init(
                timestamp: Date(), level: .fail,
                text: "[error] jamf-cli not found — install via Homebrew: brew install jamf-cli"
            ))
        } else {
            onLine(.init(
                timestamp: Date(), level: .fail,
                text: "[error] auth check failed for profile '\(profile)' — " +
                      "re-authenticate with: jamf-cli -p \(profile) pro auth token"
            ))
        }
        return false
    }

    /// Returns `true` when the auth method does not require a bearer-token probe.
    ///
    /// API-key auth (Jamf School) uses key-based authentication with no bearer token
    /// to inspect, so the `pro auth token` probe must be skipped for those profiles.
    nonisolated static func shouldSkipAuthProbe(for authMethod: String) -> Bool {
        authMethod == "apikey"
    }

    nonisolated func validateConnection(
        profile: String,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        guard ProfileService.isValid(profile) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] invalid profile name: \(profile)"))
            throw CLIBridgeError.invalidProfile(profile)
        }
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jamf-cli not found"))
            throw CLIBridgeError.executableNotFound
        }
        guard await authGuard(profile: profile, onLine: onLine) else {
            return Self.exitCodeUnauthorized
        }
        return try await run(
            executable: bin,
            arguments: ["-p", profile, "config", "validate"],
            environment: Self.environmentForJamfCLI(),
            onLine: onLine
        )
    }

    /// Fetch the token status for `profile` using `jamf-cli pro auth token --output json`.
    ///
    /// Returns a `TokenStatus` with `isValid: false` (never throws) when:
    /// - jamf-cli is not installed
    /// - the profile slug is invalid
    /// - jamf-cli exits non-zero (unauthenticated, old version, unknown command)
    /// - JSON is missing or malformed
    nonisolated func tokenStatus(for profile: String) async -> TokenStatus? {
        guard ProfileService.isValid(profile),
              let bin = ExecutableLocator.locate("jamf-cli") else {
            return nil
        }
        // Subcommand: jamf-cli -p <profile> pro auth token --output json --no-input
        // Available since jamf-cli v1.9; older versions exit non-zero with "unknown command".
        let args = CLICommand.proAuthToken(profile: profile).argv
        let exitCode: Int32
        let data: Data
        do {
            (exitCode, data) = try await runAndCapture(
                executable: bin,
                arguments: args,
                environment: Self.environmentForJamfCLI()
            ) { _ in }
        } catch {
            // tokenStatus is the auth prober — codesign rejection or launch failure
            // here means we cannot confirm auth; treat as invalid/expired token.
            AppLogger.cli.warning(
                "tokenStatus: runAndCapture threw for \(profile, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
            return TokenStatus.make(profile: profile, token: nil, expiresAt: nil, raw: "")
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard exitCode == 0, !data.isEmpty else {
            return TokenStatus.make(profile: profile, token: nil, expiresAt: nil, raw: raw)
        }
        return parseTokenStatus(profile: profile, data: data, raw: raw)
    }

    nonisolated func parseTokenStatus(
        profile: String,
        data: Data,
        raw: String
    ) -> TokenStatus {
        // Defensive decode struct — every field optional so malformed JSON never throws.
        struct TokenPayload: Decodable {
            let token: String?
            let expires_at: String?   // ISO8601, e.g. "2026-05-04T13:38:38Z"; omitted for token-file auth
        }
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(TokenPayload.self, from: data) else {
            return TokenStatus.make(profile: profile, token: nil, expiresAt: nil, raw: raw)
        }
        let expiresAt: Date?
        if let rawDate = payload.expires_at {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            expiresAt = formatter.date(from: rawDate)
        } else {
            expiresAt = nil
        }
        return TokenStatus.make(
            profile: profile,
            token: payload.token,
            expiresAt: expiresAt,
            raw: raw
        )
    }

    /// Payload + provenance for a single-device detail fetch. `fromCache==true`
    /// signals the live API call failed and we returned the last-known-good cache.
    /// When `fromCache==false` a `.meta` sidecar holding `generated_at` (ISO-8601
    /// UTC) is written alongside the cache file; `freshnessTimestamp(for:)` in
    /// DeviceLookupView prefers that sidecar over the attacker-`touch`-able mtime.
    struct DeviceDetailResult: Sendable {
        let data: Data
        let fromCache: Bool
        let cacheURL: URL?
    }

    nonisolated func deviceDetailWithProvenance(
        profile: String,
        deviceID: String,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) async -> DeviceDetailResult? {
        guard await authGuard(profile: profile, onLine: { line in
            AppLogger.cli.warning("deviceDetail auth: \(line.text, privacy: .private)")
        }) else { return nil }
        return await singleDeviceDetail(
            profile: profile,
            deviceID: deviceID,
            cacheSubdir: "devices",
            jamfCLIArgs: { id in ["pro", "device", id] },
            onLine: onLine
        )
    }

    /// Mobile-device detail. Mirrors `deviceDetailWithProvenance` but invokes
    /// `jamf-cli pro mobile-devices get <id>` and caches under
    /// `jamf-cli-data/mobile-devices/`. Same fall-back-to-cache semantics.
    nonisolated func mobileDeviceDetailWithProvenance(
        profile: String,
        deviceID: String,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) async -> DeviceDetailResult? {
        guard await authGuard(profile: profile, onLine: { line in
            AppLogger.cli.warning("mobileDeviceDetail auth: \(line.text, privacy: .private)")
        }) else { return nil }
        return await singleDeviceDetail(
            profile: profile,
            deviceID: deviceID,
            cacheSubdir: "mobile-devices",
            jamfCLIArgs: { id in ["pro", "mobile-devices", "get", id] },
            onLine: onLine
        )
    }

    /// Shared backbone for single-device fetches. The two device kinds differ
    /// only in jamf-cli subcommand and cache directory — everything else
    /// (profile validation, atomic move, fall-back to last-known-good cache)
    /// is identical and must stay in lock-step. Returns a `DeviceDetailResult`
    /// so callers can render a staleness banner when the live API call fails
    /// and we silently returned the previous snapshot.
    nonisolated private func singleDeviceDetail(
        profile: String,
        deviceID: String,
        cacheSubdir: String,
        jamfCLIArgs: (String) -> [String],
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) async -> DeviceDetailResult? {
        let trimmedID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProfileService.isValid(profile),
              !trimmedID.isEmpty,
              let workspace = ProfileService.workspaceURL(for: profile) else {
            return nil
        }

        let devicesDir = workspace
            .appendingPathComponent("jamf-cli-data", isDirectory: true)
            .appendingPathComponent(cacheSubdir, isDirectory: true)
        let cache = devicesDir.appendingPathComponent(deviceCacheFilename(trimmedID))
        if let bin = ExecutableLocator.locate("jamf-cli") {
            let partial = devicesDir.appendingPathComponent(".\(cache.lastPathComponent).partial")
            let baseArgs = ["-p", profile] + jamfCLIArgs(trimmedID)
            let exit = await runDeviceDetailProcess(
                executable: bin,
                arguments: baseArgs + [
                    "--output", "json", "--no-input", "--out-file", partial.path,
                ],
                outputDirectory: devicesDir,
                onLine: onLine
            )
            if exit == 0 {
                do {
                    let data = try Data(contentsOf: partial)
                    if !data.isEmpty {
                        // Remove both the stale cache and its freshness sidecar so a
                        // forged-old-timestamp sidecar can't survive a live refresh.
                        try? FileManager.default.removeItem(at: cache)
                        try? FileManager.default.removeItem(
                            at: cache.appendingPathExtension("meta")
                        )
                        do {
                            try FileManager.default.moveItem(at: partial, to: cache)
                            if let cached = try? Data(contentsOf: cache) {
                                CLIBridge.writeDeviceDetailFreshnessSidecar(for: cache)
                                return DeviceDetailResult(
                                    data: cached, fromCache: false, cacheURL: cache
                                )
                            }
                        } catch {
                            try? data.write(to: cache, options: .atomic)
                            CLIBridge.writeDeviceDetailFreshnessSidecar(for: cache)
                            return DeviceDetailResult(
                                data: data, fromCache: false, cacheURL: cache
                            )
                        }
                    }
                } catch {
                    AppLogger.cli.warning(
                        "deviceDetail: could not read partial output: \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
            try? FileManager.default.removeItem(at: partial)
        }
        guard let data = try? Data(contentsOf: cache) else { return nil }
        return DeviceDetailResult(data: data, fromCache: true, cacheURL: cache)
    }

    /// Writes a freshness sidecar at `cache.appendingPathExtension("meta")` holding
    /// `{"generated_at": "<ISO-8601 UTC>"}`. Called on every successful live-data write
    /// so `freshnessTimestamp(for:)` in DeviceLookupView can prefer the app-written
    /// timestamp over the attacker-`touch`-able filesystem mtime (T-15).
    ///
    /// - Non-blocking: failures are logged as warnings; the caller's return is unaffected.
    /// - The caller is responsible for removing any stale `.meta` file before calling this
    ///   (done in `singleDeviceDetail` alongside `removeItem(at: cache)`).
    nonisolated static func writeDeviceDetailFreshnessSidecar(for cache: URL) {
        let sidecar = cache.appendingPathExtension("meta")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let isoString = formatter.string(from: Date())
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["generated_at": isoString]
        ) else {
            AppLogger.cli.warning(
                "freshnessSidecar: could not serialize JSON for \(cache.lastPathComponent, privacy: .private)"
            )
            return
        }
        do {
            try data.write(to: sidecar, options: .atomic)
        } catch {
            AppLogger.cli.warning(
                "freshnessSidecar: write failed for \(sidecar.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    nonisolated func diffBackups(
        profile: String,
        left: URL,
        right: URL,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        guard ProfileService.isValid(profile) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] invalid profile name: \(profile)"))
            throw CLIBridgeError.invalidProfile(profile)
        }
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jamf-cli not found"))
            throw CLIBridgeError.executableNotFound
        }
        return try await run(
            executable: bin,
            arguments: [
                "-p", profile,
                "pro", "diff",
                "--source", left.path,
                "--target", right.path,
                "--output", "plain",
                "--no-input",
            ],
            environment: Self.environmentForJamfCLI(),
            onLine: onLine
        )
    }

    func generateHTML(
        profile: String,
        outFile: String?,
        template: any ReportTemplate = ExecutiveTemplate(),
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        // HTML generation reads only cached jamf-cli JSON snapshots; no live API calls are made.
        // authGuard is intentionally omitted — stale/expired credentials do not prevent rendering.
        guard await ensureWorkspace(profile: profile, onLine: onLine) != nil else {
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            let msg = "error: workspace URL unexpectedly nil for profile '\(profile)' after ensureWorkspace — this is a programmer error"
            onLine(LogLine(timestamp: Date(), level: .fail, text: msg))
            AppLogger.cli.error("\(msg)")
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let configURL = workspace.appendingPathComponent("config.yaml")
        guard let config = loadConfig(at: configURL, onLine: onLine) else {
            throw CLIBridgeError.configLoadFailed(path: configURL.path)
        }
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] could not resolve data_dir for \(profile)"))
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let outputURL: URL
        if let path = outFile {
            outputURL = URL(fileURLWithPath: path)
        } else {
            let engine = ReportEngine(config: config, dataDir: dataDir)
            outputURL = engine.resolveOutputURL(stem: "report", profile: profile)
                .deletingPathExtension().appendingPathExtension("html")
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: outputURL.deletingLastPathComponent().path) {
            do {
                try fm.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                let dirPath = outputURL.deletingLastPathComponent().path
                AppLogger.cli.error(
                    "generateHTML: could not create output dir: \(dirPath, privacy: .private) — \(error, privacy: .private)"
                )
                onLine(.init(timestamp: Date(), level: .fail,
                    text: "[error] could not create output directory: \(error.localizedDescription)"))
                throw CLIBridgeError.directoryOperationFailed(path: dirPath)
            }
        }
        do {
            try await ReportEngine.generateHTML(
                config: config,
                dataDir: dataDir,
                outputURL: outputURL,
                template: template,
                onLine: onLine
            )
            onLine(.init(timestamp: Date(), level: .ok,
                         text: "[ok] HTML report written: \(outputURL.lastPathComponent)"))
            tightenOnSuccess(0, profile: profile)
            return 0
        } catch {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] html generation failed: \(error.localizedDescription)"))
            // Engine-layer failure: return 1 (real non-zero exit).
            tightenOnSuccess(1, profile: profile)
            return 1
        }
    }

    func generatePDF(
        profile: String,
        outFile: String,
        template: any ReportTemplate = ExecutiveTemplate(),
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        // PDF generation reads only cached jamf-cli JSON snapshots; no live API calls.
        guard await ensureWorkspace(profile: profile, onLine: onLine) != nil else {
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            let msg = "error: workspace URL unexpectedly nil for profile '\(profile)' after ensureWorkspace — this is a programmer error"
            onLine(LogLine(timestamp: Date(), level: .fail, text: msg))
            AppLogger.cli.error("\(msg)")
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let configURL = workspace.appendingPathComponent("config.yaml")
        guard let config = loadConfig(at: configURL, onLine: onLine) else {
            throw CLIBridgeError.configLoadFailed(path: configURL.path)
        }
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] could not resolve data_dir for \(profile)"))
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let outputURL = URL(fileURLWithPath: outFile)
        let fm = FileManager.default
        if !fm.fileExists(atPath: outputURL.deletingLastPathComponent().path) {
            do {
                try fm.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                let dirPath = outputURL.deletingLastPathComponent().path
                AppLogger.cli.error(
                    "generatePDF: could not create output dir: \(dirPath, privacy: .private) — \(error, privacy: .private)"
                )
                onLine(.init(timestamp: Date(), level: .fail,
                    text: "[error] could not create output directory: \(error.localizedDescription)"))
                throw CLIBridgeError.directoryOperationFailed(path: dirPath)
            }
        }
        do {
            try await ReportEngine.generatePDF(
                config: config,
                dataDir: dataDir,
                outputURL: outputURL,
                profileName: profile,
                template: template
            )
            onLine(.init(timestamp: Date(), level: .ok,
                         text: "[ok] PDF report written: \(outputURL.lastPathComponent)"))
            tightenOnSuccess(0, profile: profile)
            return 0
        } catch {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] pdf generation failed: \(error.localizedDescription)"))
            tightenOnSuccess(1, profile: profile)
            return 1
        }
    }

    func exportInventoryCSV(
        profile: String,
        outFile: String?,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        guard await authGuard(profile: profile, onLine: onLine) else {
            return Self.exitCodeUnauthorized
        }
        guard await ensureWorkspace(profile: profile, onLine: onLine) != nil else {
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            let msg = "error: workspace URL unexpectedly nil for profile '\(profile)' after ensureWorkspace — this is a programmer error"
            onLine(LogLine(timestamp: Date(), level: .fail, text: msg))
            AppLogger.cli.error("\(msg)")
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let configURL = workspace.appendingPathComponent("config.yaml")
        guard let config = loadConfig(at: configURL, onLine: onLine) else {
            throw CLIBridgeError.configLoadFailed(path: configURL.path)
        }
        let outputURL: URL
        if let path = outFile {
            outputURL = URL(fileURLWithPath: path)
        } else {
            let engine = ReportEngine(config: config, dataDir: workspace)
            outputURL = engine.resolveOutputURL(stem: "inventory", profile: profile)
                .deletingPathExtension().appendingPathExtension("csv")
        }
        do {
            try await ReportEngine.inventoryCSV(
                profile: profile,
                workspacePaths: WorkspacePaths.self,
                outputURL: outputURL
            )
            onLine(.init(timestamp: Date(), level: .ok,
                         text: "[ok] inventory CSV written: \(outputURL.lastPathComponent)"))
            tightenOnSuccess(0, profile: profile)
            return 0
        } catch {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] inventory-csv failed: \(error.localizedDescription)"))
            // Engine-layer failure: return 1 (real non-zero exit).
            tightenOnSuccess(1, profile: profile)
            return 1
        }
    }

    func audit(
        profile: String,
        category: String?,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        // B-02: defense-in-depth profile validation. Mirrors validateConnection.
        guard ProfileService.isValid(profile) else {
            AppLogger.cli.warning("audit: rejecting invalid profile name")
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] invalid profile name: \(profile)"))
            throw CLIBridgeError.invalidProfile(profile)
        }
        // B-03: refuse leading-dash category. Checked before auth so that the
        // rejection is deterministic and does not depend on auth state.
        if let category, category.hasPrefix("-") {
            AppLogger.cli.warning("audit: rejecting leading-dash category")
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] audit category may not start with '-'"))
            throw CLIBridgeError.invalidArgument("audit category may not start with '-'")
        }
        guard await authGuard(profile: profile, onLine: onLine) else {
            return Self.exitCodeUnauthorized
        }
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jamf-cli not found"))
            throw CLIBridgeError.executableNotFound
        }
        var args = ["-p", profile, "pro", "audit", "--output", "json", "--no-input"]
        if let category, !category.isEmpty {
            args.append(contentsOf: ["--checks", category])
        }

        let (code, data) = try await runAndCapture(
            executable: bin,
            arguments: args,
            environment: Self.environmentForJamfCLI(),
            onLine: onLine
        )
        if code == 0, !data.isEmpty {
            saveJSONSnapshot(data: data, profile: profile, type: "audit", onLine: onLine)
        }
        tightenOnSuccess(code, profile: profile)
        return code
    }

    func groupHygiene(
        profile: String,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        // B-02: defense-in-depth profile validation.
        guard ProfileService.isValid(profile) else {
            AppLogger.cli.warning("groupHygiene: rejecting invalid profile name")
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] invalid profile name: \(profile)"))
            throw CLIBridgeError.invalidProfile(profile)
        }
        guard await authGuard(profile: profile, onLine: onLine) else {
            return Self.exitCodeUnauthorized
        }
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jamf-cli not found"))
            throw CLIBridgeError.executableNotFound
        }
        let args = ["-p", profile, "pro", "group-tools", "analyze", "--unused", "--output", "json", "--no-input"]
        let (code, data) = try await runAndCapture(
            executable: bin,
            arguments: args,
            environment: Self.environmentForJamfCLI(),
            onLine: onLine
        )
        if code == 0, !data.isEmpty {
            saveJSONSnapshot(data: data, profile: profile, type: "group-tools-analyze", onLine: onLine)
        }
        tightenOnSuccess(code, profile: profile)
        return code
    }

    private func saveJSONSnapshot(
        data: Data,
        profile: String,
        type: String,
        onLine: (@Sendable (LogLine) -> Void)? = nil
    ) {
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else {
            // C-12: surface the silent path-resolution failure too. Otherwise
            // the user sees a green CLI exit while the workspace gets no
            // refreshed JSON.
            AppLogger.cli.warning(
                "saveJSONSnapshot: could not resolve data_dir for \(type, privacy: .public)"
            )
            onLine?(.init(
                timestamp: Date(),
                level: .warn,
                text: "[warn] snapshot write skipped (\(type)) — workspace data_dir unresolved"
            ))
            return
        }
        let dir = dataDir.appendingPathComponent(type, isDirectory: true)
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .prefix(15)
        let file = dir.appendingPathComponent("\(type)_\(ts).json")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // S-01: write atomically so a crash, OOM, or full-disk
            // mid-write leaves no truncated <type>_<ts>.json poisoning
            // the cached-fallback path. Mirrors the .atomic discipline
            // of every other JSON write in this file.
            try data.write(to: file, options: .atomic)
            // MFS-1: ensure the freshly-written snapshot is owner-only readable.
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: file.path
            )
        } catch {
            // C-07/MFS-4: route to unified logging instead of stdout.
            // %{public} for type (taxonomy), %{private} for the error chain.
            AppLogger.cli.warning(
                "saveJSONSnapshot failed for \(type, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
            // C-12: also surface to the in-app log feed so the user can see
            // their refresh just used stale data.
            onLine?(.init(
                timestamp: Date(),
                level: .warn,
                text: "[warn] snapshot write failed (\(type)) — refresh will use stale data: \(error.localizedDescription)"
            ))
        }
    }

    func backup(
        profile: String,
        label: String?,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        guard ProfileService.isValid(profile) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] invalid profile name: \(profile)"))
            throw CLIBridgeError.invalidProfile(profile)
        }
        // B-03: refuse leading-dash labels — would be re-interpreted as a flag by jamf-cli.
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedLabel, trimmedLabel.hasPrefix("-") {
            AppLogger.cli.warning("backup: rejecting leading-dash label")
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] backup label may not start with '-'"))
            throw CLIBridgeError.invalidArgument("backup label may not start with '-'")
        }
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jamf-cli not found"))
            throw CLIBridgeError.executableNotFound
        }
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] no workspace for profile '\(profile)'"))
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let backupsRoot = workspace.appendingPathComponent("backups", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            AppLogger.cli.error(
                "backup: could not create backups dir: \(backupsRoot.path, privacy: .private) — \(error, privacy: .private)"
            )
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] could not create backups directory: \(error.localizedDescription)"))
            throw CLIBridgeError.directoryOperationFailed(path: backupsRoot.path)
        }

        // Create a temp dir inside the backups root so the atomic rename stays on-volume.
        let tempDir = backupsRoot.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        guard let validatedTemp = WorkspacePathGuard.validate(tempDir, under: workspace) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] backup temp path rejected by path guard"))
            throw CLIBridgeError.invalidArgument("backup temp path rejected by path guard")
        }
        do {
            try fm.createDirectory(at: validatedTemp, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            AppLogger.cli.error(
                "backup: could not create temp dir: \(validatedTemp.path, privacy: .private) — \(error, privacy: .private)"
            )
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] could not create backup temp dir: \(error.localizedDescription)"))
            throw CLIBridgeError.directoryOperationFailed(path: validatedTemp.path)
        }

        let args = ["-p", profile, "--no-input", "pro", "backup",
                    "--format", "json", "--output", validatedTemp.path]
        let exit = try await run(
            executable: bin,
            arguments: args,
            environment: Self.environmentForJamfCLI(),
            onLine: onLine
        )

        guard exit == 0 else {
            if (try? fm.removeItem(at: validatedTemp)) == nil {
                AppLogger.cli.warning(
                    "backup: failed to remove temp dir after CLI error: \(validatedTemp.path, privacy: .private)"
                )
                onLine(.init(timestamp: Date(), level: .warn,
                    text: "[warn] backup temp dir could not be removed — delete manually: \(validatedTemp.lastPathComponent)"))
            }
            tightenOnSuccess(exit, profile: profile)
            return exit
        }

        // Rename temp dir to a timestamped final name.
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .prefix(15)
        let finalName = "\(ts)"
        let finalDir = backupsRoot.appendingPathComponent(String(finalName), isDirectory: true)
        guard let validatedFinal = WorkspacePathGuard.validate(finalDir, under: workspace) else {
            if (try? fm.removeItem(at: validatedTemp)) == nil {
                AppLogger.cli.warning(
                    "backup: failed to remove temp dir after path guard rejection: \(validatedTemp.path, privacy: .private)"
                )
                onLine(.init(timestamp: Date(), level: .warn,
                    text: "[warn] backup temp dir could not be removed — delete manually: \(validatedTemp.lastPathComponent)"))
            }
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] backup final path rejected by path guard"))
            throw CLIBridgeError.invalidArgument("backup final path rejected by path guard")
        }

        do {
            try fm.moveItem(at: validatedTemp, to: validatedFinal)
        } catch {
            if (try? fm.removeItem(at: validatedTemp)) == nil {
                AppLogger.cli.warning(
                    "backup: failed to remove temp dir after move failure: \(validatedTemp.path, privacy: .private)"
                )
                onLine(.init(timestamp: Date(), level: .warn,
                    text: "[warn] backup temp dir could not be removed — delete manually: \(validatedTemp.lastPathComponent)"))
            }
            AppLogger.cli.error(
                "backup: move failed \(validatedTemp.path, privacy: .private) → \(validatedFinal.path, privacy: .private) — \(error, privacy: .private)"
            )
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] could not finalize backup directory: \(error.localizedDescription)"))
            throw CLIBridgeError.directoryOperationFailed(path: validatedFinal.path)
        }

        // Write manifest.json so BackupLibrary can read label, date, and counts.
        let stats = directoryStats(validatedFinal)
        let effectiveLabel = trimmedLabel ?? ""
        let manifest: [String: Any] = [
            "label": effectiveLabel,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "file_count": stats.fileCount,
            "size_bytes": stats.sizeBytes,
        ]
        do {
            let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            let manifestURL = validatedFinal.appendingPathComponent("manifest.json")
            try manifestData.write(to: manifestURL, options: .atomic)
            try? fm.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: manifestURL.path
            )
        } catch {
            AppLogger.cli.warning(
                "backup: manifest write failed for \(validatedFinal.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] backup manifest write failed — backup was created but BackupsView may show no label or stats"))
        }

        onLine(.init(timestamp: Date(), level: .ok,
                     text: "[ok] backup written: \(validatedFinal.lastPathComponent)"))
        tightenOnSuccess(0, profile: profile)
        return 0
    }

    private func directoryStats(_ url: URL) -> (fileCount: Int, sizeBytes: Int64) {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        var fileCount = 0
        var sizeBytes: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            fileCount += 1
            sizeBytes += Int64(values.fileSize ?? 0)
        }
        return (fileCount, sizeBytes)
    }

    func check(profile: String, csvPath: String?, onLine: @Sendable @escaping (LogLine) -> Void) async throws -> Int32 {
        guard ProfileService.isValid(profile) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] invalid profile name: \(profile)"))
            throw CLIBridgeError.invalidProfile(profile)
        }
        guard await authGuard(profile: profile, onLine: onLine) else {
            return Self.exitCodeUnauthorized
        }
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] no workspace for profile '\(profile)'"))
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let configURL = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] config.yaml not found — run workspace-init first"))
            throw CLIBridgeError.configLoadFailed(path: configURL.path)
        }
        do {
            let config = try ConfigLoader.load(from: configURL)
            let cliProfile = config.jamfCli?.resolvedProfile ?? profile
            onLine(.init(timestamp: Date(), level: .ok,
                         text: "[ok] config.yaml decoded successfully"))
            onLine(.init(timestamp: Date(), level: .ok,
                         text: "[ok] jamf_cli.profile: \(cliProfile.isEmpty ? "(not set)" : cliProfile)"))
            let resolvedDataDir = try? WorkspacePaths.dataDir(for: profile)
            let dataDir = resolvedDataDir ?? workspace.appendingPathComponent("jamf-cli-data")
            if resolvedDataDir == nil {
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] data_dir path resolution failed — using fallback jamf-cli-data/"))
            }
            let snapshotCount = (try? FileManager.default.contentsOfDirectory(
                atPath: dataDir.path))?.count ?? 0
            let dataDirLevel: LogLevel = resolvedDataDir != nil ? .ok : .warn
            onLine(.init(timestamp: Date(), level: dataDirLevel,
                         text: "[\(dataDirLevel == .ok ? "ok" : "warn")] cached snapshots in data_dir: \(snapshotCount)"))

            // CSV column validation — only runs when a CSV path is provided.
            if let csvPath, !csvPath.isEmpty {
                let csvURL = URL(fileURLWithPath: csvPath)
                if FileManager.default.fileExists(atPath: csvURL.path) {
                    do {
                        var text = try String(contentsOf: csvURL, encoding: .utf8)
                        if text.hasPrefix("\u{FEFF}") { text = String(text.dropFirst()) }
                        let firstLine = text.split(separator: "\n", maxSplits: 1).first ?? ""
                        let headers = Set(firstLine.split(separator: ",").map {
                            String($0).trimmingCharacters(in: .init(charactersIn: "\" \t\r"))
                        })
                        let allColumns: [(name: String, value: String)] = [
                            ("computer_name", config.columns?.computerName ?? ""),
                            ("serial_number", config.columns?.serialNumber ?? ""),
                            ("operating_system", config.columns?.operatingSystem ?? ""),
                            ("last_checkin", config.columns?.lastCheckin ?? ""),
                            ("department", config.columns?.department ?? ""),
                            ("email", config.columns?.email ?? ""),
                        ]
                        let configuredColumns = allColumns.filter { !$0.value.isEmpty }
                        var anyMissing = false
                        for col in configuredColumns where !headers.contains(col.value) {
                            onLine(.init(timestamp: Date(), level: .warn,
                                         text: "[warn] column '\(col.value)' (config: \(col.name)) not found in CSV"))
                            anyMissing = true
                        }
                        if !anyMissing {
                            onLine(.init(timestamp: Date(), level: .ok,
                                         text: "[ok] all configured columns found in CSV"))
                        }
                    } catch {
                        onLine(.init(timestamp: Date(), level: .warn,
                                     text: "[warn] could not read CSV '\(csvPath)': \(error.localizedDescription)"))
                    }
                } else {
                    onLine(.init(timestamp: Date(), level: .warn,
                                 text: "[warn] CSV file not found: \(csvPath)"))
                }
            }

            return 0
        } catch {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] \(error.localizedDescription)"))
            throw CLIBridgeError.configLoadFailed(path: workspace.appendingPathComponent("config.yaml").path)
        }
    }

    func initializeWorkspace(
        profile: String,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        guard await ensureWorkspace(profile: profile, onLine: onLine) != nil else {
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        return 0
    }

    func setupLaunchAgent(
        _ schedule: Schedule,
        load: Bool,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        if schedule.isMulti { return try await setupMultiLaunchAgent(schedule, load: load, onLine: onLine) }

        guard await ensureWorkspace(profile: schedule.profile, onLine: onLine) != nil else {
            throw CLIBridgeError.workspaceMissing(profile: schedule.profile)
        }

        let plan: LaunchAgentWriter.SetupPlan
        do {
            plan = try LaunchAgentWriter.nativeSingleWrite(for: schedule, load: load)
        } catch {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] \(error.localizedDescription)"))
            throw CLIBridgeError.launchFailed(reason: error.localizedDescription)
        }

        let action = load ? "writing and loading" : "writing disabled"
        onLine(.init(timestamp: Date(), level: .info, text: "[info] \(action) LaunchAgent \(plan.label)"))
        _ = await LaunchAgentWriter.unload(plan.label)
        if load {
            let exit = await LaunchAgentWriter.loadPlist(at: plan.plistURL)
            if exit != 0 {
                onLine(.init(timestamp: Date(), level: .warn,
                             text: "[warn] launchctl bootstrap returned \(exit) — plist written but not loaded"))
            }
            return exit
        }
        return 0
    }

    private func setupMultiLaunchAgent(
        _ schedule: Schedule,
        load: Bool,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        guard LaunchAgentWriter.label(for: schedule) != nil else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] invalid schedule name for multi-profile label"))
            throw CLIBridgeError.invalidArgument("invalid schedule name for multi-profile label")
        }
        guard ProfileService.isValid(schedule.profile) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] multi-profile schedules need a base workspace profile"))
            throw CLIBridgeError.invalidProfile(schedule.profile)
        }
        guard let execURL = Bundle.main.executableURL else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] cannot resolve app executable path"))
            throw CLIBridgeError.executableNotFound
        }
        do {
            let plan = try LaunchAgentWriter.nativeMultiWrite(
                for: schedule,
                executableURL: execURL,
                load: load
            )
            let action = load ? "writing and loading" : "writing disabled"
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[info] \(action) multi-profile LaunchAgent \(plan.label)"))
            _ = await LaunchAgentWriter.unload(plan.label)
            if load {
                let exit = await LaunchAgentWriter.loadPlist(at: plan.plistURL)
                if exit != 0 {
                    onLine(.init(timestamp: Date(), level: .warn,
                                 text: "[warn] launchctl bootstrap returned \(exit) — plist written but not loaded"))
                }
                return exit
            }
            return 0
        } catch {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] \(error.localizedDescription)"))
            throw CLIBridgeError.launchFailed(reason: error.localizedDescription)
        }
    }

    func runMulti(
        target: MultiTarget,
        subcommand: [String],
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        // B-02: validate every profile name surfaced through the multi target.
        // `cliFlags` may emit `--profiles foo,bar` from a list scope; we cannot
        // trust those strings without re-validation.
        for profile in target.allProfileNames where !ProfileService.isValid(profile) {
            AppLogger.cli.warning("runMulti: rejecting invalid profile name in target")
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] invalid profile name: \(profile)"))
            throw CLIBridgeError.invalidProfile(profile)
        }
        // Auth guard: probe credentials before dispatching live API calls.
        // Uses the first profile in the target for the probe; multi-profile runs
        // share a single auth context in practice (same server, same token).
        if let firstProfile = target.allProfileNames.first {
            guard await authGuard(profile: firstProfile, onLine: onLine) else {
                return Self.exitCodeUnauthorized
            }
        }
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jamf-cli not found"))
            throw CLIBridgeError.executableNotFound
        }
        var args = ["multi"]
        args.append(contentsOf: target.cliFlags)
        if target.sequential { args.append("--sequential") }
        args.append("--")
        args.append(contentsOf: subcommand)
        return try await run(
            executable: bin,
            arguments: args,
            environment: Self.environmentForJamfCLI(),
            onLine: onLine
        )
    }

    /// B-13: minimal environment for jamf-cli subprocess invocations.
    ///
    /// By default `Process` inherits the parent environment verbatim, which
    /// allows variables like `LD_PRELOAD`, `DYLD_INSERT_LIBRARIES`,
    /// `SSL_CERT_FILE`, `JAMF_CLI_*` to alter how jamf-cli validates TLS,
    /// loads dynamic libraries, or interprets its own config. We pin a known
    /// minimal env and only allow-list a small set of variables that proxied
    /// environments legitimately need.
    nonisolated static let jamfCLIAllowedEnvKeys: [String] = [
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "no_proxy",
    ]

    /// M-01: codesign verification gate invoked by `run` and
    /// `runAndCapture` before spawning a process. Returns `nil` when
    /// the spawn should proceed, or a `CLIBridgeError.codesignRejected`
    /// when the gate rejected the binary — in which case the caller MUST NOT
    /// invoke `process.run()`.
    ///
    /// Scoped on basename: only binaries named `jamf-cli` are gated.
    /// Non-jamf-cli executables (`/bin/sh`, `/bin/echo`, etc.) pass
    /// through unconditionally. This keeps the helper safe for any
    /// future caller that flows a non-Jamf binary through CLIBridge.
    ///
    /// On rejection: emits a fatal log line via `onLine` so the user
    /// sees a clear "signature verification failed" message in the
    /// Runs feed, and mirrors to AppLogger for post-mortem forensics.
    nonisolated static func codesignGate(
        executable: URL,
        onLine: (LogLine) -> Void
    ) -> CLIBridgeError? {
        guard executable.lastPathComponent == "jamf-cli" else {
            return nil
        }
        switch JamfCLIIdentity.ensureVerifiedJamfCLI(executable: executable) {
        case .success:
            return nil
        case .failure(let error):
            AppLogger.cli.error(
                "CLIBridge: codesign gate rejected \(executable.path, privacy: .public): \(String(describing: error), privacy: .private)"
            )
            onLine(.init(
                timestamp: Date(),
                level: .fail,
                text: "[fatal] jamf-cli signature verification failed — refusing to launch \(executable.path)"
            ))
            return .codesignRejected
        }
    }

    nonisolated static func environmentForJamfCLI() -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": parent["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": parent["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": parent["TMPDIR"] ?? "/tmp",
        ]
        for key in jamfCLIAllowedEnvKeys {
            if let value = parent[key], !value.isEmpty {
                env[key] = value
            }
        }
        return env
    }

    private func ensureWorkspace(
        profile: String,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> URL? {
        guard ProfileService.isValid(profile),
              let workspace = ProfileService.workspaceURL(for: profile) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] invalid profile name: \(profile)"))
            return nil
        }
        let config = workspace.appendingPathComponent("config.yaml")
        if FileManager.default.fileExists(atPath: config.path) {
            return reconcileConfigProfile(config: config, profile: profile, onLine: onLine)
        }

        onLine(.init(timestamp: Date(), level: .info, text: "[info] initializing workspace for \(profile)"))
        do {
            try ReportEngine.initializeWorkspace(
                profile: profile,
                workspacesRoot: ProfileService.workspacesRoot(),
                seedConfigURL: bundledSeedConfig(),
                onLine: onLine
            )
        } catch {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] workspace init failed for \(profile): \(error.localizedDescription)"))
            return nil
        }
        guard FileManager.default.fileExists(atPath: config.path) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] workspace init failed for \(profile)"))
            return nil
        }
        return reconcileConfigProfile(config: config, profile: profile, onLine: onLine)
    }

    private func reconcileConfigProfile(
        config: URL,
        profile: String,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) -> URL? {
        do {
            let text = try String(contentsOf: config, encoding: .utf8)
            var document = try YAMLCodec.decode(text)
            guard case .mapping(var root) = document.root else { return config }
            var jamfCLI = root.value(for: "jamf_cli")?.mapping ?? YAMLCodec.YAMLMapping(entries: [])
            let current = jamfCLI.value(for: "profile")?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard current != profile else { return config }

            jamfCLI.set("profile", value: .scalar(.string(profile)))
            root.set("jamf_cli", value: .mapping(jamfCLI))
            document.root = .mapping(root)
            let encoded = try YAMLCodec.encode(document, replacingTopLevelKeys: ["jamf_cli"])
            let permissions = (try? FileManager.default.attributesOfItem(atPath: config.path))
                .flatMap { $0[.posixPermissions] as? NSNumber }
            try encoded.write(to: config, atomically: true, encoding: .utf8)
            if let permissions {
                do {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: permissions],
                        ofItemAtPath: config.path
                    )
                } catch {
                    AppLogger.cli.warning(
                        "reconcileConfigProfile: could not restore permissions on \(config.path): \(error)"
                    )
                }
            }
            onLine(.init(
                timestamp: Date(),
                level: .info,
                text: "[info] set jamf_cli.profile to \(profile) in \(config.path)"
            ))
            return config
        } catch {
            onLine(.init(
                timestamp: Date(),
                level: .fail,
                text: "[error] could not update jamf_cli.profile in \(config.path): \(error.localizedDescription)"
            ))
            return nil
        }
    }

    private func bundledSeedConfig() -> URL? {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let candidates = [
            cwd.appendingPathComponent("config.example.yaml"),
            cwd.deletingLastPathComponent().appendingPathComponent("config.example.yaml"),
            Bundle.main.resourceURL?.appendingPathComponent("config.example.yaml"),
        ].compactMap { $0 }
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }
}

// Internal (file-scope dropped) so JamfCLIIdentity-gate tests can
// exercise this path directly — singleDeviceDetail is the only
// production caller.
func runDeviceDetailProcess(
    executable: URL,
    arguments: [String],
    outputDirectory: URL,
    onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
) async -> Int32 {
    await Task.detached(priority: .userInitiated) {
        // M-01: this path bypasses CLIBridge.run / runAndCapture (it
        // builds its own Process for high-throughput per-device detail
        // fetches), so it has to invoke the codesign gate directly.
        if executable.lastPathComponent == "jamf-cli" {
            switch JamfCLIIdentity.ensureVerifiedJamfCLI(executable: executable) {
            case .success:
                break
            case .failure(let error):
                AppLogger.cli.error(
                    "runDeviceDetailProcess: codesign gate rejected \(executable.path, privacy: .public): \(String(describing: error), privacy: .private)"
                )
                onLine?(.init(
                    timestamp: Date(), level: .fail,
                    text: "jamf-cli failed code-signature verification — the binary may be tampered or unsigned. Reinstall jamf-cli."
                ))
                // Codesign rejection: -1 is used here because runDeviceDetailProcess is a
                // fire-and-forget helper (callers check `exit == 0` not the error type),
                // and the singleDeviceDetail caller already surfaces the per-device
                // diagnostic via onLine. The free function's signature stays Int32
                // for backward compatibility with its test seam.
                return -1
            }
        }
        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = CLIBridge.environmentForJamfCLI()
            process.standardOutput = FileHandle.nullDevice
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            // Drain stderr via readabilityHandler before waitUntilExit to prevent
            // a pipe-buffer deadlock when the child writes >~64 KB before exiting.
            // NSLock.lock()/unlock() is @available(*, noasync) — it cannot be called
            // directly in an async function body. Wrapping all lock/unlock pairs inside
            // synchronous methods on the class is the standard workaround used throughout
            // this file (DataBox, RunCompletion, ProcessBox) and is safe because
            // the `@available(*, noasync)` restriction does not propagate through a
            // synchronous call boundary.
            final class StderrBuffer: @unchecked Sendable {
                private let lock = NSLock()
                private var data = Data()
                func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
                func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
            }
            let buf = StderrBuffer()
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                buf.append(chunk)
            }
            try process.run()
            process.waitUntilExit()
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let code = process.terminationStatus
            if code != 0 {
                let errData = buf.snapshot()
                if let msg = String(data: errData, encoding: .utf8),
                   !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    AppLogger.cli.warning(
                        "runDeviceDetailProcess exit \(code): \(msg, privacy: .private)"
                    )
                }
            }
            return code
        } catch {
            AppLogger.cli.error(
                "runDeviceDetailProcess launch failed: \(error.localizedDescription, privacy: .private)"
            )
            onLine?(.init(
                timestamp: Date(), level: .fail,
                text: "jamf-cli could not be launched — check that jamf-cli is installed and the executable is intact."
            ))
            // Launch failure: -1 is used for the same reason as above (Int32 signature, fire-and-forget).
            return -1
        }
    }.value
}

private func deviceCacheFilename(_ raw: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let sanitizedScalars = raw.unicodeScalars.map { scalar in
        allowed.contains(scalar) ? Character(scalar) : "_"
    }
    let sanitized = String(sanitizedScalars)
        .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    let prefix = String((sanitized.isEmpty ? "device" : sanitized).prefix(80))
    return "\(prefix)-\(stableDeviceHash(raw)).json"
}

private func stableDeviceHash(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
}
