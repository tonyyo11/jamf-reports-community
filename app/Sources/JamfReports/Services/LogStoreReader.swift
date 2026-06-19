import Foundation
import OSLog

/// A single decoded log entry for the in-app viewer. Carries its own `Sendable`
/// level so callers (views) need not import OSLog.
struct LogEntry: Identifiable, Sendable {
    enum Level: Int, Sendable, Comparable {
        case debug, info, notice, error, fault
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        init(_ osLevel: OSLogEntryLog.Level) {
            switch osLevel {
            case .debug: self = .debug
            case .info: self = .info
            case .notice: self = .notice
            case .error: self = .error
            case .fault: self = .fault
            default: self = .info   // .undefined → treat as info
            }
        }

        var label: String {
            switch self {
            case .debug: return "Debug"
            case .info: return "Info"
            case .notice: return "Notice"
            case .error: return "Error"
            case .fault: return "Fault"
            }
        }
    }

    let id = UUID()
    let date: Date
    let category: String
    let level: Level
    let message: String
}

/// Snapshot reader over the local OSLog store, scoped to our subsystem.
/// `.currentProcessIdentifier` (no special entitlement) → shows THIS session's logs,
/// which is the high-value target; cross-launch history stays the Console/export path.
enum LogStoreReader {
    static let subsystem = "com.github.tonyyo11.jamf-reports-community"

    /// Newest-first entries for our subsystem within the time window, filtered by
    /// category and minimum level, capped at `limit` (the newest `limit`).
    static func recent(categories: Set<String> = [], minLevel: LogEntry.Level = .info,
                       since: Date, limit: Int = 1000) throws -> [LogEntry] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: since)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        var out: [LogEntry] = []
        for case let log as OSLogEntryLog in try store.getEntries(at: position, matching: predicate) {
            let level = LogEntry.Level(log.level)
            guard level >= minLevel else { continue }
            if !categories.isEmpty, !categories.contains(log.category) { continue }
            out.append(LogEntry(date: log.date, category: log.category,
                                level: level, message: log.composedMessage))
        }
        return Array(out.suffix(limit).reversed())   // newest `limit`, newest-first
    }
}
