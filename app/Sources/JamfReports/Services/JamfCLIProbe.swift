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

    /// Seconds a probe gets, the same allowance as `ConnectionCheck`'s calls.
    static let defaultTimeout: TimeInterval = ConnectionCheck.timeout

    /// The child's exit code and output, or nil when it cannot be launched or had to be stopped
    /// at `timeout`. The caller must already have passed the codesign gate. Blocks the calling
    /// thread, so call it off the main actor.
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
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // SF-10/B-13: minimal env for jamf-cli invocations.
        process.environment = CLIBridge.environmentForJamfCLI()
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let box = TimedProcessBox()
        box.set(process)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            box.disarmTimeout()
            exited.signal()
        }
        do {
            try process.run()
        } catch {
            let reason = error.localizedDescription
            AppLogger.cli.error("JamfCLIProbe: launch failed: \(reason, privacy: .private)")
            return .launchFailed
        }
        box.armTimeout(timeout)

        // Drain while the child runs, or output past the pipe buffer would block it.
        let stdoutDrainer = ProcessPipeDrainer(pipe: stdout)
        let stderrDrainer = ProcessPipeDrainer(pipe: stderr)
        stdoutDrainer.start()
        stderrDrainer.start()
        exited.wait()

        if box.didTimeOut {
            // A grandchild may still hold the pipes; do not wait for their EOF.
            stdoutDrainer.cancel()
            stderrDrainer.cancel()
            let name = executable.lastPathComponent
            AppLogger.cli.warning(
                "JamfCLIProbe: \(name, privacy: .public) timed out at \(timeout, privacy: .public)s"
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
