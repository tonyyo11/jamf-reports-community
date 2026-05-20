import Foundation
import OSLog

// MARK: - Unified Logger

/// Central logging entry point. Subsystem and categories match the bundle identifier prefix.
/// Usage: `AppLogger.ui.debug("view appeared")`
enum AppLogger {
    private static let subsystem = "com.github.tonyyo11.jamf-reports-community"

    static let engine   = Logger(subsystem: subsystem, category: "engine")
    static let cli      = Logger(subsystem: subsystem, category: "cli")
    static let schedule = Logger(subsystem: subsystem, category: "schedule")
    static let ui       = Logger(subsystem: subsystem, category: "ui")
}

// MARK: - Crash log writer

/// Writes an uncaught-exception crash log to `~/Library/Logs/JamfReports/crash_<timestamp>.log`.
///
/// Install once before launching the GUI:
/// ```swift
/// CrashReporter.install()
/// ```
/// The handler does not re-throw — the process terminates after the handler returns, which
/// is the default NSApplication behaviour for uncaught NSExceptions.
enum CrashReporter {

    /// Install the uncaught exception handler. Safe to call multiple times; subsequent
    /// calls replace the handler with the same implementation.
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.write(exception)
        }
    }

    // MARK: - Private

    private static func write(_ exception: NSException) {
        let fm = FileManager.default
        let logDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/JamfReports", isDirectory: true)
        // Best-effort directory creation — if it fails we can't log, but we also can't crash.
        // 0o700: device serials, hostnames, and usernames appear in crash logs; restrict to owner.
        try? fm.createDirectory(
            at: logDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Tighten permissions on any pre-existing directory created with a looser umask.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logDir.path)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "Z")
        let logURL = logDir.appendingPathComponent("crash_\(timestamp).log")

        let symbols = exception.callStackSymbols.joined(separator: "\n")
        let report = """
            Jamf Reports — Uncaught Exception
            Date: \(timestamp)
            Name: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "(none)")

            Call Stack Symbols:
            \(symbols)
            """

        // B-06: create with 0o600 atomically rather than write-then-chmod.
        // Closes the TOCTOU window where another local user could open the
        // file before the chmod lands. createFile is atomic at the syscall
        // level when the file does not already exist.
        let data = Data(report.utf8)
        if fm.fileExists(atPath: logURL.path) {
            try? fm.removeItem(at: logURL)
        }
        fm.createFile(
            atPath: logURL.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        )

        // Mirror to OSLog so the crash appears in Console.app alongside other app logs.
        AppLogger.ui.critical("Uncaught exception: \(exception.name.rawValue) — \(exception.reason ?? "(none)")")
    }
}
