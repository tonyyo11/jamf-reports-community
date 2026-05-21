import Foundation
import OSLog
@testable import JamfReports

/// Test-side capture of `AppLogger` (`os.Logger`) emissions.
///
/// `AppLogger` writes through `os.Logger` under the subsystem
/// `com.github.tonyyo11.jamf-reports-community`. Production code logs
/// unconditionally — there is no injectable logger — so a test that needs to
/// assert a specific forensic log line was emitted reads it back from the
/// unified log via `OSLogStore`.
///
/// `OSLogStore(scope: .currentProcessIdentifier)` needs an entitlement that
/// XCTest hosts do not always have. `entries()` throws when access is denied;
/// callers should translate that into `XCTSkip` so the suite stays green on
/// CI hosts without the entitlement — the same contract `AppLoggerOSLogStoreTests`
/// already relies on.
struct OSLogCapture {
    private let since: Date
    private static let subsystem = "com.github.tonyyo11.jamf-reports-community"

    /// Begin capturing. Records the start instant so `entries()` only returns
    /// log lines emitted after this point. The start is back-dated one second
    /// to tolerate `OSLogStore.position(date:)` clock granularity.
    static func start() -> OSLogCapture {
        OSLogCapture(since: Date().addingTimeInterval(-1))
    }

    /// Every `AppLogger` log entry emitted since `start()`.
    /// Throws when `OSLogStore` access is denied — callers should `XCTSkip`.
    func entries() throws -> [OSLogEntryLog] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: since)
        let predicate = NSPredicate(format: "subsystem == %@", Self.subsystem)
        return try store.getEntries(at: position, matching: predicate)
            .compactMap { $0 as? OSLogEntryLog }
    }

    /// True when an `AppLogger` error-level entry's message contains `substring`.
    /// Throws when `OSLogStore` access is denied — callers should `XCTSkip`.
    func containsError(_ substring: String) throws -> Bool {
        try entries().contains { $0.level == .error && $0.composedMessage.contains(substring) }
    }
}
