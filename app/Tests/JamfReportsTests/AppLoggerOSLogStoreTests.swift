import XCTest
import OSLog
@testable import JamfReports

/// MFS-4 (security audit C-07) — assert that `AppLogger` writes through
/// `os.Logger` (subsystem-level unified logging) and that those entries are
/// retrievable via `OSLogStore`.
///
/// `OSLogStore.local()` requires entitlements that XCTest hosts do not have
/// out of the box; when access is denied, the test is skipped rather than
/// failed so the suite stays green in CI environments without the
/// entitlement.
@MainActor
final class AppLoggerOSLogStoreTests: XCTestCase {

    func test_appLogger_emitsRetrievableEntries() throws {
        let store: OSLogStore
        do {
            store = try OSLogStore(scope: .currentProcessIdentifier)
        } catch {
            throw XCTSkip(
                "OSLogStore requires entitlements unavailable in this test host: \(error.localizedDescription)"
            )
        }

        // Emit a known marker. %{public} so we can match on the stored string.
        let marker = "JRC.AppLoggerOSLogStoreTests.\(UUID().uuidString)"
        AppLogger.collect.notice("oslog-test marker=\(marker, privacy: .public)")

        // Give the logging pipeline a moment to flush.
        let start = Date().addingTimeInterval(-5)
        let position = store.position(date: start)

        let predicate = NSPredicate(format: "subsystem == %@",
                                    "com.github.tonyyo11.jamf-reports-community")
        let entries: [OSLogEntry]
        do {
            entries = try store.getEntries(at: position, matching: predicate).map { $0 }
        } catch {
            throw XCTSkip("OSLogStore.getEntries denied: \(error.localizedDescription)")
        }

        let composed = entries.compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
        XCTAssertTrue(composed.contains(where: { $0.contains(marker) }),
                      "expected an OSLog entry containing marker=\(marker), got \(composed.count) entries")
    }
}
