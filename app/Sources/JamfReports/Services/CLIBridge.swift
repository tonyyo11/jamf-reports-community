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
        #if DEBUG
        // Tests never launch the jamf-cli installed on this Mac; CI has none, and a test that
        // needs one injects a stub.
        if binary == "jamf-cli", NSClassFromString("XCTestCase") != nil { return nil }
        #endif
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

        /// jamf-cli's own `Error: …` stderr line, which carries no level marker. Colour only:
        /// `LogLevel` and Run History's failure verdict do not read it.
        var isBareError: Bool {
            text.drop(while: \.isWhitespace).lowercased().hasPrefix("error:")
        }

        /// A `[partial]` line streamed from another process arrives at info level
        /// (`LogLevel.from` keeps it there for Run History); the live logs still show it amber.
        var isPartialMarker: Bool {
            text.drop(while: \.isWhitespace).lowercased().hasPrefix("[partial]")
        }
    }

    /// A no-op `onLine` handler for call sites that do not need log streaming.
    /// Use this constant instead of an inline `{ _ in }` closure so the intent
    /// is explicit and the constant type is guaranteed to match the parameter.
    /// `nonisolated` so it can be referenced from nonisolated static functions
    /// (e.g. `codesignGate` call sites in `ProfileService`).
    nonisolated static let noOpOnLine: @Sendable (LogLine) -> Void = { _ in }

    /// Feeds streamed run lines into the in-app `LogBuffer` so the Settings →
    /// Logging viewer shows live collect progress in signed builds (where the
    /// old `OSLogStore` reader failed with a generic error). These are the
    /// user-facing run lines; `LogViewerView` scrubs them with `LogRedactor` at
    /// display and export.
    nonisolated static let bufferingOnLine: @Sendable (LogLine) -> Void = { line in
        let level: LogEntry.Level
        switch line.level {
        case .info, .ok: level = .info
        case .warn:      level = .notice
        case .fail:      level = .error
        }
        LogBuffer.shared.append(
            LogEntry(date: line.timestamp, category: "collect", level: level, message: line.text)
        )
    }

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
            guard let entries = FileManager.snapshotFolderEntries(in: dir) else {
                // Missing is expected on first run before any snapshots exist; a folder that is
                // there but refused (a link) or unreadable is named.
                if FileManager.default.fileExists(atPath: dir.path) {
                    AppLogger.cli.warning(
                        "cachedJSONSnapshots: could not enumerate \(type, privacy: .public) for \(profile, privacy: .public): not a readable snapshot folder"
                    )
                }
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
                    let data: Data
                    do {
                        data = try BoundedFile.read(
                            item.url, limit: BoundedFile.snapshotLimit, followSymlinks: false,
                            inside: dataDir)
                    } catch {
                        let name = item.url.lastPathComponent
                        let reason = String(describing: error)
                        AppLogger.cli.warning(
                            "snapshot skipped \(name, privacy: .public): \(reason, privacy: .public)"
                        )
                        return nil
                    }
                    // S-01: reject truncated / malformed snapshots so a
                    // partially-written file from a crash mid-write does
                    // not render green in AuditView.
                    // Structural JSON probe is the
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
    /// - Parameter timeout: seconds before the child is terminated, as for ``runAndCapture``;
    ///   the call then returns ``exitCodeTimedOut``. `nil` waits as long as the child runs.
    nonisolated func run(
        executable: URL,
        arguments: [String],
        cwd: URL? = nil,
        environment: [String: String] = CLIBridge.environmentForJamfCLI(),
        timeout: TimeInterval? = nil,
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

            /// Timeout path only: a grandchild may hold the pipes after the child is gone,
            /// so stop waiting for their EOF. Shares the single-resume flag with `finish`.
            @discardableResult
            func forceResume(_ code: Int32) -> Bool {
                let shouldResume: Bool
                lock.lock()
                shouldResume = !resumed
                if shouldResume { resumed = true }
                lock.unlock()
                if shouldResume { continuation.resume(returning: code) }
                return shouldResume
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
        let box = TimedProcessBox()

        let code = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let completion = RunCompletion(continuation)
                let process = Process()
                box.set(process)
                process.executableURL = executable
                process.arguments = arguments
                if let cwd { process.currentDirectoryURL = cwd }
                process.environment = environment
                // Never the caller's terminal: `jamf-reports` started from a shell must not
                // leave jamf-cli reading what the user types.
                process.standardInput = FileHandle.nullDevice

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                // One reader per pipe: a read can end mid-character or mid-line, and a
                // pipe's handler is never called concurrently with itself.
                let stdoutLines = PipeLineReader()
                let stderrLines = PipeLineReader()
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    let lines = stdoutLines.lines(from: data)
                    for line in lines {
                        onLine(.init(
                            timestamp: Date(), level: LogLevel.from(line: line), text: line))
                    }
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        completion.markStdoutEOF()
                    }
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    let lines = stderrLines.lines(from: data)
                    for line in lines { onLine(Self.stderrLine(line)) }
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        completion.markStderrEOF()
                    }
                }

                box.setReadHandles([stdout.fileHandleForReading, stderr.fileHandleForReading])
                process.terminationHandler = { proc in
                    let status = proc.terminationStatus
                    completion.markTerminated(status)
                    guard box.didTimeOut else { return }
                    DispatchQueue.global().asyncAfter(deadline: .now() + CLIBridge.eofGraceAfterExit) {
                        if completion.forceResume(status) { box.clearReadHandlers() }
                    }
                }

                do {
                    try process.run()
                    box.stopIfClosing()
                    // Belt-and-suspenders: if cancellation arrived before run()
                    // (onCancel fired first, read nil, returned without terminating),
                    // terminate the now-running process ourselves.
                    if Task.isCancelled { process.terminate() }
                    if let timeout { box.armTimeout(timeout) }
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
        return box.didTimeOut ? Self.exitCodeTimedOut : code
    }
    /// Run an arbitrary command, streaming each line through `onLine` and returning
    /// the collected stdout + the process exit code.
    ///
    /// - Parameter environment: see ``run(executable:arguments:cwd:environment:onLine:)``.
    /// - Parameter timeout: seconds before the child is terminated (SIGTERM, then SIGKILL after
    ///   ``timeoutKillGrace``) and the call returns ``exitCodeTimedOut`` with the stdout read
    ///   so far, without waiting for pipe EOF. `nil` waits as long as the child runs.
    nonisolated func runAndCapture(
        executable: URL,
        arguments: [String],
        cwd: URL? = nil,
        environment: [String: String] = CLIBridge.environmentForJamfCLI(),
        timeout: TimeInterval? = nil,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> (Int32, Data) {
        final class DataBox: @unchecked Sendable {
            private var data = Data()
            private let lock = NSLock()
            func append(_ newData: Data) {
                lock.lock()
                data.append(newData)
                lock.unlock()
            }
            /// A timed-out call resumes without waiting for EOF, so a readability block can
            /// still be appending while the result is copied.
            func snapshot() -> Data {
                lock.lock(); defer { lock.unlock() }
                return data
            }
        }
        let box = DataBox()

        // M-01: same gate as `run` — verify before spawn.
        if let gateError = Self.codesignGate(executable: executable, onLine: onLine) {
            throw gateError
        }

        // Resumes the async continuation only once BOTH pipes have reached EOF
        // (an empty `availableData` delivery) and the process has terminated.
        // Resuming on `terminationHandler` alone races the final
        // `readabilityHandler` deliveries — they run on different GCD queues — so
        // under CI load the continuation can resume before the last stdout chunk
        // is appended, truncating the captured payload to empty (Epic #102). The
        // same race on stderr dropped the lines collect's `StderrSignalWatcher`
        // classifies a command that exits 0 without data from (#207 G24).
        final class CaptureCompletion: @unchecked Sendable {
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
            /// bypassing the EOF wait (no child means the pipes will never
            /// deliver EOF).
            func failWithLaunchError(_ error: CLIBridgeError) {
                let shouldResume: Bool
                lock.lock()
                shouldResume = !resumed
                if shouldResume { resumed = true }
                lock.unlock()
                if shouldResume { continuation.resume(throwing: error) }
            }

            /// Timeout path only: the child has exited but a grandchild may still hold the
            /// pipes, so do not wait for their EOF. Shares the single-resume flag with
            /// `finish`, so whichever arrives first is the only resume.
            @discardableResult
            func forceResume(_ code: Int32) -> Bool {
                let shouldResume: Bool
                lock.lock()
                shouldResume = !resumed
                if shouldResume { resumed = true }
                lock.unlock()
                if shouldResume { continuation.resume(returning: code) }
                return shouldResume
            }

            private func finish(_ mutate: (CaptureCompletion) -> Void) {
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

        let processBox = TimedProcessBox()

        let code = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                let completion = CaptureCompletion(continuation)
                let process = Process()
                processBox.set(process)
                process.executableURL = executable
                process.arguments = arguments
                if let cwd { process.currentDirectoryURL = cwd }
                process.environment = environment
                process.standardInput = FileHandle.nullDevice

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
                // A marker `StderrSignalWatcher` reads can straddle two reads, so lines are
                // rebuilt from bytes; the handler is never called concurrently with itself.
                let stderrLines = PipeLineReader()
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    let lines = stderrLines.lines(from: data)
                    for line in lines { onLine(Self.stderrLine(line)) }
                    if data.isEmpty {
                        // EOF: every stderr line, an unterminated last one included, has been
                        // through onLine. Clearing the handler here, not in terminationHandler,
                        // is what lets a line still in the pipe at exit arrive.
                        handle.readabilityHandler = nil
                        completion.markStderrEOF()
                    }
                }

                processBox.setReadHandles(
                    [stdout.fileHandleForReading, stderr.fileHandleForReading]
                )
                process.terminationHandler = { proc in
                    processBox.disarmTimeout()
                    if processBox.didTimeOut {
                        // A timed-out call returns what it has; a grandchild holding a pipe
                        // open must not keep it waiting for EOF.
                        processBox.clearReadHandlers()
                        // The stderr handler will not see EOF now; keep an unterminated last
                        // line. stdout is captured whole, with no line reader to flush.
                        for line in stderrLines.finish() { onLine(Self.stderrLine(line)) }
                        completion.forceResume(proc.terminationStatus)
                    } else {
                        completion.markTerminated(proc.terminationStatus)
                        // A grandchild that inherited a pipe keeps it open after the child is
                        // gone. EOF normally lands within milliseconds of the exit; give up
                        // waiting for it after the kill grace and return what was read.
                        let status = proc.terminationStatus
                        DispatchQueue.global().asyncAfter(
                            deadline: .now() + CLIBridge.eofGraceAfterExit
                        ) {
                            guard completion.forceResume(status) else { return }
                            processBox.clearReadHandlers()
                            for line in stderrLines.finish() { onLine(Self.stderrLine(line)) }
                        }
                    }
                }

                do {
                    try process.run()
                    processBox.stopIfClosing()
                    if Task.isCancelled { process.terminate() }
                    if let timeout { processBox.armTimeout(timeout) }
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
        if processBox.didTimeOut, let timeout {
            AppLogger.cli.warning(
                "CLIBridge.runAndCapture: terminated after \(timeout, privacy: .public)s timeout"
            )
            onLine(.init(timestamp: Date(), level: .warn,
                         text: "[warn] timed out after \(Int(timeout.rounded(.up)))s — stopped"))
            return (Self.exitCodeTimedOut, box.snapshot())
        }
        return (code, box.snapshot())
    }

    /// Fluent helper for the most common CLI flows the GUI surfaces.
    /// `aiNarrative` (F3) is set only by GUI-generate call sites; every other
    /// caller leaves the nil default. `htmlWithWorkbook: false` is for the one caller that
    /// writes the HTML report itself in the same run (`generateAll`), so it is written once.
    func generate(
        profile: String,
        template: any ReportTemplate = FullInstanceTemplate(),
        outputDir: URL? = nil,
        aiNarrative: String? = nil,
        htmlWithWorkbook: Bool = true,
        csvFolder: Bool = false,
        now: Date = Date(),
        written: RunArtifacts? = nil,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        try await AttentionLog.recording(profile: profile) {
            try await generateRecording(
                profile: profile, template: template, outputDir: outputDir,
                aiNarrative: aiNarrative, htmlWithWorkbook: htmlWithWorkbook,
                csvFolder: csvFolder, now: now, written: written, onLine: onLine)
        }
    }

    private func generateRecording(
        profile: String,
        template: any ReportTemplate,
        outputDir: URL?,
        aiNarrative: String?,
        htmlWithWorkbook: Bool,
        csvFolder: Bool,
        now: Date,
        written: RunArtifacts?,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        try await ensureWorkspace(profile: profile, onLine: onLine)
        // A Generate with no collect before it (the Overview, onboarding) still names a drift.
        SharedConfigPin.checkpoint(profile: profile, onLine: onLine)
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            let msg = "error: workspace URL unexpectedly nil for profile '\(profile)' after ensureWorkspace — this is a programmer error"
            onLine(LogLine(timestamp: Date(), level: .fail, text: msg))
            AppLogger.cli.error("\(msg)")
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let configURL = workspace.appendingPathComponent("config.yaml")
        let config = try loadConfig(at: configURL, onLine: onLine)
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] could not resolve data_dir for \(profile)"))
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let engine = ReportEngine(config: config, dataDir: dataDir, profile: profile)
        let defaultURL = try engine.resolveOutputURL(
            stem: ExportNaming.reportKind(for: .xlsx, schoolMode: false), profile: profile,
            onLine: outputDir == nil ? onLine : nil)
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
            let generated = try await engine.generateReport(
                outputURL: outputURL, template: template,
                aiNarrative: aiNarrative, csvFolder: csvFolder, now: now, onLine: onLine
            )
            let failures = generated.failures
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
            var htmlURL: URL?
            if htmlWithWorkbook {
                htmlURL = await engine.writeHTMLWithWorkbook(
                    besideWorkbook: outputURL, template: template,
                    aiNarrative: aiNarrative, onLine: onLine)
            }
            await RunArtifacts.record(
                [outputURL, htmlURL, generated.csvFolder].compactMap { $0 }, in: written,
                config: config, profile: profile, onLine: onLine)
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
    ) throws -> ReportConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ReportConfig()
        }
        do {
            return try ConfigLoader.load(from: url)
        } catch {
            let msg = "[error] config.yaml parse failed — aborting: \(error.localizedDescription)"
            AppLogger.cli.error("\(msg, privacy: .private)")
            onLine(.init(timestamp: Date(), level: .fail, text: msg))
            throw CLIBridgeError.configLoadFailed(
                path: url.path,
                detail: (error as? ConfigLoader.LoadError)?.keyPathDetail
                    ?? ConfigLoader.describeDecodingFailure(error)
            )
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
        csvFolder: Bool = false,
        now: Date = Date(),
        written: RunArtifacts? = nil,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        guard await authGuard(profile: profile, onLine: onLine) else {
            return Self.exitCodeUnauthorized
        }
        try await ensureWorkspace(profile: profile, onLine: onLine)
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            let msg = "error: workspace URL unexpectedly nil for profile '\(profile)' after ensureWorkspace — this is a programmer error"
            onLine(LogLine(timestamp: Date(), level: .fail, text: msg))
            AppLogger.cli.error("\(msg)")
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let configURL = workspace.appendingPathComponent("config.yaml")
        let config = try loadConfig(at: configURL, onLine: onLine)
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] could not resolve data_dir for \(profile)"))
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let engine = ReportEngine(config: config, dataDir: dataDir)
        let outputURL = try engine.resolveOutputURL(
            stem: ExportNaming.reportKind(for: .xlsx, schoolMode: true), profile: profile,
            onLine: onLine)
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
            let generated = try await ReportEngine.schoolGenerateReport(
                config: config,
                dataDir: dataDir,
                outputURL: outputURL,
                profile: profile,
                csvFolder: csvFolder,
                now: now,
                onLine: onLine
            )
            let failures = generated.failures
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
            await RunArtifacts.record(
                [outputURL, generated.csvFolder].compactMap { $0 }, in: written,
                config: config, profile: profile, onLine: onLine)
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
    ///
    /// `force: true` bypasses the once-per-day FULL-collect guard in
    /// `ReportEngine.collect` when `tiers` is left at its default (full) set.
    /// For a narrower set — e.g. `RefreshCoordinator`'s `[.refresh]` — that
    /// guard never applies regardless; what `force: true` bypasses there is
    /// the per-kind cadence filter, so ad-hoc Refresh calls still always
    /// fetch fresh data. Scheduled collects (via `main.swift --scheduled-run`)
    /// pass `force: false` (the default).
    ///
    /// Holds the tick lock throughout (`holdingTickLock`), and throws
    /// `CLIBridgeError.tickLockHeld` before the auth probe when a tick holds it, or
    /// `CLIBridgeError.collectInProgress` when another collect is running in this app,
    /// `.generateInProgress` for a report. Inside `holdingGenerate` it runs under that hold.
    func collect(
        profile: String,
        tiers: Set<CollectionTier> = Set(CollectionTier.allCases),
        force: Bool = false,
        now: Date = Date(),
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        try await Self.holdingTickLock {
            try await self.collectHoldingTickLock(
                profile: profile, tiers: tiers, force: force, now: now, onLine: onLine)
        }
    }

    private func collectHoldingTickLock(
        profile: String,
        tiers: Set<CollectionTier>,
        force: Bool,
        now: Date,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        guard await authGuard(profile: profile, onLine: onLine) else {
            return Self.exitCodeUnauthorized
        }
        try await ensureWorkspace(profile: profile, onLine: onLine)
        // Honor the Settings "Skip expensive collections" toggle. UserDefaults
        // backs the @AppStorage in SettingsView, so this is a direct read.
        // Scheduled collects run from main.swift and pass skipExpensive=false
        // unconditionally — the toggle only affects manual GUI refreshes.
        let skipExpensive = UserDefaults.standard.bool(forKey: "skipExpensiveCollections")
        // Load config for product-type routing. Failure degrades to Jamf Pro
        // (same behaviour as before the router existed) and logs loudly.
        let config: ReportConfig? = {
            guard let workspace = ProfileService.workspaceURL(for: profile) else { return nil }
            let url = workspace.appendingPathComponent("config.yaml")
            let loaded = try? ConfigLoader.load(from: url)
            if loaded == nil {
                AppLogger.cli.warning(
                    "[routing] could not load config for \(profile, privacy: .public) — defaulting to Jamf Pro"
                )
            }
            return loaded
        }()
        do {
            try await CollectRouter.run(
                profile: profile,
                tiers: tiers,
                skipExpensive: skipExpensive,
                force: force,
                config: config,
                now: now,
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

    /// `narrative` (F3, GUI-only) is asked for between the collect and the generate, only
    /// when the collect worked: it reads the snapshots the collect just wrote, so a narrative
    /// asked for before it would describe the stale ones the report is not built from. The
    /// whole run holds the tick lock (`holdingGenerate`).
    func collectThenGenerate(
        profile: String,
        narrative: (() async -> String?)? = nil,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        // Auth is checked inside collect(); skipping a separate probe here avoids calling
        // jamf-cli pro auth token twice for the combined collect+generate flow.
        onLine(.init(timestamp: Date(), level: .info, text: "[info] collecting jamf-cli snapshots for \(profile)"))
        // One clock for the run, so a collect that crosses midnight and the report that follows
        // it date the day's summary the same.
        let runStart = Date()
        return try await Self.runCollectThenGenerate(
            // force: true — collectThenGenerate is always a GUI "Run now" action; the
            // once-per-day guard must not silently skip a user-triggered collect+generate.
            collect: {
                try await self.collect(profile: profile, force: true, now: runStart, onLine: onLine)
            },
            narrative: narrative,
            generate: { aiNarrative in
                onLine(.init(timestamp: Date(), level: .info,
                             text: "[info] generating report from cached snapshots"))
                return try await self.generate(profile: profile, aiNarrative: aiNarrative,
                                               now: runStart, onLine: onLine)
            }
        )
    }

    /// Orchestration core of `collectThenGenerate`, with the three steps injected so tests
    /// can order them without a live jamf-cli (the same seam as `runGenerateAll`). A failed
    /// collect returns its exit code before the narrative is asked for. One `holdingGenerate`
    /// covers all three, so the lock is never released between the collect and the report.
    static func runCollectThenGenerate(
        collect: () async throws -> Int32,
        narrative: (() async -> String?)?,
        generate: (String?) async throws -> Int32
    ) async throws -> Int32 {
        // The collect and the generate each run the pin checkpoint; the run reports a drift once.
        try await SharedConfigPin.announcingOnce {
            try await holdingGenerate {
                let collectExit = try await collect()
                guard collectExit == 0 else { return collectExit }
                return try await generate(await narrative?())
            }
        }
    }

    // MARK: - jamf-cli exit codes (jamf-cli Error Handling & Exit Codes spec)
    nonisolated static let exitCodeUsage: Int32 = 2          // bad flags / missing args — indicates a caller bug
    nonisolated static let exitCodeUnauthorized: Int32 = 3   // HTTP 401 — invalid or expired credentials
    nonisolated static let exitCodeNotFound: Int32 = 4       // HTTP 404 — resource does not exist
    nonisolated static let exitCodePermissionDenied: Int32 = 5  // HTTP 403 — account lacks required API privileges
    nonisolated static let exitCodeRateLimited: Int32 = 6    // HTTP 429 — server throttling; transient, self-resolving
    nonisolated static let exitCodePartialFailure: Int32 = 7 // partial failure (v1.19.0+): some ops succeeded, stdout has valid JSON
    // Refused by policy (v1.28.0+): correctly invoked, but the resolved credentials
    // cannot reach the API that serves it. Never succeeds on retry.
    nonisolated static let exitCodeRefusedByPolicy: Int32 = 8
    /// Returned by `runAndCapture(timeout:)` when it stopped the child. jamf-cli never exits
    /// with it; a signal-terminated child would otherwise read as exit 15.
    nonisolated static let exitCodeTimedOut: Int32 = -2
    /// Limit on the `pro auth token` probe. jamf-cli leaves body transfer unbounded, so a
    /// server that stalls mid-response would otherwise hold the tick lock until its give-up.
    nonisolated static let tokenProbeTimeout: TimeInterval = 60
    /// Limit on one `pro backup`, which holds the tick lock throughout. Generous: a large
    /// tenant's backup is legitimately long; the limit only ends a stalled transfer.
    nonisolated static let backupTimeout: TimeInterval = 2 * 60 * 60
    /// Seconds a child gets to act on the timeout's SIGTERM before `runAndCapture` sends SIGKILL.
    nonisolated static let timeoutKillGrace: TimeInterval = 3
    /// Stops every jamf-cli (or other) child this process started through `CLIBridge`, then
    /// returns how many it signalled. The tick's six-hour give-up calls it before exiting, since
    /// ending the tick leaves a call that never answered running; it blocks up to `grace`.
    @discardableResult
    nonisolated static func terminateRunningChildren(
        grace: TimeInterval = timeoutKillGrace
    ) -> Int {
        TimedProcessBox.terminateAllRunning(grace: grace)
    }

    /// Seconds `runAndCapture` waits for pipe EOF after the child exits normally, before it
    /// stops reading: a process the child left running can hold the pipes open indefinitely.
    nonisolated static let eofGraceAfterExit: TimeInterval = timeoutKillGrace

    /// Translate a jamf-cli exit code into a plain-language explanation with a
    /// remediation hint, prefixed by the operation. Replaces raw "… exit N"
    /// strings so the user learns the cause (auth / privileges / throttling /
    /// network) and what to do next, not just a number.
    ///
    /// - Parameters:
    ///   - code: the process exit code.
    ///   - operation: human phrase for what failed, e.g. "HTML report generation".
    /// True for the exit codes after which `pro backup` has left output on
    /// disk that retention must prune: `0`, and `exitCodePartialFailure` (7 — a
    /// partial export is still finalized to `backups/<timestamp>/`). Both
    /// backup call sites (scheduled run, CLI) share this one rule; they used
    /// to spell it out separately and drifted apart.
    nonisolated static func backupOutputIsPrunable(exit code: Int32) -> Bool {
        code == 0 || code == exitCodePartialFailure
    }

    /// The sentence for a locked login keychain, shared by `explainExit` and the auth probe.
    nonisolated static let keychainLockedDetail = "the login keychain is locked, so jamf-cli "
        + "could not read this profile's stored credentials. "
        + FailureCause.keychainLockedHint + "."

    /// `cause` (from `FailureCause.classify`) names a failure the exit code alone cannot: a
    /// locked keychain exits 1, like a network error.
    nonisolated static func explainExit(
        _ code: Int32, operation: String, cause: FailureCause? = nil
    ) -> String {
        if cause?.kind == .keychainLocked { return "\(operation) failed: \(keychainLockedDetail)" }
        let detail: String
        switch code {
        case exitCodeUnauthorized:
            detail = "authentication failed (401) — this profile's credentials are invalid or "
                + "expired. Re-authenticate it from Data Sources. A Jamf Platform API "
                + "integration is valid for six months; an expired one needs a replacement in "
                + "Jamf Account. A gateway URL in a different region (US, EU, APAC) from the "
                + "integration fails the same way."
        case exitCodePermissionDenied:
            detail = "permission denied (403) — this profile lacks a required permission. For a "
                + "Jamf Pro API client, grant the privilege to its API role in Jamf Pro; for a "
                + "Jamf Platform API integration, grant the permission to the integration in "
                + "Jamf Account."
        case exitCodeNotFound:
            detail = "not found (404) — the server didn't have the requested resource."
        case exitCodeRateLimited:
            detail = "rate limited (429) — Jamf Pro is throttling requests. Wait a minute, "
                + "then try again."
        case exitCodePartialFailure:
            detail = "partial failure (exit 7) — some sub-operations failed but partial data "
                + "was returned and saved. Review this run's log output for the specific "
                + "failures."
        case exitCodeTimedOut:
            detail = "timed out: jamf-cli did not answer within its time limit and was "
                + "stopped. The server may be overloaded or unreachable; the next run tries "
                + "again."
        case exitCodeUsage:
            detail = "internal argument error (exit 2) — please report this along with this "
                + "run's log output. On a Platform API profile, exit 2 is also the retired "
                + "`apigw.jamf.com` host or an environment/tenant scope conflict — run "
                + "`jamf-cli config validate`."
        case exitCodeRefusedByPolicy:
            detail = "refused by policy (exit 8) — the command is outside what this "
                + "profile's API publishes: on a Platform gateway profile, a Jamf Pro or "
                + "Classic command the Platform API does not serve; on an instance "
                + "profile, a Platform-only command. Use an oauth2 profile against the "
                + "Jamf Pro instance for this command. `jamf-cli commands -o json` lists "
                + "the refusals for the binary in hand (gateway == \"unserved\")."
        case 1:
            detail = "exit 1 — usually a network error or a per-command failure. Review this "
                + "run's log output for the failing command."
        default:
            detail = "exit \(code) — review this run's log output for details."
        }
        return "\(operation) failed: \(detail)"
    }

    /// Maps a thrown operation error to a user-facing cause+remediation string,
    /// routing exit-code-bearing engine errors through `explainExit`. Codeless
    /// verdicts map to their canonical code (auth-dead → 401, all-kinds-dead → 1);
    /// anything else falls back to the localized description.
    nonisolated static func explainOperationError(_ error: Error, operation: String) -> String {
        // A refusal, not a failure: the operation never started.
        if let refused = error as? CLIBridgeError, refused.isCollectRefusal {
            return refused.localizedDescription
        }
        // Already a sentence naming the operation and the profile's product.
        if case let CLIBridgeError.wrongProduct(refusal) = error { return refusal }
        if case let ReportEngineError.collectFailed(_, exitCode) = error {
            return explainExit(exitCode, operation: operation)
        }
        if case ReportEngineError.authExpired = error {
            return explainExit(exitCodeUnauthorized, operation: operation)   // 3 / 401
        }
        if case let ReportEngineError.collectDead(_, _, cause) = error {
            switch cause {
            case .outage:
                return explainExit(1, operation: operation)                   // all kinds failed
            case .noPermission:
                return explainExit(exitCodePermissionDenied, operation: operation)
            case .keychainLocked:
                return "\(operation) failed: \(keychainLockedDetail)"
            case .rejectedID:
                return "\(operation) failed: the Jamf Platform gateway rejected this profile's "
                    + "environment or tenant ID. Correct it with Update credentials in Data "
                    + "Sources; the environment ID is in the integration's details in Jamf Account."
            }
        }
        // An error that carries jamf-cli's own text (a launch or decode failure quoting it).
        if FailureCause.mentionsLockedKeychain(error.localizedDescription) {
            return "\(operation) failed: \(keychainLockedDetail)"
        }
        return "\(operation) failed — \(error.localizedDescription)"
    }

    /// Guards a live-API operation by probing `pro auth token` first.
    ///
    /// Resolves the profile's auth method via `jamf-cli config list` (falls back to local
    /// workspace discovery if jamf-cli is absent). Skips the probe for Jamf School profiles
    /// (`authMethod == "apikey"`) — school uses API-key auth with no bearer token to inspect.
    ///
    /// Returns `true` when it's safe to proceed. On failure, emits a `[error]` log
    /// line with a remediation hint and returns `false` — callers must return
    /// a non-zero exit code immediately without running any further API calls.
    ///
    /// A probe that gets no answer within `probeTimeout` is neither a rejection nor a pass:
    /// the guard logs one `[warn]` and lets the command run, as `collect` does for
    /// `AuthProbeResult.unconfirmed`. The command's own 401 then reports dead credentials.
    /// `_testExecutable` is a test seam; production resolves jamf-cli.
    nonisolated func authGuard(
        profile: String,
        probeTimeout: TimeInterval = CLIBridge.tokenProbeTimeout,
        _testExecutable: URL? = nil,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async -> Bool {
        AppLogger.auth.debug("auth probe profile=\(profile, privacy: .public)")
        guard !ProfileAuthMethod.skipsProAuthProbe(profile: profile) else { return true }
        let probe = await probeToken(
            for: profile, executable: _testExecutable, timeout: probeTimeout
        )
        let status: TokenStatus?
        switch probe {
        case .timedOut:
            let msg = "[warn] auth check timed out after \(Int(probeTimeout.rounded(.up))) s for "
                + "profile '\(profile)'; could not confirm the credentials. Continuing; the "
                + "command reports a rejected credential itself."
            AppLogger.auth.warning("\(msg, privacy: .public)")
            onLine(.init(timestamp: Date(), level: .warn, text: msg))
            return true
        case .keychainLocked:
            let msg = "[error] auth check failed for profile '\(profile)': "
                + Self.keychainLockedDetail
            AppLogger.auth.error("\(msg, privacy: .public)")
            onLine(.init(timestamp: Date(), level: .fail, text: msg))
            return false
        case .status(let result):
            status = result
        }
        if let status, status.isValid, !status.isExpired { return true }
        if ExecutableLocator.locate("jamf-cli") == nil {
            onLine(.init(
                timestamp: Date(), level: .fail,
                text: "[error] jamf-cli not found — install via Homebrew: brew install jamf-cli"
            ))
        } else {
            onLine(.init(
                timestamp: Date(), level: .fail,
                text: "[error] auth check failed for profile '\(profile)' — re-authenticate "
                      + "with: jamf-cli -p \(ProfileName.shellWord(profile)) pro auth token"
            ))
        }
        return false
    }

    /// The refusal, after one `[error]` line, when the workspace's `profiles:` block cannot run
    /// (`EnvironmentProfiles.refusal`), or when `profile` is known to belong to another product
    /// (Jamf School, Protect, Security Cloud) or is an organization-level integration: no `pro`
    /// command may run against it. Nil for a Jamf Pro profile and for one that cannot be
    /// resolved. Reading config.yaml and the lookup (which can run `jamf-cli config list`) run
    /// detached: most callers are on the main actor. `resolved` is the test seam.
    nonisolated static func refusesProCommand(
        profile: String, operation: String, onLine: (@Sendable (LogLine) -> Void)?,
        resolved: @escaping @Sendable (String) -> ProfileAuthMethod.Resolved? = {
            ProfileAuthMethod.resolve(profile: $0)
        }
    ) async -> String? {
        let refusal = await Task.detached {
            EnvironmentProfiles.read(workspace: profile).refusal(workspace: profile)
                ?? resolved(profile)?.proRefusal(profile: profile, operation: operation)
        }.value
        guard let refusal else { return nil }
        onLine?(.init(timestamp: Date(), level: .fail, text: "[error] \(refusal)"))
        return refusal
    }

    /// The `[error]` line for a name that failed `ProfileService.isValid`, filtered like
    /// `ProfileName.invalidMessage`.
    nonisolated static func invalidProfileLine(_ profile: String) -> LogLine {
        .init(timestamp: Date(), level: .fail,
              text: "[error] invalid profile name: \(ConfigSchema.displayText(profile))")
    }

    nonisolated func validateConnection(
        profile: String,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        guard ProfileService.isValid(profile) else {
            onLine(Self.invalidProfileLine(profile))
            throw CLIBridgeError.invalidProfile(profile)
        }
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jamf-cli not found"))
            throw CLIBridgeError.executableNotFound
        }
        guard await authGuard(profile: profile, onLine: onLine) else {
            return Self.exitCodeUnauthorized
        }
        // `config validate` ignores -p and checks every profile in jamf-cli's file, so the
        // verdict is taken from the JSON rows that concern this profile. runAndCapture keeps
        // stdout out of onLine; its stderr "Error: config validation failed" is dropped here
        // because another profile may be the one that failed.
        let (code, stdout) = try await runAndCapture(
            executable: bin,
            arguments: Self.configValidateArguments(profile: profile),
            environment: Self.environmentForJamfCLI(),
            onLine: { line in
                if line.text.contains("config validation failed") { return }
                onLine(line)
            }
        )
        let verdict = Self.validationVerdict(stdout: stdout, exitCode: code, profile: profile)
        for failure in verdict.failures {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] \(failure)"))
        }
        return verdict.exit
    }

    private struct ValidateCheck: Decodable {
        let scope: String
        let name: String
        let status: String
        let message: String?
    }

    /// Reduces `jamf-cli config validate --output json` (an array of `{scope, name, status,
    /// message}`) to the rows for `config` and `profile`; another profile's failing row does
    /// not fail this one, nor does the apikey false positive below. Output that does not parse
    /// keeps `exitCode`.
    nonisolated static func validationVerdict(
        stdout: Data, exitCode: Int32, profile: String
    ) -> (exit: Int32, failures: [String]) {
        guard let checks = try? JSONDecoder().decode([ValidateCheck].self, from: stdout) else {
            return (exitCode, [])
        }
        let failures = checks
            .filter { ($0.scope == "config" || $0.scope == profile) && $0.status == "fail" }
            // jamf-cli's validAuthMethods (internal/commands/config.go, 1.33.0) lacks apikey, so it
            // fails every Jamf School profile's auth-method row; the credentials are fine.
            .filter { !($0.scope == profile && $0.name == "auth-method"
                && $0.message == #"invalid "apikey""#) }
            .map { check in
                let message = check.message ?? ""
                return "\(check.scope) \(check.name) failed" + (message.isEmpty ? "" : ": \(message)")
            }
        let failing = exitCode == 0 ? 1 : exitCode
        guard failures.isEmpty else { return (failing, failures) }
        // Every profile jamf-cli holds emits rows, so none means it does not have this one.
        guard checks.contains(where: { $0.scope == profile }) else {
            return (failing, ["\(profile) not found in jamf-cli's config"])
        }
        return (0, [])
    }

    /// What `probeToken` found: the token status, or no answer within the time limit.
    enum TokenProbe: Sendable {
        case status(TokenStatus?)
        case timedOut
        /// jamf-cli could not read the profile's credentials from a locked keychain.
        case keychainLocked
    }

    /// Fetch the token status for `profile` using `jamf-cli pro auth token --output json`.
    ///
    /// Returns a `TokenStatus` with `isValid: false` (never throws) when:
    /// - jamf-cli is not installed
    /// - the profile slug is invalid
    /// - jamf-cli exits non-zero (unauthenticated, old version, unknown command)
    /// - JSON is missing or malformed
    /// - the probe did not answer within `tokenProbeTimeout`
    ///
    /// Returns nil for an API-key profile (Jamf School) or one known to be another product,
    /// which has no `pro` bearer token: the probe would fail and read as "not authenticated"
    /// for working credentials.
    nonisolated func tokenStatus(for profile: String) async -> TokenStatus? {
        guard !ProfileAuthMethod.skipsProAuthProbe(profile: profile) else { return nil }
        switch await probeToken(for: profile, executable: nil, timeout: Self.tokenProbeTimeout) {
        case .status(let status): return status
        case .timedOut: return TokenStatus.make(profile: profile, token: nil, expiresAt: nil)
        case .keychainLocked: return TokenStatus.keychainLocked(profile: profile)
        }
    }

    /// The probe behind `tokenStatus` and `authGuard`; the guard needs a timeout told apart
    /// from a rejection. `executable` overrides the jamf-cli lookup (tests).
    nonisolated func probeToken(
        for profile: String,
        executable: URL?,
        timeout: TimeInterval
    ) async -> TokenProbe {
        guard ProfileService.isValid(profile),
              let bin = executable ?? ExecutableLocator.locate("jamf-cli") else {
            return .status(nil)
        }
        // Subcommand: jamf-cli -p <profile> pro auth token --output json --no-input
        // Available since jamf-cli v1.9; older versions exit non-zero with "unknown command".
        let args = CLICommand.proAuthToken(profile: profile).argv
        let exitCode: Int32
        let data: Data
        // A keychain error may be printed on stderr, which `runAndCapture` keeps out of `data`.
        let stderrWatcher = StderrSignalWatcher()
        do {
            (exitCode, data) = try await runAndCapture(
                executable: bin,
                arguments: args,
                environment: Self.environmentForJamfCLI(),
                timeout: timeout,
                onLine: stderrWatcher.forwarding(to: { _ in })
            )
        } catch {
            // tokenStatus is the auth prober — codesign rejection or launch failure
            // here means we cannot confirm auth; treat as invalid/expired token.
            AppLogger.auth.warning(
                "tokenStatus: runAndCapture threw for \(profile, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
            return .status(TokenStatus.make(profile: profile, token: nil, expiresAt: nil))
        }
        if exitCode == Self.exitCodeTimedOut { return .timedOut }
        guard exitCode == 0, !data.isEmpty else {
            let cause = FailureCause.classify(
                exitCode: exitCode, stdout: data,
                sawKeychainLockedOnStderr: stderrWatcher.sawKeychainLocked)
            if cause.kind == .keychainLocked { return .keychainLocked }
            return .status(TokenStatus.make(profile: profile, token: nil, expiresAt: nil))
        }
        return .status(parseTokenStatus(profile: profile, data: data))
    }

    nonisolated func parseTokenStatus(profile: String, data: Data) -> TokenStatus {
        // Defensive decode struct — every field optional so malformed JSON never throws.
        struct TokenPayload: Decodable {
            let token: String?
            let expires_at: String?   // ISO8601, e.g. "2026-05-04T13:38:38Z"; omitted for token-file auth
        }
        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(TokenPayload.self, from: data) else {
            return TokenStatus.make(profile: profile, token: nil, expiresAt: nil)
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
            expiresAt: expiresAt
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
        if await Self.refusesProCommand(profile: profile, operation: "Device lookup", onLine: onLine) != nil {
            return nil
        }
        guard await authGuard(profile: profile, onLine: { line in
            AppLogger.auth.warning("deviceDetail auth: \(line.text, privacy: .private)")
        }) else { return nil }
        return await singleDeviceDetail(
            profile: profile,
            deviceID: deviceID,
            cacheSubdir: "devices",
            jamfCLIArgs: Self.computerDetailArguments,
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
        if await Self.refusesProCommand(profile: profile, operation: "Mobile device lookup", onLine: onLine) != nil {
            return nil
        }
        guard await authGuard(profile: profile, onLine: { line in
            AppLogger.auth.warning("mobileDeviceDetail auth: \(line.text, privacy: .private)")
        }) else { return nil }
        return await singleDeviceDetail(
            profile: profile,
            deviceID: deviceID,
            cacheSubdir: "mobile-devices",
            jamfCLIArgs: Self.mobileDetailArguments,
            onLine: onLine
        )
    }

    /// Shared backbone for single-device fetches. The two device kinds differ
    /// only in jamf-cli subcommand and cache directory — everything else
    /// (profile validation, atomic move, fall-back to last-known-good cache)
    /// is identical and must stay in lock-step. Returns a `DeviceDetailResult`
    /// so callers can render a staleness banner when the live API call fails
    /// and we silently returned the previous snapshot.
    /// B-03: a device identifier is fleet data — a device's own name or serial
    /// out of the inventory snapshot — not operator input, and it lands in a
    /// bare positional argv slot. A leading dash is parsed by jamf-cli's flag
    /// layer as a global flag rather than an identifier, so it is refused here
    /// exactly as `audit --checks` and `backup --label` already refuse one.
    nonisolated static func isSafeDeviceIdentifier(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("-")
    }

    nonisolated static func computerDetailArguments(_ id: String) -> [String] {
        ["pro", "device", id]
    }

    nonisolated static func mobileDetailArguments(_ id: String) -> [String] {
        ["pro", "mobile-devices", "get", id]
    }

    /// `locateJamfCLI` is a test seam: the default locator finds no jamf-cli under XCTest.
    /// Callers run `refusesProCommand` first, before `authGuard` probes the profile.
    nonisolated func singleDeviceDetail(
        profile: String,
        deviceID: String,
        cacheSubdir: String,
        jamfCLIArgs: @Sendable (String) -> [String],
        locateJamfCLI: @Sendable () -> URL? = { ExecutableLocator.locate("jamf-cli") },
        timeout: TimeInterval = deviceDetailTimeout,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)? = nil
    ) async -> DeviceDetailResult? {
        let trimmedID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeDeviceIdentifier(trimmedID) else {
            AppLogger.cli.warning("device detail: rejecting leading-dash identifier")
            return nil
        }
        guard ProfileService.isValid(profile),
              ProfileService.workspaceURL(for: profile) != nil else {
            return nil
        }

        // Nil when the cache folder is refused: the lookup then runs live and caches nothing.
        let devicesDir = Self.deviceCacheFolder(
            profile: profile, cacheSubdir: cacheSubdir, onLine: onLine)
        let cache = devicesDir?.appendingPathComponent(deviceCacheFilename(trimmedID))
        if let bin = locateJamfCLI() {
            // Staged in the per-user temp directory, not beside the cache: a predictable name
            // in a shared workspace can be a symlink someone planted, and jamf-cli would write
            // through it.
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("jrc-device-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: staging) }
            let baseArgs = ["-p", profile] + jamfCLIArgs(trimmedID)
            let exit = await runDeviceDetailProcess(
                executable: bin,
                arguments: baseArgs + [
                    "--output", "json", "--no-input", "--out-file", staging.path,
                ],
                outputDirectory: devicesDir ?? FileManager.default.temporaryDirectory,
                stdoutFallbackFile: staging,
                timeout: timeout,
                onLine: onLine
            )
            if exit == 0 {
                do {
                    let data = try Data(contentsOf: staging)
                    if !data.isEmpty, let cache {
                        // Remove both the stale cache and its freshness sidecar so a
                        // forged-old-timestamp sidecar can't survive a live refresh.
                        try? FileManager.default.removeItem(at: cache)
                        try? FileManager.default.removeItem(
                            at: cache.appendingPathExtension("meta")
                        )
                        // Atomic, so it replaces whatever sits at `cache` instead of following it.
                        let cached = Self.writeDeviceDetailCache(data, to: cache)
                        if cached { CLIBridge.writeDeviceDetailFreshnessSidecar(for: cache) }
                        return DeviceDetailResult(
                            data: data, fromCache: false, cacheURL: cached ? cache : nil
                        )
                    } else if !data.isEmpty {
                        return DeviceDetailResult(data: data, fromCache: false, cacheURL: nil)
                    }
                } catch {
                    let reason = error.localizedDescription
                    AppLogger.cli.warning(
                        "deviceDetail: could not read staged output: \(reason, privacy: .private)"
                    )
                }
            }
        }
        let fallback = [cache, Self.legacyDeviceCache(
            profile: profile, cacheSubdir: cacheSubdir, file: deviceCacheFilename(trimmedID),
            current: devicesDir)]
        for url in fallback.compactMap({ $0 }) {
            if let data = try? BoundedFile.read(
                url, limit: BoundedFile.deviceDetailLimit, followSymlinks: false) {
                return DeviceDetailResult(data: data, fromCache: true, cacheURL: url)
            }
        }
        return nil
    }

    /// The kind folder under the profile's data folder (`jamf_cli.data_dir`). A link there would
    /// send cached device JSON wherever a peer pointed it, so it is refused with one warning.
    nonisolated private static func deviceCacheFolder(
        profile: String, cacheSubdir: String,
        onLine: (@Sendable (CLIBridge.LogLine) -> Void)?
    ) -> URL? {
        do {
            return try WorkspacePaths.confinedFolder(
                [cacheSubdir], under: try WorkspacePaths.dataDir(for: profile))
        } catch {
            let msg = "[warn] device detail: the \(cacheSubdir) cache folder is not used, so "
                + "this lookup is not cached: \(WorkspacePaths.refusal(of: error))."
            AppLogger.cli.warning("\(msg, privacy: .private)")
            onLine?(.init(timestamp: Date(), level: .warn, text: msg))
            return nil
        }
    }

    /// A copy cached under the fixed `jamf-cli-data/<kind>` folder before the cache followed
    /// `jamf_cli.data_dir`. Read only, never written, and only through a confined folder.
    nonisolated private static func legacyDeviceCache(
        profile: String, cacheSubdir: String, file: String, current: URL?
    ) -> URL? {
        guard let workspace = ProfileService.workspaceURL(for: profile),
              let folder = try? WorkspacePaths.confinedFolder(
                  ["jamf-cli-data", cacheSubdir], under: workspace),
              folder.standardizedFileURL != current?.standardizedFileURL else { return nil }
        return folder.appendingPathComponent(file)
    }

    /// Writes `data` to `cache` through a temp file and rename, then restricts it to the owner.
    /// False (and a warning) when the write failed; the caller still has the live data.
    nonisolated private static func writeDeviceDetailCache(_ data: Data, to cache: URL) -> Bool {
        do {
            try data.write(to: cache, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: cache.path)
            return true
        } catch {
            let reason = error.localizedDescription
            AppLogger.cli.warning(
                "deviceDetail: cache write failed: \(reason, privacy: .private)"
            )
            return false
        }
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
    ) async throws -> (exitCode: Int32, payload: Data) {
        guard ProfileService.isValid(profile) else {
            onLine(Self.invalidProfileLine(profile))
            throw CLIBridgeError.invalidProfile(profile)
        }
        if let refusal = await Self.refusesProCommand(
            profile: profile, operation: "Backup diff", onLine: onLine
        ) {
            throw CLIBridgeError.wrongProduct(refusal)
        }
        // A backup whose Jamf Pro part failed or was skipped holds only Protect objects, which
        // `pro diff` cannot read.
        for backup in [left, right]
        where BackupProductResult.pro(inBackup: backup)?.leavesNoJamfProBackup == true {
            let error = CLIBridgeError.backupWithoutPro(backup.lastPathComponent)
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] \(error.localizedDescription)"))
            throw error
        }
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jamf-cli not found"))
            throw CLIBridgeError.executableNotFound
        }
        // `--output json` (not `plain`): the plain renderer flattens each change
        // into its whole field value, which is what made the diff sheet a wall of
        // JSON — 246KB to express ten changes on a real pair of backups. The
        // structured form is what `BackupDiffModel` collapses. jamf-cli writes
        // the payload to stdout and only progress ("Loading source: …") to
        // stderr, so `runAndCapture` streams the progress through `onLine` and
        // hands back the payload.
        let (exitCode, data) = try await runAndCapture(
            executable: bin,
            arguments: Self.diffArguments(profile: profile, source: left.path, target: right.path),
            environment: Self.environmentForJamfCLI(),
            onLine: onLine
        )
        return (exitCode, data)
    }

    func generateHTML(
        profile: String,
        outFile: String?,
        template: any ReportTemplate = FullInstanceTemplate(),
        aiNarrative: String? = nil,
        written: RunArtifacts? = nil,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        // HTML generation reads only cached jamf-cli JSON snapshots; no live API calls are made.
        // authGuard is intentionally omitted — stale/expired credentials do not prevent rendering.
        try await ensureWorkspace(profile: profile, onLine: onLine)
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            let msg = "error: workspace URL unexpectedly nil for profile '\(profile)' after ensureWorkspace — this is a programmer error"
            onLine(LogLine(timestamp: Date(), level: .fail, text: msg))
            AppLogger.cli.error("\(msg)")
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let configURL = workspace.appendingPathComponent("config.yaml")
        let config = try loadConfig(at: configURL, onLine: onLine)
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
            outputURL = try engine.resolveOutputURL(stem: "report", profile: profile, onLine: onLine)
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
                profile: profile,
                template: template,
                aiNarrative: aiNarrative,
                onLine: onLine
            )
            onLine(.init(timestamp: Date(), level: .ok,
                         text: "[ok] HTML report written: \(outputURL.lastPathComponent)"))
            written?.add([outputURL], config: config)
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
        template: any ReportTemplate = FullInstanceTemplate(),
        written: RunArtifacts? = nil,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        // PDF generation reads only cached jamf-cli JSON snapshots; no live API calls.
        try await ensureWorkspace(profile: profile, onLine: onLine)
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            let msg = "error: workspace URL unexpectedly nil for profile '\(profile)' after ensureWorkspace — this is a programmer error"
            onLine(LogLine(timestamp: Date(), level: .fail, text: msg))
            AppLogger.cli.error("\(msg)")
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let configURL = workspace.appendingPathComponent("config.yaml")
        let config = try loadConfig(at: configURL, onLine: onLine)
        guard let dataDir = try? WorkspacePaths.dataDir(for: profile) else {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] could not resolve data_dir for \(profile)"))
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let outputURL = URL(fileURLWithPath: outFile)
        // Epic #103: refuse sensitive destinations before creating directories —
        // a future non-UI caller (scheduled run, agent) could otherwise create
        // arbitrary directory trees. Deny-list rather than a workspace
        // allow-list on purpose: the sole UI caller is an NSSavePanel, and a
        // strict allow-list would silently re-break user-chosen export
        // destinations (the B-04 regression PR #161 removed).
        guard !WorkspacePaths.isSensitiveAbsolutePath(outputURL) else {
            onLine(.init(timestamp: Date(), level: .fail,
                text: "[error] refusing to write PDF into a sensitive path: \(outputURL.path)"))
            throw CLIBridgeError.directoryOperationFailed(path: outputURL.path)
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
                template: template,
                onLine: onLine
            )
            onLine(.init(timestamp: Date(), level: .ok,
                         text: "[ok] PDF report written: \(outputURL.lastPathComponent)"))
            written?.add([outputURL], config: config)
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
        written: RunArtifacts? = nil,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        // Epic #103 parity with generatePDF: the engine createDirectory()s at
        // this path, so refuse sensitive destinations before doing anything.
        if let path = outFile {
            let candidate = URL(fileURLWithPath: path)
            guard !WorkspacePaths.isSensitiveAbsolutePath(candidate) else {
                onLine(.init(timestamp: Date(), level: .fail,
                    text: "[error] refusing to write CSV into a sensitive path: \(candidate.path)"))
                throw CLIBridgeError.directoryOperationFailed(path: candidate.path)
            }
        }
        // No authGuard: this reads cached snapshots only, so a 401 must not block it.
        try await ensureWorkspace(profile: profile, onLine: onLine)
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            let msg = "error: workspace URL unexpectedly nil for profile '\(profile)' after ensureWorkspace — this is a programmer error"
            onLine(LogLine(timestamp: Date(), level: .fail, text: msg))
            AppLogger.cli.error("\(msg)")
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        let configURL = workspace.appendingPathComponent("config.yaml")
        let config = try loadConfig(at: configURL, onLine: onLine)
        let outputURL: URL
        if let path = outFile {
            outputURL = URL(fileURLWithPath: path)
        } else {
            let engine = ReportEngine(config: config, dataDir: workspace)
            outputURL = try engine.resolveOutputURL(
                stem: ExportNaming.reportKind(for: .csv, schoolMode: false), profile: profile,
                onLine: onLine)
                .deletingPathExtension().appendingPathExtension("csv")
        }
        do {
            try await ReportEngine.inventoryCSV(
                profile: profile,
                workspacePaths: WorkspacePaths.self,
                outputURL: outputURL
            )
            // No sidecar for a CSV; the hash line is what lists it as a file the run wrote, and
            // a Generate run's manifest lists it.
            if let line = ReportEngine.sha256LogLine(for: outputURL) { onLine(line) }
            onLine(.init(timestamp: Date(), level: .ok,
                         text: "[ok] inventory CSV written: \(outputURL.lastPathComponent)"))
            written?.add([outputURL], config: config)
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

    /// `thresholds.stale_device_days` for the audit's `--days`: 30, the app's default, when the
    /// workspace has no config.yaml or it does not parse (logged; the audit still runs).
    nonisolated static func auditStaleDays(profile: String) -> Int {
        guard let workspace = ProfileService.workspaceURL(for: profile) else { return 30 }
        let url = workspace.appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: url.path) else { return 30 }
        do {
            return try ConfigLoader.load(from: url).thresholds?.resolvedStaleDays ?? 30
        } catch {
            let reason = error.localizedDescription
            AppLogger.cli.warning(
                """
                audit: config.yaml unreadable (\(reason, privacy: .private)); \
                using the default 30-day stale threshold
                """
            )
            return 30
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
            onLine(Self.invalidProfileLine(profile))
            throw CLIBridgeError.invalidProfile(profile)
        }
        // B-03: refuse leading-dash category. Checked before auth so that the
        // rejection is deterministic and does not depend on auth state.
        if let category, category.hasPrefix("-") {
            AppLogger.cli.warning("audit: rejecting leading-dash category")
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] audit category may not start with '-'"))
            throw CLIBridgeError.invalidArgument("audit category may not start with '-'")
        }
        if let refusal = await Self.refusesProCommand(
            profile: profile, operation: "Health audit", onLine: onLine
        ) {
            throw CLIBridgeError.wrongProduct(refusal)
        }
        guard await authGuard(profile: profile, onLine: onLine) else {
            return Self.exitCodeUnauthorized
        }
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jamf-cli not found"))
            throw CLIBridgeError.executableNotFound
        }
        let args = ReportEngine.auditArguments(
            profile: profile, staleDays: Self.auditStaleDays(profile: profile),
            category: category)

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
            onLine(Self.invalidProfileLine(profile))
            throw CLIBridgeError.invalidProfile(profile)
        }
        if let refusal = await Self.refusesProCommand(
            profile: profile, operation: "Group analysis", onLine: onLine
        ) {
            throw CLIBridgeError.wrongProduct(refusal)
        }
        guard await authGuard(profile: profile, onLine: onLine) else {
            return Self.exitCodeUnauthorized
        }
        guard let bin = ExecutableLocator.locate("jamf-cli") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jamf-cli not found"))
            throw CLIBridgeError.executableNotFound
        }
        let args = Self.groupAnalyzeArguments(profile: profile)
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

    /// `<type>_<yyyyMMdd'T'HHmmss>.json` in local time: the stamp `ReportEngine.saveSnapshot`
    /// writes and `CloudStorage.snapshotTimestamp` reads. A UTC stamp read as local put an
    /// audit hours in the future, ahead of newer snapshots.
    nonisolated static func snapshotFileName(type: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "\(type)_\(formatter.string(from: date)).json"
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
        do {
            // A type folder that is a symlink would send the snapshot wherever a peer pointed it.
            let dir = try WorkspacePaths.confinedFolder([type], under: dataDir)
            let file = dir.appendingPathComponent(Self.snapshotFileName(type: type, at: Date()))
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

    /// `timeout` ends a stalled `pro backup` and `protectTimeout` a stalled `protect backup`,
    /// each on its own clock; `_testExecutable` is a test seam. When the workspace has Protect
    /// connected the backup also holds `protect/` (see `ProtectBackup`).
    func backup(
        profile: String,
        label: String?,
        timeout: TimeInterval = CLIBridge.backupTimeout,
        protectTimeout: TimeInterval = ProtectBackup.timeout,
        _testExecutable: URL? = nil,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        try await backupRun(
            profile: profile, label: label, timeout: timeout, protectTimeout: protectTimeout,
            _testExecutable: _testExecutable, onLine: onLine).exit
    }

    /// What one backup run left: jamf-cli's exit and the folder it finished, nil when it wrote
    /// none (a failure with nothing to keep, or Jamf Pro skipped with no Jamf Protect objects).
    struct BackupRun: Sendable {
        let exit: Int32
        let folder: URL?
    }

    /// `backup`, with the folder it finished, for a caller that stamps and prunes it.
    func backupRun(
        profile: String,
        label: String?,
        timeout: TimeInterval = CLIBridge.backupTimeout,
        protectTimeout: TimeInterval = ProtectBackup.timeout,
        _testExecutable: URL? = nil,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> BackupRun {
        try await AttentionLog.recording(profile: profile) {
            try await backupRecording(
                profile: profile, label: label, timeout: timeout,
                protectTimeout: protectTimeout, _testExecutable: _testExecutable, onLine: onLine)
        }
    }

    private func backupRecording(
        profile: String,
        label: String?,
        timeout: TimeInterval,
        protectTimeout: TimeInterval,
        _testExecutable: URL?,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> BackupRun {
        guard ProfileService.isValid(profile) else {
            onLine(Self.invalidProfileLine(profile))
            throw CLIBridgeError.invalidProfile(profile)
        }
        // B-03: refuse leading-dash labels — would be re-interpreted as a flag by jamf-cli.
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedLabel, trimmedLabel.hasPrefix("-") {
            AppLogger.cli.warning("backup: rejecting leading-dash label")
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] backup label may not start with '-'"))
            throw CLIBridgeError.invalidArgument("backup label may not start with '-'")
        }
        if let refusal = await Self.refusesProCommand(
            profile: profile, operation: "Backup", onLine: onLine
        ) {
            throw CLIBridgeError.wrongProduct(refusal)
        }
        guard let bin = _testExecutable ?? ExecutableLocator.locate("jamf-cli") else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] jamf-cli not found"))
            throw CLIBridgeError.executableNotFound
        }
        // The guard root here is deliberately the UNRESOLVED workspace URL, unlike
        // every other WorkspacePathGuard caller, which passes the resolved
        // `WorkspacePathGuard.root(for:)`. The difference is that those callers
        // validate paths that already exist, while backup validates two paths it is
        // about to create.
        //
        // `resolvingSymlinksInPath()` only follows symlinks for a path that fully
        // exists; for a not-yet-created path it returns the path with symlinks
        // intact (verified empirically). So for the staging and final directories
        // the candidate stays unresolved, and comparing it against a RESOLVED root
        // fails on any workspace behind a symlink — iCloud/OneDrive/SharePoint, an
        // external volume, a symlinked home. Both sides must be unresolved here.
        // Do not "fix" this to `WorkspacePathGuard.root(for:)`; that inverts it and
        // breaks backup on exactly those workspaces. Pinned by
        // CLIBridgeBackupTests.test_pathGuardAcceptsNotYetCreatedPathUnderSymlinkedWorkspace.
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            onLine(.init(timestamp: Date(), level: .fail, text: "[error] no workspace for profile '\(profile)'"))
            throw CLIBridgeError.workspaceMissing(profile: profile)
        }
        // `-p` is the workspace's own profile, as for collect, generate and audit. A shared
        // (synced) workspace's config.yaml can be edited from another Mac, so honouring
        // `jamf_cli.profile` here would export a different tenant's config objects into
        // this folder from an unattended job. Checked before anything is created, so a
        // refusal leaves no staging directory behind.
        try Self.checkBackupConfigProfile(profile, onLine: onLine)
        let backupsRoot = workspace.appendingPathComponent("backups", isDirectory: true)
        // Checked from the resolved root; the unresolved paths below stay as they are (see above).
        guard WorkspacePaths.confinedFolderOrWarn(["backups"], under: workspace, onLine: onLine)
                != nil else {
            throw CLIBridgeError.directoryOperationFailed(path: backupsRoot.path)
        }
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

        // On storage other Macs reach, the operator decides whether Jamf Pro is backed up here.
        let proSkip = decideProBackup(
            profile: profile, workspace: workspace, backupsRoot: backupsRoot,
            isScheduled: trimmedLabel?.hasPrefix("scheduled-") == true, onLine: onLine)
        let proSkipped = proSkip != nil
        let exit: Int32
        if proSkip == nil {
            exit = try await run(
                executable: bin,
                arguments: Self.backupArguments(
                    profile: profile, outputDirectory: validatedTemp.path),
                environment: Self.environmentForJamfCLI(),
                timeout: timeout,
                onLine: onLine
            )
            if exit == Self.exitCodeTimedOut {
                onLine(.init(timestamp: Date(), level: .fail,
                             text: "[error] backup stopped after the "
                                 + "\(Int(timeout.rounded(.up))) s limit; the unfinished backup "
                                 + "was discarded"))
            }
        } else {
            exit = 0
        }

        // Exit 7 is jamf-cli's documented partial failure: some config-object types
        // failed (e.g. one type 403s under a reporting-scoped API role) but valid
        // data was returned for the rest. Keeping that staging dir is the whole
        // point of the code — deleting it here would destroy the partial export.
        let isPartial = exit == Self.exitCodePartialFailure
        let proFailed = !proSkipped && exit != 0 && !isPartial
        if proFailed {
            // Every other failure branch names its cause; this one used to return a
            // bare exit code with no log line at all.
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] " + Self.explainExit(exit, operation: "Backup")))
            // The unfinished Jamf Pro files are never kept; an empty staging folder lets
            // Protect still back up below. Not intermediate, so a name planted after the
            // removal fails the create and goes to the discard below.
            let cleared = (try? fm.removeItem(at: validatedTemp)) != nil
                && (try? fm.createDirectory(at: validatedTemp, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])) != nil
            guard cleared else {
                discardStaging(validatedTemp, onLine: onLine)
                tightenOnSuccess(exit, profile: profile)
                return BackupRun(exit: exit, folder: nil)
            }
        }

        if isPartial {
            onLine(.init(timestamp: Date(), level: .warn,
                text: "[warn] backup is PARTIAL — jamf-cli reported exit 7: some configuration "
                    + "object types failed and are missing from this backup. The data that was "
                    + "returned has been kept. Check the lines above for the failing types before "
                    + "relying on this as a restore point."))
        }

        // Protect joins the same staging folder, so one backup holds both products. Its
        // failure never costs the Jamf Pro backup above.
        let protectResult = await backupProtect(
            profile: profile, workspace: workspace, staging: validatedTemp, executable: bin,
            timeout: protectTimeout,
            proState: proSkipped ? .skipped : proFailed ? .failed : (isPartial ? .partial : .ok),
            sharedStorage: {
                BackupMaintenance.sharedStorageDescription(
                    backupsRoot, profile: profile, volumeIsLocal: CloudStorage.isOnLocalVolume,
                    pinnedIsShared: true)
            },
            onLine: onLine)
        // With Jamf Pro failed, the folder is kept only for Protect objects to restore from.
        if proFailed, (protectResult?.objectTotal ?? 0) == 0 {
            discardStaging(validatedTemp, protect: protectResult, onLine: onLine)
            tightenOnSuccess(exit, profile: profile)
            return BackupRun(exit: exit, folder: nil)
        }
        // A skipped Jamf Pro part with no Jamf Protect objects leaves nothing to restore from,
        // so no folder is written; the skip line, the Partial line and the attention item above
        // already say so. Not a failure.
        if proSkipped, (protectResult?.objectTotal ?? 0) == 0 {
            discardStaging(validatedTemp, protect: protectResult, onLine: onLine)
            onLine(.init(
                timestamp: Date(), level: proSkip?.isPartial == true ? .warn : .info,
                text: (proSkip?.isPartial == true ? "[warn]" : "[info]")
                    + " no backup written: Jamf Pro was skipped and Jamf Protect left nothing "
                    + "to keep"))
            tightenOnSuccess(exit, profile: profile)
            return BackupRun(exit: exit, folder: nil)
        }

        // Rename temp dir to a timestamped final name.
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .prefix(15)
        let finalName = Self.uniqueBackupDirectoryName(base: String(ts), in: backupsRoot, fileManager: fm)
        let finalDir = backupsRoot.appendingPathComponent(finalName, isDirectory: true)
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
        var manifest: [String: Any] = [
            "label": effectiveLabel,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "file_count": stats.fileCount,
            "size_bytes": stats.sizeBytes,
        ]
        // Only a workspace with Protect connected, or a skipped Jamf Pro part, records
        // per-product results; any other manifest is as it always was, and older ones read the
        // same.
        if protectResult != nil || proSkipped {
            var products: [String: Any] = [
                "pro": proSkip.map {
                    BackupProductResult(state: .skipped, reason: $0.reason).manifestValue
                } ?? ["exit_code": Int(exit),
                      "state": proFailed ? "failed" : isPartial ? "partial" : "ok"],
            ]
            products["protect"] = protectResult?.manifestValue
            manifest["products"] = products
        }
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

        if proFailed {
            // Post-success housekeeping, which stamps a backup, does not run after a failure,
            // and an unstamped backup on shared storage would never be pruned.
            BackupMaintenance.stampOwnership(of: validatedFinal)
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] Jamf Pro backup failed; kept the Jamf Protect part in "
                             + validatedFinal.lastPathComponent))
            tightenOnSuccess(exit, profile: profile)
            return BackupRun(exit: exit, folder: validatedFinal)
        }
        let protectIncomplete = protectResult?.isIncomplete == true
        onLine(.init(
            timestamp: Date(),
            level: proSkip?.isPartial == true || isPartial || protectIncomplete ? .warn
                : proSkipped ? .info : .ok,
            text: isPartial
                ? "[warn] partial backup written: \(validatedFinal.lastPathComponent)"
                : protectIncomplete
                ? "[warn] backup written without a complete Jamf Protect part: "
                    + validatedFinal.lastPathComponent
                : proSkipped
                ? (proSkip?.isPartial == true ? "[warn]" : "[info]")
                    + " backup written without a Jamf Pro part: "
                    + validatedFinal.lastPathComponent
                : "[ok] backup written: \(validatedFinal.lastPathComponent)"
        ))
        tightenOnSuccess(exit, profile: profile)
        return BackupRun(exit: exit, folder: validatedFinal)
    }

    /// A Jamf Pro part this backup leaves out: `reason` goes in the manifest, `isPartial` is
    /// whether the run reads as Partial.
    struct ProSkip: Sendable {
        let reason: String
        let isPartial: Bool
    }

    /// Decides whether this backup includes Jamf Pro (`ProBackup.plan`), logs what that means
    /// and keeps the Needs-attention item in step. Returns the skip when it is skipped. A skip
    /// is never a failure (no `[error]`); it is Partial only when nobody has decided yet or the
    /// decision waits for a Confirm.
    private func decideProBackup(
        profile: String, workspace: URL, backupsRoot: URL, isScheduled: Bool,
        onLine: @Sendable (LogLine) -> Void
    ) -> ProSkip? {
        let read = ProBackup.readConfig(profile: profile)
        let config = read.config
        let decodeFailure = read.failure
        // A config.yaml that does not decode cannot say the folder is shared; the storage and
        // this Mac's pin can.
        let place = BackupMaintenance.sharedStorageDescription(
            backupsRoot, profile: profile, volumeIsLocal: CloudStorage.isOnLocalVolume,
            unreadableConfigIsShared: false, pinnedIsShared: true)
        let setting: ProBackup.Setting = place == nil || decodeFailure != nil ? .notChosen
            : SharedConfigPin.proBackupSetting(
                config?.backup?.proOnSyncedStorage, profile: profile)
        // Once this Mac has seen a choice, a peer deleting the key cannot restart the grace.
        if place != nil, decodeFailure == nil, setting != .notChosen {
            ProBackupGrace.exhaust(profile: profile)
        }
        let plan = ProBackup.plan(
            setting: setting, place: place, decodeFailure: decodeFailure,
            hasScheduledHistory: { BackupMaintenance.hasScheduledJamfProBackup(profile: profile) },
            graceRunsUsed: { ProBackupGrace.used(profile: profile) })
        func skip(
            _ reason: String, _ kind: ProBackup.SkipKind, place: String, detail: String? = nil
        ) -> ProSkip {
            let full = reason + (detail.map { ": \($0)" } ?? "")
            onLine(.init(timestamp: Date(), level: .warn, text: ProBackup.skipLine(reason: full)))
            if kind.makesRunPartial {
                onLine(.init(timestamp: Date(), level: .warn, text: ProBackup.partialLine))
            }
            if kind == .asking {
                AttentionLog.raise(
                    .proBackupChoiceNeeded,
                    ProBackup.choiceNeededMessage(place: place, runsLeft: nil))
            } else {
                AttentionLog.clear(.proBackupChoiceNeeded)
            }
            return ProSkip(reason: reason, isPartial: kind.makesRunPartial)
        }
        switch plan {
        case .run:
            AttentionLog.clear(.proBackupChoiceNeeded)
            return nil
        case .runOnSyncedStorage(let place):
            AttentionLog.clear(.proBackupChoiceNeeded)
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[info] backing up Jamf Pro to synced storage: this workspace is "
                             + "\(place), and "
                             + "\(SharedConfigPin.Key.proBackupOnSyncedStorage.rawValue) allows "
                             + "it on this Mac"))
            return nil
        case .skip(let reason, let kind):
            return skip(reason, kind, place: place ?? "on synced storage", detail: decodeFailure)
        case .runWhileAsking(let place, let runsLeft):
            // Only a scheduled run uses up the grace; a manual backup during it is free.
            var left = runsLeft
            if isScheduled {
                do {
                    try ProBackupGrace.record(profile: profile)
                    left -= 1
                } catch {
                    // Not counting would keep Jamf Pro on shared storage for good. The manifest
                    // gets a fixed reason; the error text stays in the log line.
                    return skip(
                        "the count of scheduled backups that run before this choice is needed "
                            + "could not be saved on this Mac",
                        .asking, place: place,
                        detail: LogRedactor.redact(error.localizedDescription))
                }
            }
            let message = ProBackup.choiceNeededMessage(place: place, runsLeft: left)
            onLine(.init(timestamp: Date(), level: .warn, text: "[warn] \(message)"))
            AttentionLog.raise(.proBackupChoiceNeeded, message)
            return nil
        }
    }

    /// Removes a staging folder the run keeps nothing from. The Protect part's failure list
    /// (`protect/_failures.yaml`), which its `[warn]` line points the operator to, goes with it,
    /// so say so.
    private func discardStaging(
        _ staging: URL, protect: BackupProductResult?, onLine: @Sendable (LogLine) -> Void
    ) {
        discardStaging(staging, onLine: onLine)
        guard protect?.hasFailuresFile == true else { return }
        onLine(.init(timestamp: Date(), level: .warn,
                     text: "[warn] the Jamf Protect failure list "
                         + "(\(ProtectBackup.folderName)/\(ProtectBackup.failuresFileName)) was "
                         + "discarded with the staging folder, since this backup keeps nothing"))
    }

    private func discardStaging(_ staging: URL, onLine: @Sendable (LogLine) -> Void) {
        guard (try? FileManager.default.removeItem(at: staging)) == nil else { return }
        AppLogger.cli.warning(
            "backup: failed to remove temp dir after CLI error: \(staging.path, privacy: .private)"
        )
        onLine(.init(timestamp: Date(), level: .warn,
            text: "[warn] backup temp dir could not be removed — delete manually: \(staging.lastPathComponent)"))
    }

    nonisolated static func diffArguments(profile: String, source: String, target: String) -> [String] {
        ["-p", profile, "pro", "diff", "--source", source, "--target", target,
         "--output", "json", "--no-input"]
    }

    nonisolated static func groupAnalyzeArguments(profile: String) -> [String] {
        ["-p", profile, "pro", "group-tools", "analyze", "--unused", "--output", "json",
         "--no-input"]
    }

    nonisolated static func configValidateArguments(profile: String) -> [String] {
        ["-p", profile, "config", "validate", "--output", "json"]
    }

    /// The jamf-cli arguments for a backup of `profile` into `outputDirectory`.
    nonisolated static func backupArguments(profile: String, outputDirectory: String) -> [String] {
        ["-p", profile, "--no-input", "pro", "backup",
         "--format", "json", "--output", outputDirectory]
    }

    /// Compares the workspace's MDM profile (`EnvironmentProfiles.mdm`: `jamf_cli.profile` in an
    /// old-shape config.yaml) with `profile` before a backup. A case variant is refused like
    /// `CollectRouter.run` refuses it: the two share the folder on a case-insensitive volume. A
    /// `profiles:` block that cannot run was already refused by `refusesProCommand`, so any
    /// other name here is an old-key one, ignored with one warning, because the backup always
    /// runs as `profile`. A missing or undecodable config has nothing to compare.
    nonisolated static func checkBackupConfigProfile(
        _ profile: String,
        onLine: @Sendable (LogLine) -> Void
    ) throws {
        guard let workspace = ProfileService.workspaceURL(for: profile),
              let config = try? ConfigLoader.load(
                  from: workspace.appendingPathComponent("config.yaml")
              ) else { return }
        let environment = EnvironmentProfiles.resolve(config: config, workspace: profile)
        let owner = environment.mdm ?? profile
        if ProfileService.isCaseVariant(owner, of: profile) {
            let conflict = CLIBridgeError.profileCaseConflict(profile: profile, owner: owner)
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] \(conflict.localizedDescription)"))
            throw conflict
        }
        guard owner != profile else { return }
        onLine(.init(
            timestamp: Date(), level: .warn,
            text: "[warn] backup: config.yaml sets jamf_cli.profile to "
                + "\(ConfigSchema.displayText(owner)); ignored, backing up this workspace's "
                + "profile \(ConfigSchema.displayText(profile))"
        ))
    }

    /// Backup directory name for `base`, appending `-2`, `-3`, … when a directory
    /// with that name already exists.
    ///
    /// The name is a 1-second-resolution timestamp, so two backups finishing in the
    /// same second collide: `moveItem` throws EEXIST, the catch deletes the
    /// just-completed staging dir, and a good backup is lost while the user sees a
    /// failure. Non-colliding names are returned verbatim — `BackupsView` and
    /// `BackupMaintenance` read these directories, so the format must not shift for
    /// the normal case.
    nonisolated static func uniqueBackupDirectoryName(
        base: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> String {
        var candidate = base
        var suffix = 2
        while fileManager.fileExists(
            atPath: directory.appendingPathComponent(candidate, isDirectory: true).path
        ) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
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

    func initializeWorkspace(
        profile: String,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws -> Int32 {
        try await ensureWorkspace(profile: profile, onLine: onLine)
        return 0
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
            onLine(Self.invalidProfileLine(profile))
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

    /// The one environment every jamf-cli child gets; `parent` is the test seam. Add a variable
    /// jamf-cli must see to `jamfCLIAllowedEnvKeys` (verbatim) or here (when it needs a check).
    /// `proxy` and `noProxy` are the system proxy a background run installed (`SystemProxy`); a
    /// variable already in the parent environment (a shell, the GUI) wins over them.
    nonisolated static func environmentForJamfCLI(
        parent: [String: String] = ProcessInfo.processInfo.environment,
        proxy: String? = SystemProxy.scheduledRun.url,
        noProxy: String? = SystemProxy.scheduledRun.noProxy
    ) -> [String: String] {
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
        // jamf-cli keeps its profiles under $XDG_CONFIG_HOME when it is set; the app reads the
        // same folder (`ProfileService.jamfCLIConfigFileURL`), so a relative value is dropped.
        if let xdg = ProfileService.absoluteXDGConfigHome(in: parent) {
            env["XDG_CONFIG_HOME"] = xdg
        }
        if let proxy, env["HTTPS_PROXY"] == nil, env["https_proxy"] == nil {
            env["HTTPS_PROXY"] = proxy
            if let noProxy, env["NO_PROXY"] == nil, env["no_proxy"] == nil {
                env["NO_PROXY"] = noProxy
            }
        }
        // v1.26.0's daily update notifier can stall PTY-driven onboarding on a
        // restricted network; older binaries ignore this var, so no version gate.
        env["JAMF_CLI_NO_UPDATE_CHECK"] = "1"
        return env
    }

    /// Creates `profile`'s workspace on first use and records the profile in its
    /// config. Throws the reason the workspace can't be used, so callers need not
    /// guess one: a bare "not found" once hid a rejected profile name.
    private func ensureWorkspace(
        profile: String,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) async throws {
        guard let workspace = ProfileService.workspaceURL(for: profile) else {
            onLine(Self.invalidProfileLine(profile))
            throw CLIBridgeError.invalidProfile(profile)
        }
        let config = workspace.appendingPathComponent("config.yaml")
        if !FileManager.default.fileExists(atPath: config.path) {
            onLine(.init(timestamp: Date(), level: .info,
                         text: "[info] initializing workspace for \(profile)"))
            do {
                try ReportEngine.initializeWorkspace(
                    profile: profile,
                    workspacesRoot: ProfileService.workspacesRoot(),
                    seedConfigURL: Self.bundledSeedConfig(),
                    onLine: onLine
                )
            } catch {
                let reason = error.localizedDescription
                onLine(.init(timestamp: Date(), level: .fail,
                             text: "[error] workspace init failed for \(profile): \(reason)"))
                throw CLIBridgeError.directoryOperationFailed(path: workspace.path)
            }
            guard FileManager.default.fileExists(atPath: config.path) else {
                onLine(.init(timestamp: Date(), level: .fail,
                             text: "[error] workspace init failed for \(profile)"))
                throw CLIBridgeError.directoryOperationFailed(path: workspace.path)
            }
        }
        try reconcileConfigProfile(config: config, profile: profile, onLine: onLine)
    }

    /// Refuses a workspace recorded for a case variant of `profile`: the two
    /// share the folder on a case-insensitive volume, and rebinding it would
    /// collect a second tenant into the first one's data. Records `profile` in
    /// `jamf_cli.profile` through `ConfigService.saveBlock`, which copies the file first when
    /// the write drops a comment, an unread line or a retired key, and logs what it did.
    private func reconcileConfigProfile(
        config: URL,
        profile: String,
        onLine: @Sendable @escaping (LogLine) -> Void
    ) throws {
        do {
            let document = try YAMLCodec.decode(ConfigLoader.readText(at: config))
            guard case .mapping(let root) = document.root else { return }
            let current = root.value(for: "jamf_cli")?.mapping?.value(for: "profile")?
                .stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard current != profile else { return }
            guard !ProfileService.isCaseVariant(current, of: profile) else {
                throw CLIBridgeError.profileCaseConflict(profile: profile, owner: current)
            }

            let report = try ConfigService.saveBlock(
                key: "jamf_cli", profile: profile,
                workspaceRoot: config.deletingLastPathComponent().deletingLastPathComponent()
            ) { ConfigService.setJamfCLIProfile(profile, in: &$0) }.report
            onLine(.init(
                timestamp: Date(),
                level: .info,
                text: "[info] set jamf_cli.profile to \(profile) in \(config.path)"
            ))
            if let line = report.statusLine {
                onLine(.init(timestamp: Date(), level: .info, text: "[info] \(line)"))
            }
        } catch let conflict as CLIBridgeError {
            onLine(.init(timestamp: Date(), level: .fail,
                         text: "[error] \(conflict.localizedDescription)"))
            throw conflict
        } catch {
            onLine(.init(
                timestamp: Date(),
                level: .fail,
                text: "[error] could not update jamf_cli.profile in \(config.path): \(error.localizedDescription)"
            ))
            // The workspace exists; what failed is reading or writing its config.
            if error is YAMLCodec.CodecError {
                throw CLIBridgeError.configLoadFailed(path: config.path, detail: nil)
            }
            if let refused = error as? ConfigService.ConfigError {
                throw Self.refusedWrite(refused, key: "jamf_cli.profile")
            }
            throw CLIBridgeError.directoryOperationFailed(path: config.path)
        }
    }

    /// The error for a config.yaml write `ConfigService` refused, saying what to change.
    private static func refusedWrite(
        _ error: ConfigService.ConfigError, key: String
    ) -> CLIBridgeError {
        let fix: String
        switch error {
        case .notASettingsBlock(let block):
            fix = "\(block) is typed as a single value; write its settings indented under "
                + "\"\(block):\", or remove that line."
        case .symlinkDestination:
            fix = "the file is a symbolic link; replace it with the file it points to."
        case .credentialKey(let name):
            fix = "it holds a credential-shaped key (\(ConfigSchema.displayText(name))); "
                + "remove it: secrets belong in jamf-cli's keychain, an environment variable "
                + "or a file, never in this config.yaml."
        default:
            fix = "the file could not be updated; check that the workspace's config.yaml is a "
                + "set of top-level settings."
        }
        return .configWriteRefused(key: key, fix: fix)
    }

    nonisolated static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The `config.example.yaml` that seeds a new workspace's config.yaml: the app bundle's
    /// copy. A debug build (`swift run`, no bundle) also reads the working directory and its
    /// parent, the repo checkout; a release build never does, since a file planted where a
    /// `jamf-reports` run starts would become the workspace's config.
    nonisolated static func bundledSeedConfig(
        workingDirectory: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        resourceURL: URL? = Bundle.main.resourceURL,
        searchesWorkingDirectory: Bool = CLIBridge.isDebugBuild
    ) -> URL? {
        let name = "config.example.yaml"
        var candidates: [URL?] = []
        if searchesWorkingDirectory {
            candidates += [
                workingDirectory.appendingPathComponent(name),
                workingDirectory.deletingLastPathComponent().appendingPathComponent(name),
            ]
        }
        candidates.append(resourceURL?.appendingPathComponent(name))
        return candidates.compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// Internal (file-scope dropped) so JamfCLIIdentity-gate tests can
// exercise this path directly — singleDeviceDetail is the only
// production caller.
/// `stdoutFallbackFile`: jamf-cli's `pro device` accepts `--out-file` but its
/// structured-output path builds a local formatter without the out-file writer,
/// so the JSON lands on stdout and the file is never created (upstream bug,
/// observed through 1.26.0). When set, captured stdout is written there after a
/// clean exit if the CLI didn't produce the file itself — so the fetch works on
/// both broken and fixed jamf-cli versions.
func runDeviceDetailProcess(
    executable: URL,
    arguments: [String],
    outputDirectory: URL,
    stdoutFallbackFile: URL? = nil,
    timeout: TimeInterval = deviceDetailTimeout,
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
            // One lookup may wait on several slow API calls; the limit only backstops a wedged
            // jamf-cli, and the caller falls back to the cached copy on any non-zero exit.
            switch JamfCLIProbe.runOutcome(
                executable: executable, arguments: arguments, timeout: timeout
            ) {
            case .launchFailed:
                // -1 as for the cases above: the Int32 signature is a test seam.
                onLine?(deviceLaunchFailureLine())
                return -1
            case .timedOut:
                onLine?(.init(
                    timestamp: Date(), level: .fail,
                    text: "jamf-cli did not answer within \(Int(timeout)) s - stopped"
                ))
                return CLIBridge.exitCodeTimedOut
            case .completed(let output):
                return finishDeviceDetail(
                    output, stdoutFallbackFile: stdoutFallbackFile
                )
            }
        } catch {
            AppLogger.cli.error(
                "runDeviceDetailProcess launch failed: \(error.localizedDescription, privacy: .private)"
            )
            onLine?(deviceLaunchFailureLine())
            // Launch failure: -1 is used for the same reason as above (Int32 signature, fire-and-forget).
            return -1
        }
    }.value
}

/// Seconds `pro device` gets: one lookup resolves the device, then reads its detail and several
/// history subsets in turn, and a single jamf-cli request may itself wait 120 s.
let deviceDetailTimeout: TimeInterval = 180

private func deviceLaunchFailureLine() -> CLIBridge.LogLine {
    CLIBridge.LogLine(
        timestamp: Date(), level: .fail,
        text: "jamf-cli could not be launched — check that jamf-cli is installed and the executable is intact."
    )
}

/// Logs a failed exit and, on a clean one, writes captured stdout to `stdoutFallbackFile` when
/// jamf-cli did not create it (see `runDeviceDetailProcess`). Returns the exit code.
private func finishDeviceDetail(
    _ output: JamfCLIProbe.Output, stdoutFallbackFile: URL?
) -> Int32 {
    let code = output.exitCode
    if code != 0 {
        if let msg = String(data: output.stderr, encoding: .utf8),
           !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            AppLogger.cli.warning("runDeviceDetailProcess exit \(code): \(msg, privacy: .private)")
        }
    }
    if code == 0, let dest = stdoutFallbackFile {
        let cliWroteFile = ((try? Data(contentsOf: dest))?.isEmpty == false)
        if !cliWroteFile && !output.stdout.isEmpty {
            try? output.stdout.write(to: dest, options: .atomic)
        }
    }
    return code
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
