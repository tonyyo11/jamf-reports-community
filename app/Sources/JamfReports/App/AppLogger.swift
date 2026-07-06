import Foundation
import OSLog

// MARK: - Unified Logger

/// Central logging entry point. Subsystem and categories match the bundle identifier prefix.
/// Usage: `AppLogger.ui.debug("view appeared")`
///
/// Level convention — apply consistently:
///   .error   actionable failure the operator must address
///   .warning degraded but continuing (a fallback fired / a non-fatal skip)
///   .notice  significant state transition (kept at default persistence)
///   .info    milestone / progress (verbose; persisted only with debug logging on)
///   .debug   fine-grained per-item / per-seam trace (verbose-only)
enum AppLogger {
    private static let subsystem = "com.github.tonyyo11.jamf-reports-community"

    static let cli      = Logger(subsystem: subsystem, category: "cli")       // jamf-cli spawn/exec/exit
    static let collect  = Logger(subsystem: subsystem, category: "collect")   // snapshot collection + parsing
    static let report   = Logger(subsystem: subsystem, category: "report")    // xlsx/html/chart generation
    static let auth     = Logger(subsystem: subsystem, category: "auth")      // credential/token/auth-guard
    static let schedule = Logger(subsystem: subsystem, category: "schedule")  // launchd/scheduled runs
    static let webhook  = Logger(subsystem: subsystem, category: "webhook")   // Teams/Slack notify
    static let platform = Logger(subsystem: subsystem, category: "platform")  // Protect/School/DDM/compliance
    static let ui       = Logger(subsystem: subsystem, category: "ui")        // views/state

    /// The eight categories above, addressable by name for `event(_:_:_:)`.
    enum Category: String, Sendable {
        case cli, collect, report, auth, schedule, webhook, platform, ui
    }

    private static func logger(for category: Category) -> Logger {
        switch category {
        case .cli: return cli
        case .collect: return collect
        case .report: return report
        case .auth: return auth
        case .schedule: return schedule
        case .webhook: return webhook
        case .platform: return platform
        case .ui: return ui
        }
    }

    private static func osType(_ level: LogEntry.Level) -> OSLogType {
        switch level {
        case .debug:  return .debug
        case .info:   return .info
        case .notice: return .default
        case .error:  return .error
        case .fault:  return .fault
        }
    }

    /// Log an operational event to OSLog AND mirror it into `LogBuffer`, so the
    /// in-app viewer can show it in signed builds (where `OSLogStore` reads fail
    /// with a generic error). `message` MUST be free of secrets — it is stored
    /// raw and scrubbed by `LogRedactor` only at display/export time. Secret- or
    /// PII-bearing logs keep using the category `Logger`s directly with
    /// `privacy: .private`; those never reach the buffer.
    static func event(_ category: Category, _ level: LogEntry.Level, _ message: String) {
        logger(for: category).log(level: osType(level), "\(message, privacy: .public)")
        LogBuffer.shared.append(
            LogEntry(date: Date(), category: category.rawValue, level: level, message: message)
        )
    }
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
