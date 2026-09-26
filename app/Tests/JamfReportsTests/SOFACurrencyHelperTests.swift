import Foundation
import XCTest
@testable import JamfReports

final class SOFACurrencyHelperTests: XCTestCase {

    private func row(_ version: String) -> SOFAFeedService.OSFamilyRow {
        SOFAFeedService.OSFamilyRow(
            platform: "macOS", osFamily: "", productVersion: version, build: "",
            releaseDate: "", daysSinceRelease: nil, activelyExploitedCVEs: 0,
            securityInfoURL: "")
    }

    func testLatestByMajorKeepsTheGreatestVersionPerMajor() {
        let latest = SOFAFeedService.latestByMajor([
            row("15.7.2"), row("15.7.10"), row("26.5.1"), row(""),
        ])
        XCTAssertEqual(latest, [15: "15.7.10", 26: "26.5.1"],
                       "15.7.10 beats 15.7.2 numerically, not as text")
    }

    func testIsCurrentSeparatesBehindFromUntracked() {
        let latest = [15: "15.7.10", 26: "26.5.1"]
        XCTAssertEqual(SOFAFeedService.isCurrent("15.7.10", latestByMajor: latest), true)
        XCTAssertEqual(SOFAFeedService.isCurrent("26.6", latestByMajor: latest), true)
        XCTAssertEqual(SOFAFeedService.isCurrent("15.7.2", latestByMajor: latest), false)
        XCTAssertNil(SOFAFeedService.isCurrent("14.7.4", latestByMajor: latest),
                     "A major the feed doesn't track is unknown, not behind")
    }

    func testOSCurrentPercentStillMatchesItsHandWrittenRule() {
        // 2 of 4 Macs sit on their major's latest release.
        let pct = ReportEngine.osCurrentPercent(
            macOSRows: [row("15.7.10"), row("26.5.1")],
            osCounts: ["15.7.10": 1, "15.7.2": 1, "26.5.1": 1, "26.4": 1],
            totalDevices: 4)
        XCTAssertEqual(pct, 50.0)
    }
}
