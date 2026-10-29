import Foundation

/// Runs a short jamf-cli query (a version check) to completion with a deadline.
///
/// The probes used to call `waitUntilExit()` with no limit, so a wedged `jamf-cli --version`
/// stalled whatever asked: the headless tick runs one before every collect while it holds the
/// tick lock. The deadline is `CLIBridge.runAndCapture`'s (`TimedProcessBox`): SIGTERM, then
/// SIGKILL after `CLIBridge.timeoutKillGrace`. Not for collect kinds, which can legitimately run
/// for minutes.
enum JamfCLIProbe {

    struct Output: Sendable {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
    }

    /// How a run ended, for a caller that must tell a stopped child from one that never started.
    enum Outcome: Sendable {
        case completed(Output)
        case timedOut
        case launchFailed
    }

    /// The root flag all three version readers send (`Provenance`, `DiagnosticBundleService`,
    /// `JamfCLIInstaller.installedVersion`).
    static let versionArguments = ["--version"]

    /// Seconds a probe gets, the same allowance as `ConnectionCheck`'s calls.
    static let defaultTimeout: TimeInterval = ConnectionCheck.timeout

    /// The child's exit code and output, or nil when it cannot be launched or had to be stopped
    /// at `timeout`. The caller must already have passed the codesign gate. Blocks the calling
    /// thread on a semaphore: for synchronous callers only, off the main actor and off the
    /// cooperative pool. A caller that is `async` uses `runAsync`.
    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) -> Output? {
        guard case .completed(let output) = runOutcome(
            executable: executable, arguments: arguments, timeout: timeout
        ) else { return nil }
        return output
    }

    /// `run` that says whether the child was stopped at `timeout` or never started.
    static func runOutcome(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) -> Outcome {
        let running = Running(executable: executable, arguments: arguments)
        let exited = DispatchSemaphore(value: 0)
        if running.start(timeout: timeout, onExit: { exited.signal() }) == .launchFailed {
            return .launchFailed
        }
        exited.wait()
        return running.outcome(timeout: timeout)
    }

    /// `run` without a blocked thread: the exit arrives on `terminationHandler`.
    static func runAsync(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) async -> Output? {
        guard case .completed(let output) = await runOutcomeAsync(
            executable: executable, arguments: arguments, timeout: timeout
        ) else { return nil }
        return output
    }

    /// `runOutcome` without a blocked thread. Same deadline, SIGTERM/SIGKILL and pipe draining.
    static func runOutcomeAsync(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) async -> Outcome {
        let running = Running(executable: executable, arguments: arguments)
        // A cancelled caller stops the child, as `CLIBridge.run` does.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let launch = running.start(timeout: timeout) {
                    continuation.resume(returning: running.outcome(timeout: timeout))
                }
                if launch == .launchFailed { continuation.resume(returning: .launchFailed) }
                // onCancel ran before the launch when the caller was already cancelled.
                if launch == .running, Task.isCancelled { running.terminate() }
            }
        } onCancel: {
            running.terminate()
        }
    }

    /// One probe child: `start` launches it, `outcome` reads the result once `onExit` has run.
    private final class Running: @unchecked Sendable {
        enum Launch { case running, launchFailed }
        private let process = Process()
        private let stdout = Pipe()
        private let stderr = Pipe()
        private let stdoutDrainer: ProcessPipeDrainer
        private let stderrDrainer: ProcessPipeDrainer
        private let box = TimedProcessBox()
        private let executableName: String

        init(executable: URL, arguments: [String]) {
            process.executableURL = executable
            process.arguments = arguments
            // SF-10/B-13: minimal env for jamf-cli invocations.
            process.environment = CLIBridge.environmentForJamfCLI()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout
            process.standardError = stderr
            stdoutDrainer = ProcessPipeDrainer(pipe: stdout)
            stderrDrainer = ProcessPipeDrainer(pipe: stderr)
            executableName = executable.lastPathComponent
        }

        /// `onExit` runs once the child has exited, including after a timeout; it does not run
        /// when the launch fails.
        func terminate() { box.terminate() }

        func start(timeout: TimeInterval, onExit: @escaping @Sendable () -> Void) -> Launch {
            // Drain from before the launch, or a child that exits at once reaches `finish()`
            // before the handler is installed and leaves it spinning at EOF.
            stdoutDrainer.start()
            stderrDrainer.start()
            box.set(process)
            process.terminationHandler = { [box] _ in
                box.disarmTimeout()
                onExit()
            }
            do {
                try process.run()
            } catch {
                stdoutDrainer.cancel()
                stderrDrainer.cancel()
                let reason = error.localizedDescription
                AppLogger.cli.error("JamfCLIProbe: launch failed: \(reason, privacy: .private)")
                return .launchFailed
            }
            box.stopIfClosing()
            box.armTimeout(timeout)
            return .running
        }

        func outcome(timeout: TimeInterval) -> Outcome {
            if box.didTimeOut {
                // A grandchild may still hold the pipes; do not wait for their EOF.
                stdoutDrainer.cancel()
                stderrDrainer.cancel()
                let name = executableName
                AppLogger.cli.warning(
                    "JamfCLIProbe: \(name, privacy: .private) timed out at \(timeout, privacy: .public)s"
                )
                return .timedOut
            }
            return .completed(Output(
                exitCode: process.terminationStatus,
                stdout: stdoutDrainer.finish(),
                stderr: stderrDrainer.finish()
            ))
        }
    }
}
