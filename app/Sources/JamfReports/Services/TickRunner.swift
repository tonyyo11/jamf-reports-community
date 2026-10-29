import Foundation

/// Run-now plumbing shared by the GUI and the CLI: a marker the next tick
/// consumes, plus spawning an immediate tick for it.
enum TickRunner {
    static var runNowMarkerDir: URL {
        AppSupport.directory().appendingPathComponent("run-now", isDirectory: true)
    }

    /// A tick that could not take the lock exits with this (`EX_TEMPFAIL`)
    /// rather than 0: the requested run has NOT happened yet, and every caller
    /// that reports an outcome — the Schedules screen, the health-card button,
    /// `jamf-reports schedules run` — must be able to say "queued" instead of
    /// claiming a run that only starts on the next wake.
    static let queuedExitCode: Int32 = 75

    /// Leave a marker so the label runs even if this process cannot take the
    /// lock right now (another run is in flight) — the next wake picks it up.
    static func requestRunNow(label: String, dir: URL = runNowMarkerDir) throws {
        guard LaunchAgentWriter.isValidLabel(label) else { return }
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data().write(to: dir.appendingPathComponent(label), options: .atomic)
    }

    /// Every queued label, with its marker left on disk: a tick killed during an
    /// earlier, longer run must not lose the requests queued behind it. Filenames
    /// are labels; anything that fails `isValidLabel` is removed and ignored.
    static func pendingRunNowLabels(dir: URL = runNowMarkerDir) -> Set<String> {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var labels: Set<String> = []
        for name in names {
            if LaunchAgentWriter.isValidLabel(name) {
                labels.insert(name)
            } else {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        return labels
    }

    /// Delete one label's marker. The tick calls this once the run's start is
    /// recorded and before the run begins, never after it ends: a run-now label is
    /// due unconditionally, so a marker outliving a run that crashed the process
    /// would re-run it on every wake.
    static func clearRunNowMarker(label: String, dir: URL = runNowMarkerDir) {
        guard LaunchAgentWriter.isValidLabel(label) else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(label))
    }

    /// Spawn `JamfReports --tick --now <label>` as a child through `CLIBridge.run`, the shared
    /// runner: line splitting, EOF-gated completion, handler cleanup and task cancellation (a
    /// cancelled caller stops the child). With `wait`, stream its output through `onLine` and
    /// return its exit code; without, return 0 once the executable is found and let the run
    /// finish unobserved (the health-row button). The parent's environment is passed on, as
    /// before: the child reads `JRC_WORKSPACES_ROOT` and the like.
    static func spawnNow(
        label: String,
        wait: Bool,
        executable: URL? = Bundle.main.executableURL,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void = { _ in }
    ) async -> Int32 {
        guard LaunchAgentWriter.isValidLabel(label), let executable else { return 1 }
        let arguments = ["--tick", "--now", label]
        let environment = ProcessInfo.processInfo.environment
        let bridge = await MainActor.run { CLIBridge() }
        guard wait else {
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { return 1 }
            Task.detached {
                _ = try? await bridge.run(
                    executable: executable, arguments: arguments,
                    environment: environment, onLine: onLine)
            }
            return 0
        }
        do {
            return try await bridge.run(
                executable: executable, arguments: arguments,
                environment: environment, onLine: onLine)
        } catch {
            return 1
        }
    }
}
