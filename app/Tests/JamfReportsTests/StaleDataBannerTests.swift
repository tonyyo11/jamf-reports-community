import XCTest
import SwiftUI
@testable import JamfReports

@MainActor
final class StaleDataBannerTests: XCTestCase {

    // MARK: - CacheSource state machine

    func testCacheSourceFreshHidesBanner() {
        let source: CacheSource = .fresh
        XCTAssertFalse(source.shouldDisplayBanner,
                       "Fresh source must suppress the banner — no UI noise on healthy data")
    }

    func testCacheSourceStaleShowsBanner() {
        let source: CacheSource = .stale(at: Date(timeIntervalSinceNow: -86_400 * 2))
        XCTAssertTrue(source.shouldDisplayBanner, "Stale source must show the banner")
    }

    func testCacheSourceNeverFetchedLiveShowsBanner() {
        let source: CacheSource = .neverFetchedLive
        XCTAssertTrue(source.shouldDisplayBanner,
                      "Never-fetched-live source must show the banner")
    }

    func testCacheSourceFromSnapshotDateNilIsNeverFetchedLive() {
        let source = CacheSource.from(snapshotDate: nil)
        XCTAssertEqual(source, .neverFetchedLive)
    }

    func testCacheSourceFromSnapshotDateWithinWindowIsFresh() {
        let recent = Date(timeIntervalSinceNow: -3_600)
        let source = CacheSource.from(snapshotDate: recent, withinHours: 36)
        XCTAssertEqual(source, .fresh)
    }

    func testCacheSourceFromSnapshotDateOutsideWindowIsStale() {
        let oldDate = Date(timeIntervalSinceNow: -86_400 * 3) // 3 days ago
        let source = CacheSource.from(snapshotDate: oldDate, withinHours: 36)
        switch source {
        case .stale(let at):
            XCTAssertEqual(at.timeIntervalSince1970, oldDate.timeIntervalSince1970, accuracy: 0.001)
        default:
            XCTFail("Expected .stale, got \(source)")
        }
    }

    // MARK: - StaleDataBanner rendered copy

    func testRendersFreshState() {
        let banner = StaleDataBanner(source: .fresh)
        // Fresh state — banner renders empty body, but the view itself is
        // valid and instantiable so consumers can place it unconditionally.
        XCTAssertNotNil(banner)
        XCTAssertEqual(banner.message, "")
    }

    func testRendersStaleStateWithRelativeDate() {
        let twoDaysAgo = Date(timeIntervalSinceNow: -86_400 * 2)
        let banner = StaleDataBanner(source: .stale(at: twoDaysAgo))
        XCTAssertNotNil(banner)
        let message = banner.message
        XCTAssertTrue(message.hasPrefix("Stale data — last fetched "),
                      "Expected stale prefix, got: \(message)")
        // RelativeDateTimeFormatter produces "2 days ago" or localized
        // equivalents; just confirm a relative phrase trails the prefix.
        XCTAssertGreaterThan(message.count, "Stale data — last fetched ".count,
                             "Relative date suffix must be appended")
    }

    func testRendersNeverFetchedLiveStateDistinctFromStale() {
        let neverBanner = StaleDataBanner(source: .neverFetchedLive)
        let staleBanner = StaleDataBanner(source: .stale(at: Date()))
        XCTAssertNotEqual(
            neverBanner.message,
            staleBanner.message,
            "Never-fetched-live copy must differ from stale copy — closes PR-7 BACKLOG CONSIDER"
        )
        XCTAssertEqual(
            neverBanner.message,
            "No live data fetched yet — run Collect to populate"
        )
    }

    // MARK: - #12: .stale(at:) relative time is always finite (Epic #102)
    //
    // DeviceLookupView.staleSince feeds StaleDataBanner(.stale(at:)) only when
    // non-nil; on first launch (no manifest, no cache) it stays nil and the
    // banner is not rendered (`if let since = staleSince`). That nil path was
    // audited and confirmed safe. The remaining risk is the relative-time
    // suffix itself: this pins that `RelativeDateTimeFormatter` yields a
    // finite, non-empty phrase even for extreme dates, so a formatter
    // regression cannot surface as a NaN / empty banner.

    func testStaleBannerRelativeTimeIsFiniteForEdgeDates() {
        let prefix = "Stale data — last fetched "
        let edgeDates: [Date] = [
            .distantPast,
            .distantFuture,
            Date(),
            Date(timeIntervalSinceNow: -86_400 * 365),
        ]
        for date in edgeDates {
            let message = StaleDataBanner(source: .stale(at: date)).message
            XCTAssertTrue(message.hasPrefix(prefix),
                          "Expected stale prefix for \(date); got: \(message)")
            let suffix = String(message.dropFirst(prefix.count))
            XCTAssertFalse(suffix.isEmpty,
                           "Relative-time suffix must not be empty for \(date)")
            XCTAssertFalse(suffix.lowercased().contains("nan"),
                           "Relative-time suffix must never contain NaN for \(date); got: \(suffix)")
        }
    }
}
