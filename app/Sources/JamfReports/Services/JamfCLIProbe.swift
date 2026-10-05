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
            return nil
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
            AppLogger.cli.warning(
                "JamfCLIProbe: \(executable.lastPathComponent, privacy: .public) stopped after \(timeout, privacy: .public)s"
            )
            return nil
        }
        return Output(
            exitCode: process.terminationStatus,
            stdout: stdoutDrainer.finish(),
            stderr: stderrDrainer.finish()
        )
    }
}
