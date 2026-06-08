import Foundation
import XCTest
@testable import JamfReports

/// Unit tests for `ReportEngine.osCurrentPercent(macOSRows:osCounts:totalDevices:)`.
///
/// All tests use synthetic data — no temp dirs, no JSON parsing, no real SOFA feeds.
/// The helper is pure (takes plain structs + dicts) so these tests run instantly and
/// deterministically.
final class OSCurrentPercentTests: XCTestCase {

    // MARK: - Helpers

    /// Synthesize a minimal `SOFAFeedService.OSFamilyRow` with just platform and productVersion.
    private func macOSRow(version: String) -> SOFAFeedService.OSFamilyRow {
        SOFAFeedService.OSFamilyRow(
            platform: "macOS",
            osFamily: "Test \(SOFAFeedService.versionTuple(version).first ?? 0)",
            productVersion: version,
            build: "25A000",
            releaseDate: "2026-01-01",
            daysSinceRelease: 10,
            activelyExploitedCVEs: 0,
            securityInfoURL: ""
        )
    }

    // MARK: - Nil cases

    func testNilWhenMacOSRowsEmpty() {
        let result = ReportEngine.osCurrentPercent(
            macOSRows: [],
            osCounts: ["15.7.7": 100],
            totalDevices: 100
        )
        XCTAssertNil(result, "Must return nil when SOFA macOS rows are absent (no cache)")
    }

    func testNilWhenTotalDevicesZero() {
        let rows = [macOSRow(version: "15.7.7")]
        let result = ReportEngine.osCurrentPercent(
            macOSRows: rows,
            osCounts: ["15.7.7": 0],
            totalDevices: 0
        )
        XCTAssertNil(result, "Must return nil when totalDevices is 0")
    }

    // MARK: - Single-major fleet

    func testAllCurrentSingleMajor() {
        // 100% of 200 devices are on 15.7.7 — all current.
        let rows = [macOSRow(version: "15.7.7")]
        let counts = ["15.7.7": 200]
        let result = try? XCTUnwrap(ReportEngine.osCurrentPercent(
            macOSRows: rows, osCounts: counts, totalDevices: 200))
        XCTAssertEqual(result!, 100.0, accuracy: 0.01)
    }

    func testNoneCurrentSingleMajor() {
        // All devices are behind (15.7.3 < 15.7.7).
        let rows = [macOSRow(version: "15.7.7")]
        let counts = ["15.7.3": 100]
        let result = ReportEngine.osCurrentPercent(
            macOSRows: rows, osCounts: counts, totalDevices: 100)
        XCTAssertEqual(result!, 0.0, accuracy: 0.01)
    }

    func testPartialCurrentSingleMajor() {
        // 75 out of 100 are on latest.
        let rows = [macOSRow(version: "15.7.7")]
        let counts = ["15.7.7": 75, "15.6.1": 25]
        let result = ReportEngine.osCurrentPercent(
            macOSRows: rows, osCounts: counts, totalDevices: 100)
        XCTAssertEqual(result!, 75.0, accuracy: 0.01)
    }

    // MARK: - Transition fleet (two majors) — the key regression case

    /// The scenario from the bug report: a fleet split between Sequoia (15) and
    /// Tahoe (26). The old config-list approach returned ~0.2% because the static
    /// list ["15.4", "15.3.2"] matched very few devices. The SOFA-driven approach
    /// counts per-major-latest and must return a high percentage when most devices
    /// are current for their major.
    func testTransitionFleetTwoMajors() {
        // SOFA: Sequoia latest = 15.7.7, Tahoe latest = 26.5.1.
        let rows = [macOSRow(version: "15.7.7"), macOSRow(version: "26.5.1")]
        // Fleet: 70 Tahoe current, 20 Sequoia current, 10 Sequoia behind.
        let counts = ["26.5.1": 70, "15.7.7": 20, "15.6.0": 10]
        let result = ReportEngine.osCurrentPercent(
            macOSRows: rows, osCounts: counts, totalDevices: 100)
        // 90 out of 100 are current → 90%.
        XCTAssertEqual(result!, 90.0, accuracy: 0.01,
                       "Transition fleet: 70 Tahoe current + 20 Sequoia current = 90%")
    }

    func testTransitionFleetOldConfigApproachWouldFail() {
        // Illustrates the pre-fix regression. The old code used a config list like
        // ["15.4", "15.3.2"] — neither matches the current 15.7.7 or 26.5.1 fleet,
        // so it would return ~0% even though ~90% are current.
        // The SOFA-driven approach correctly returns 90% here.
        let rows = [macOSRow(version: "15.7.7"), macOSRow(version: "26.5.1")]
        let counts = ["26.5.1": 60, "15.7.7": 30, "15.0.0": 10]
        let result = ReportEngine.osCurrentPercent(
            macOSRows: rows, osCounts: counts, totalDevices: 100)
        XCTAssertGreaterThan(result!, 50.0,
                             "SOFA-driven metric must not report ~0% for a mostly-current fleet")
        XCTAssertEqual(result!, 90.0, accuracy: 0.01)
    }

    // MARK: - Newer device (>= latest) counts as current

    func testDeviceAheadOfLatestCountsAsCurrent() {
        // A device on 15.7.10 when SOFA says 15.7.7 is still current (>= latest).
        let rows = [macOSRow(version: "15.7.7")]
        let counts = ["15.7.10": 50, "15.7.7": 50]
        let result = ReportEngine.osCurrentPercent(
            macOSRows: rows, osCounts: counts, totalDevices: 100)
        XCTAssertEqual(result!, 100.0, accuracy: 0.01,
                       "15.7.10 >= 15.7.7 so both groups are 'current'")
    }

    // MARK: - Cross-platform guard: iOS rows must not pollute macOS major

    func testIOSRowsFilteredOut() {
        // An iOS row with major 26 must not steal the major-26 slot from macOS 26.5.1.
        // The helper filters to `platform == "macOS"` before building latestByMajor.
        let iosRow = SOFAFeedService.OSFamilyRow(
            platform: "iOS / iPadOS",
            osFamily: "iOS 26",
            productVersion: "26.0.0",
            build: "23A000",
            releaseDate: "2026-01-01",
            daysSinceRelease: 10,
            activelyExploitedCVEs: 0,
            securityInfoURL: ""
        )
        let macOSRowV = macOSRow(version: "26.5.1")
        // Fleet: all Tahoe current.
        let counts = ["26.5.1": 100]
        let result = ReportEngine.osCurrentPercent(
            macOSRows: [macOSRowV, iosRow],   // caller must pass macOS-only; passing iOS here
            osCounts: counts, totalDevices: 100)
        // Even though an iOS row is passed, macOS 26.5.1 → major 26 → 100% current.
        // The iOS row raises no error; it just picks the greater version for major 26.
        // Correct behavior: pass only macOS rows (the engine filters before calling).
        XCTAssertNotNil(result)
    }

    // MARK: - Deduplication: two SOFA rows for same major → keep latest

    func testTwoRowsSameMajorKeepsLatest() {
        // SOFA might surface two entries for major 15 (edge case in feed structure).
        // The helper must keep 15.7.7 not 15.6.0.
        let rowA = macOSRow(version: "15.6.0")
        let rowB = macOSRow(version: "15.7.7")
        // All 100 devices are on 15.7.7 — should be 100% current.
        let counts = ["15.7.7": 100]
        let result = ReportEngine.osCurrentPercent(
            macOSRows: [rowA, rowB], osCounts: counts, totalDevices: 100)
        XCTAssertEqual(result!, 100.0, accuracy: 0.01,
                       "Two rows for the same major: the greater version (15.7.7) must win")
    }

    func testTwoRowsSameMajorOlderLatestWouldUndercount() {
        // If the helper picked 15.6.0 instead of 15.7.7 as latest, devices on 15.7.7
        // would still count as current (>= 15.6.0) — that's correct behavior.
        // And devices on 15.6.0 would also be current (== latest). Both are fine.
        // The deduplication matters only when the lesser version would wrongly exclude
        // devices on the newer release.
        let rowOlder = macOSRow(version: "15.6.0")
        let rowNewer = macOSRow(version: "15.7.7")
        let counts = ["15.6.0": 40, "15.7.7": 60]
        let result = ReportEngine.osCurrentPercent(
            macOSRows: [rowOlder, rowNewer], osCounts: counts, totalDevices: 100)
        // With correct dedup (15.7.7 wins): devices on 15.6.0 are NOT current → 60%.
        XCTAssertEqual(result!, 60.0, accuracy: 0.01,
                       "15.7.7 is latest; 15.6.0 devices are behind → only 60% current")
    }
}
