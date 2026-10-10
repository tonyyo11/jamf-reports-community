import XCTest
@testable import JamfReports

/// What the two currency factors read from the cached macOS SOFA feed: each release of a
/// major version with its date, and the newest XProtect. The feed below is hand-built in the
/// shape of `macos_data_feed.json` with the dates the design's example uses: a Tahoe 26 Mac
/// 30 days after 26.6.2 (2026-08-17) needs 26.6.2, not 26.7.1 (2026-09-28).
final class SOFAScoreFeedTests: XCTestCase {

    private static let feedJSON = """
        {
          "OSVersions": [
            {
              "OSVersion": "Tahoe 26",
              "Latest": {"ProductVersion": "26.7.1", "ReleaseDate": "2026-09-28T17:00:00Z"},
              "SecurityReleases": [
                {"ProductVersion": "26.7.1", "ReleaseDate": "2026-09-28T17:00:00Z"},
                {"ProductVersion": "26.7", "ReleaseDate": "2026-09-15T17:00:00Z"},
                {"ProductVersion": "26.6.2", "ReleaseDate": "2026-08-17T17:00:00Z"},
                {"ProductVersion": "26.6.1", "ReleaseDate": "2026-07-20"},
                {"ProductVersion": "26.6", "ReleaseDate": "2026-07-06T17:00:00Z"},
                {"ProductVersion": "26.5.9"},
                {"ReleaseDate": "2026-01-01T17:00:00Z"}
              ]
            },
            {
              "OSVersion": "Sequoia 15",
              "Latest": {"ProductVersion": "15.7.9", "ReleaseDate": "2026-09-01T17:00:00Z"},
              "SecurityReleases": [
                {"ProductVersion": "15.7.8", "ReleaseDate": "2026-07-01T17:00:00Z"}
              ]
            }
          ],
          "XProtectPlistConfigData": {
            "com.apple.XProtect": "5363",
            "ReleaseDate": "2026-09-29T17:00:00Z"
          }
        }
        """

    private static let now = date("2026-10-05T12:00:00Z")

    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? .distantPast
    }

    private func feed(_ json: String = SOFAScoreFeedTests.feedJSON) throws -> SOFAScoreFeed {
        try XCTUnwrap(SOFAScoreFeed.decode(Data(json.utf8)))
    }

    // MARK: - Decode

    /// Newest version first; the same release listed as Latest and in SecurityReleases once;
    /// an entry with no date or no version is skipped; a bare date reads as a date.
    func testReleasesAreGroupedByMajorSortedNewestFirstAndDeduplicated() throws {
        let feed = try feed()
        XCTAssertEqual(feed.releasesByMajor[26]?.map(\.version),
                       ["26.7.1", "26.7", "26.6.2", "26.6.1", "26.6"])
        XCTAssertEqual(feed.releasesByMajor[15]?.map(\.version), ["15.7.9", "15.7.8"])
        XCTAssertNil(feed.releasesByMajor[14])
        let bare = try XCTUnwrap(feed.releasesByMajor[26]?.first { $0.version == "26.6.1" })
        XCTAssertEqual(bare.date, Self.date("2026-07-20T00:00:00Z"))
        XCTAssertEqual(feed.releasesByMajor[26]?.first?.date, Self.date("2026-09-28T17:00:00Z"))
    }

    func testTheNewestXProtectAndItsDateAreRead() throws {
        let feed = try feed()
        XCTAssertEqual(feed.xprotectVersion, 5363)
        XCTAssertEqual(feed.xprotectReleased, Self.date("2026-09-29T17:00:00Z"))
    }

    func testAFeedWithoutXProtectOrOSVersionsStillDecodes() throws {
        let noXProtect = try feed("""
            {"OSVersions": [{"Latest": {"ProductVersion": "26.7.1",
                                        "ReleaseDate": "2026-09-28T17:00:00Z"}}]}
            """)
        XCTAssertNil(noXProtect.xprotectVersion)
        XCTAssertEqual(noXProtect.releasesByMajor[26]?.map(\.version), ["26.7.1"])

        let onlyXProtect = try feed(
            "{\"XProtectPlistConfigData\": {\"com.apple.XProtect\": \"5000\"}}")
        XCTAssertEqual(onlyXProtect.xprotectVersion, 5000)
        XCTAssertNil(onlyXProtect.xprotectReleased)
        XCTAssertTrue(onlyXProtect.releasesByMajor.isEmpty)
    }

    /// An XProtect block with values of another type reads as absent; the releases survive.
    func testAnXProtectBlockOfTheWrongTypeCostsOnlyXProtect() throws {
        let feed = try feed("""
            {"OSVersions": [{"Latest": {"ProductVersion": "26.7.1",
                                        "ReleaseDate": "2026-09-28T17:00:00Z"}}],
             "XProtectPlistConfigData": {"com.apple.XProtect": 5363, "ReleaseDate": ["x"]}}
            """)
        XCTAssertNil(feed.xprotectVersion)
        XCTAssertNil(feed.xprotectReleased)
        XCTAssertEqual(feed.releasesByMajor[26]?.count, 1)
    }

    /// One release with a number for `ProductVersion` is skipped on its own; the synthesized
    /// decoder failed the whole feed, which silently dropped both currency factors.
    func testAReleaseOfTheWrongTypeCostsOnlyThatRelease() throws {
        let feed = try feed("""
            {"OSVersions": [
               {"Latest": {"ProductVersion": 26.7, "ReleaseDate": "2026-09-28T17:00:00Z"},
                "SecurityReleases": [
                  {"ProductVersion": "26.6.2", "ReleaseDate": "2026-08-17T17:00:00Z"},
                  {"ProductVersion": 26.6, "ReleaseDate": "2026-07-06T17:00:00Z"},
                  {"ProductVersion": "26.5", "ReleaseDate": 20260601},
                  null, "26.4", [1]]},
               {"Latest": {"ProductVersion": "15.7.9", "ReleaseDate": "2026-09-01T17:00:00Z"}}],
             "XProtectPlistConfigData": {"com.apple.XProtect": "5363"}}
            """)
        XCTAssertEqual(feed.releasesByMajor[26]?.map(\.version), ["26.6.2"])
        XCTAssertEqual(feed.releasesByMajor[15]?.map(\.version), ["15.7.9"])
        XCTAssertEqual(feed.xprotectVersion, 5363)
        XCTAssertEqual(feed.isCurrent("26.6.2", graceDays: 30, now: Self.now), true)
    }

    func testAnEntryOrListOfTheWrongShapeCostsOnlyThatPart() throws {
        let feed = try feed("""
            {"OSVersions": [
               7,
               {"Latest": "26.7.1", "SecurityReleases": {"ProductVersion": "26.7.1"}},
               {"Latest": {"ProductVersion": "15.7.9", "ReleaseDate": "2026-09-01T17:00:00Z"},
                "SecurityReleases": "none"}],
             "XProtectPlistConfigData": {"com.apple.XProtect": "5363"}}
            """)
        XCTAssertNil(feed.releasesByMajor[26])
        XCTAssertEqual(feed.releasesByMajor[15]?.map(\.version), ["15.7.9"])
        XCTAssertEqual(feed.xprotectVersion, 5363)
    }

    func testOSVersionsOfTheWrongTypeCostsOnlyTheReleases() throws {
        let feed = try feed("""
            {"OSVersions": {"Latest": "x"},
             "XProtectPlistConfigData": {"com.apple.XProtect": "5363"}}
            """)
        XCTAssertTrue(feed.releasesByMajor.isEmpty)
        XCTAssertEqual(feed.xprotectVersion, 5363)
    }

    func testNotAFeedDecodesToNil() {
        XCTAssertNil(SOFAScoreFeed.decode(Data("not json".utf8)))
        XCTAssertNil(SOFAScoreFeed.decode(Data("[1, 2]".utf8)))
    }

    func testLoadReadsTheCachedFeedFromTheSofaFolder() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-sofa-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dataDir) }
        XCTAssertNil(SOFAScoreFeed.load(dataDir: dataDir), "nothing cached")

        let folder = dataDir.appendingPathComponent("sofa", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.feedJSON.utf8)
            .write(to: folder.appendingPathComponent("macos_data_feed.json"))
        XCTAssertEqual(SOFAScoreFeed.load(dataDir: dataDir), try feed())
    }

    // MARK: - macOS currency

    /// 30 days before 2026-10-05 is 2026-09-05: 26.6.2 is the newest release older than that,
    /// so it is what a Tahoe Mac needs. 26.7 and 26.7.1 are within the grace period.
    func testAMacNeedsTheNewestReleaseOlderThanTheGracePeriod() throws {
        let feed = try feed()
        func current(_ version: String, grace: Int = 30) -> Bool? {
            feed.isCurrent(version, graceDays: grace, now: Self.now)
        }
        XCTAssertEqual(current("26.6.2"), true, "the release 30 days ago is enough")
        XCTAssertEqual(current("26.7.1"), true)
        XCTAssertEqual(current("26.7"), true)
        XCTAssertEqual(current("26.6.1"), false, "behind the required release")
        XCTAssertEqual(current("26.6"), false)
        XCTAssertEqual(current("26.5"), false)
        XCTAssertEqual(current("26.6.2.1"), true, "a longer version compares as newer")
    }

    private func majorFeed(_ releases: String, xprotect: String = "") -> String {
        let extra = xprotect.isEmpty ? "" : ", \"XProtectPlistConfigData\": \(xprotect)"
        return "{\"OSVersions\": [{\"SecurityReleases\": [\(releases)]}]\(extra)}"
    }

    /// A forged or edited feed that dates every release of a major in the future would
    /// otherwise read "nothing is required yet" and mark every Mac on that major current.
    func testAMajorWhoseReleasesAreAllFutureDatedIsUnknownNotCurrent() throws {
        let feed = try feed(majorFeed("""
            {"ProductVersion": "26.9", "ReleaseDate": "2027-01-01T00:00:00Z"},
            {"ProductVersion": "26.8", "ReleaseDate": "2026-12-01T00:00:00Z"}
            """))
        XCTAssertNil(feed.isCurrent("26.0", graceDays: 30, now: Self.now))
        XCTAssertNil(feed.isCurrent("26.9", graceDays: 30, now: Self.now))
    }

    func testAFutureDatedNewestReleaseIsIgnoredAndTheOlderRealOneIsRequired() throws {
        let feed = try feed(majorFeed("""
            {"ProductVersion": "26.9", "ReleaseDate": "2027-01-01T00:00:00Z"},
            {"ProductVersion": "26.6.2", "ReleaseDate": "2026-08-17T17:00:00Z"}
            """))
        XCTAssertEqual(feed.isCurrent("26.6.2", graceDays: 30, now: Self.now), true)
        XCTAssertEqual(feed.isCurrent("26.6.1", graceDays: 30, now: Self.now), false)
    }

    /// Release day can look like tomorrow across time zones, so 12 hours ahead still counts.
    func testAReleaseDatedHalfADayAheadStillCounts() throws {
        let feed = try feed(majorFeed("""
            {"ProductVersion": "26.8", "ReleaseDate": "2026-10-06T00:00:00Z"}
            """))
        XCTAssertEqual(feed.isCurrent("26.0", graceDays: 30, now: Self.now), true,
                       "within the grace period, so nothing is required yet; not unknown")
    }

    /// The same Mac is behind with a short grace period and current with a long one.
    func testTheGracePeriodMovesTheRequiredRelease() throws {
        let feed = try feed()
        // 5 days: 26.7.1 (7 days old) is required.
        XCTAssertEqual(feed.isCurrent("26.7", graceDays: 5, now: Self.now), false)
        XCTAssertEqual(feed.isCurrent("26.7.1", graceDays: 5, now: Self.now), true)
        // 0 days: the newest release the feed lists.
        XCTAssertEqual(feed.isCurrent("26.6.2", graceDays: 0, now: Self.now), false)
        // 60 days: 2026-08-06, so 26.6.1 (2026-07-20) is required.
        XCTAssertEqual(feed.isCurrent("26.6.1", graceDays: 60, now: Self.now), true)
        XCTAssertEqual(feed.isCurrent("26.6", graceDays: 60, now: Self.now), false)
    }

    /// When every release of the major came out inside the grace period nothing is required
    /// yet, so any version of that major is current.
    func testWhenEveryReleaseIsWithinTheGraceNothingIsRequiredYet() throws {
        let feed = try feed()
        XCTAssertEqual(feed.isCurrent("26.0", graceDays: 365, now: Self.now), true)
        XCTAssertEqual(feed.isCurrent("26.6", graceDays: 100, now: Self.now), true,
                       "26.6 itself came out 91 days ago")
        let fresh = Self.date("2026-07-02T00:00:00Z")
        XCTAssertEqual(feed.isCurrent("15.0", graceDays: 100, now: fresh), true)
    }

    func testAMajorTheFeedDoesNotListIsUnknownNotBehind() throws {
        let feed = try feed()
        XCTAssertNil(feed.isCurrent("14.8", graceDays: 30, now: Self.now))
        XCTAssertNil(feed.isCurrent("27.0", graceDays: 30, now: Self.now))
        XCTAssertNil(feed.isCurrent("not a version", graceDays: 30, now: Self.now))
        XCTAssertNil(feed.isCurrent("", graceDays: 30, now: Self.now))
    }

    func testEachMajorIsJudgedAgainstItsOwnReleases() throws {
        let feed = try feed()
        XCTAssertEqual(feed.isCurrent("15.7.9", graceDays: 30, now: Self.now), true)
        XCTAssertEqual(feed.isCurrent("15.7.8", graceDays: 30, now: Self.now), false,
                       "15.7.9 came out more than 30 days ago, so it is required")
        XCTAssertEqual(feed.isCurrent("15.7.8", graceDays: 60, now: Self.now), true)
    }

    // MARK: - XProtect currency

    func testTheNewestXProtectIsCurrentAndANewerOneToo() throws {
        let feed = try feed()
        XCTAssertEqual(feed.isXProtectCurrent(5363, graceDays: 14, now: Self.now), true)
        XCTAssertEqual(feed.isXProtectCurrent(5400, graceDays: 0, now: Self.now), true)
    }

    /// 5363 came out 2026-09-29 17:00, 5.8 days before the fixed `now`.
    func testAnOlderXProtectIsCurrentOnlyWithinTheGracePeriodOfTheNewest() throws {
        let feed = try feed()
        XCTAssertEqual(feed.isXProtectCurrent(5362, graceDays: 14, now: Self.now), true)
        XCTAssertEqual(feed.isXProtectCurrent(5362, graceDays: 6, now: Self.now), true)
        XCTAssertEqual(feed.isXProtectCurrent(5362, graceDays: 5, now: Self.now), false)
        XCTAssertEqual(feed.isXProtectCurrent(5362, graceDays: 0, now: Self.now), false)
        let later = Self.date("2026-10-20T00:00:00Z")
        XCTAssertEqual(feed.isXProtectCurrent(5362, graceDays: 14, now: later), false,
                       "20 days after the release, 14 days of grace are used up")
    }

    /// A future-dated release must not buy every older XProtect an unbounded grace period.
    func testAFutureDatedXProtectReleaseGivesNoGrace() throws {
        let future = try feed(majorFeed("", xprotect: """
            {"com.apple.XProtect": "5363", "ReleaseDate": "2027-01-01T00:00:00Z"}
            """))
        XCTAssertEqual(future.isXProtectCurrent(5362, graceDays: 14, now: Self.now), false)
        XCTAssertEqual(future.isXProtectCurrent(5363, graceDays: 14, now: Self.now), true)

        let halfDayAhead = try feed(majorFeed("", xprotect: """
            {"com.apple.XProtect": "5363", "ReleaseDate": "2026-10-06T00:00:00Z"}
            """))
        XCTAssertEqual(halfDayAhead.isXProtectCurrent(5362, graceDays: 14, now: Self.now), true)
    }

    func testXProtectIsUnknownWithoutAnXProtectVersionInTheFeed() throws {
        let noXProtect = try feed(
            "{\"OSVersions\": [{\"Latest\": {\"ProductVersion\": \"26.7.1\"}}]}")
        XCTAssertNil(noXProtect.isXProtectCurrent(5363, graceDays: 14, now: Self.now))
    }

    /// With the version but no release date the grace period cannot be measured, so an older
    /// XProtect is behind.
    func testAnOlderXProtectIsBehindWhenTheFeedGivesNoReleaseDate() throws {
        let undated = try feed(
            "{\"XProtectPlistConfigData\": {\"com.apple.XProtect\": \"5000\"}}")
        XCTAssertEqual(undated.isXProtectCurrent(5000, graceDays: 14, now: Self.now), true)
        XCTAssertEqual(undated.isXProtectCurrent(4999, graceDays: 14, now: Self.now), false)
    }
}
