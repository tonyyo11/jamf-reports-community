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

    /// Read and delete every marker. Filenames are labels; anything that fails
    /// `isValidLabel` is removed and ignored.
    static func consumeRunNowMarkers(dir: URL = runNowMarkerDir) -> Set<String> {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var labels: Set<String> = []
        for name in names {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
            if LaunchAgentWriter.isValidLabel(name) { labels.insert(name) }
        }
        return labels
    }

    /// Spawn `JamfReports --tick --now <label>` as a child. With `wait`, stream
    /// its stdout/stderr through `onLine` and return its exit code; without,
    /// return 0 as soon as it is launched (the health-row button).
    static func spawnNow(
        label: String,
        wait: Bool,
        executable: URL? = Bundle.main.executableURL,
        onLine: @Sendable @escaping (CLIBridge.LogLine) -> Void = { _ in }
    ) async -> Int32 {
        guard LaunchAgentWriter.isValidLabel(label), let executable else { return 1 }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--tick", "--now", label]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n") {
                onLine(CLIBridge.LogLine(timestamp: Date(), level: .info, text: String(line)))
            }
        }

        guard wait else {
            do {
                try process.run()
                return 0
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                return 1
            }
        }

        return await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
            process.terminationHandler = { proc in c.resume(returning: proc.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                pipe.fileHandleForReading.readabilityHandler = nil
                c.resume(returning: 1)
            }
        }
    }
}
