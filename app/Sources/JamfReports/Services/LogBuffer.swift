import Foundation

/// A single diagnostic event for the in-app log viewer. Carries its own
/// `Sendable` level so views need not import OSLog.
struct LogEntry: Identifiable, Sendable {
    enum Level: Int, Sendable, Comparable {
        case debug, info, notice, error, fault
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

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

/// In-memory ring buffer of the app's own diagnostic events for THIS session,
/// fed by `AppLogger.event`. Replaces the `OSLogStore` reader, which throws a
/// generic "error 0" in signed, Hardened-Runtime builds (it only worked in
/// unsigned dev builds, so the old viewer failed in production).
///
/// Messages are stored raw and scrubbed by `LogRedactor` at display/export time
/// — the same posture the export path already used. The buffer is capped (oldest
/// dropped) so a long session can't grow it without bound. Thread-safe: events
/// arrive from any thread; the viewer reads a snapshot on appear/refresh.
final class LogBuffer: @unchecked Sendable {
    static let shared = LogBuffer()

    private let lock = NSLock()
    private let capacity: Int
    private var entries: [LogEntry] = []

    init(capacity: Int = 2000) { self.capacity = max(1, capacity) }

    func append(_ entry: LogEntry) {
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Newest-first entries, filtered by minimum level and (optionally) a lower
    /// time bound, capped at the newest `limit`.
    func snapshot(minLevel: LogEntry.Level = .debug,
                  since: Date? = nil,
                  limit: Int = 1000) -> [LogEntry] {
        lock.lock(); let all = entries; lock.unlock()
        var filtered = all.filter { $0.level >= minLevel }
        if let since { filtered = filtered.filter { $0.date >= since } }
        return Array(filtered.suffix(limit).reversed())
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }
}
