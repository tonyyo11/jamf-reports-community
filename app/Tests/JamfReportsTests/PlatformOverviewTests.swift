import XCTest
@testable import JamfReports

/// The cross-platform overview reads the daily summaries alone: one platform per platform word
/// in the newest map, shares of the devices reporting a version, and nothing drawn where a
/// summary did not measure (absent, never 0).
final class PlatformOverviewTests: XCTestCase {
    private func day(
        _ date: String, _ os: [String: Int]?, models: [String: Int]? = nil,
        osCurrent: Double? = nil, p0: Int? = nil, mobile: MobileSummary? = nil
    ) -> DailySummary {
        DailySummary(
            date: date, totalDevices: 10, fileVaultPct: nil, compliancePct: nil, staleCount: nil,
            osCurrentPct: osCurrent, crowdstrikePct: nil, patchPct: nil, actionItemsP0: p0,
            mobile: mobile, osMajorCounts: os, modelFamilyCounts: models)
    }

    private func percents(_ platform: PlatformOverview.Platform, _ key: String) -> [Double] {
        platform.adoption.first { $0.key == key }?.points.map(\.percent) ?? []
    }

    func testPlatformsComeFromTheNewestMapMacOSFirst() throws {
        let overview = PlatformOverview.build([
            day("2026-11-20", ["visionOS 26": 1, "macOS 26": 3, "iPadOS 18": 2, "iOS 26": 4]),
        ])
        XCTAssertEqual(overview.platforms.map(\.name), ["macOS", "iOS", "iPadOS", "visionOS"])
        let mac = try XCTUnwrap(overview.platforms.first)
        XCTAssertEqual(mac.devices, 3)
        XCTAssertEqual(mac.versions.map(\.key), ["macOS 26"])
        XCTAssertEqual(mac.versions.first?.percent, 100)
    }

    func testSharesAreOfTheirPlatformAndNewestMajorFirst() throws {
        let overview = PlatformOverview.build([
            day("2026-11-20", ["macOS 26": 6, "macOS 15": 3, "macOS 9": 1, "iPadOS 18": 5]),
        ])
        let mac = try XCTUnwrap(overview.platforms.first)
        XCTAssertEqual(mac.versions.map(\.key), ["macOS 26", "macOS 15", "macOS 9"])
        XCTAssertEqual(mac.versions.map(\.percent), [60, 30, 10])
        XCTAssertEqual(overview.platforms[1].versions.map(\.percent), [100])
    }

    /// No map that day, or a map without this platform: no point. A major absent on a day the
    /// platform was measured is 0.
    func testThreeKindsOfMissing() throws {
        let overview = PlatformOverview.build([
            day("2026-11-01", ["macOS 15": 4, "iPadOS 18": 2]),
            day("2026-11-02", nil),
            day("2026-11-03", ["iPadOS 18": 2]),
            day("2026-11-04", ["macOS 26": 1, "macOS 15": 3, "iPadOS 18": 2]),
        ])
        let mac = try XCTUnwrap(overview.platforms.first { $0.isMac })
        let dates = try XCTUnwrap(mac.adoption.first?.points.map(\.date))
        XCTAssertEqual(dates.map { SummaryJSONParser.dateFormatter.string(from: $0) },
                       ["2026-11-01", "2026-11-04"])
        XCTAssertEqual(percents(mac, "macOS 26"), [0, 25])
        XCTAssertEqual(percents(mac, "macOS 15"), [100, 75])
        let iPad = try XCTUnwrap(overview.platforms.first { $0.name == "iPadOS" })
        XCTAssertEqual(percents(iPad, "iPadOS 18"), [100, 100, 100])
    }

    func testOlderMajorsPoolIntoOtherAndEachDaySumsTo100() throws {
        let map = ["macOS 26": 5, "macOS 15": 4, "macOS 14": 3, "macOS 13": 2, "macOS 12": 1,
                   "macOS 11": 1]
        let overview = PlatformOverview.build([
            day("2026-11-01", map.merging(["macOS 26": 1]) { $1 }), day("2026-11-08", map),
        ])
        let mac = try XCTUnwrap(overview.platforms.first)
        XCTAssertEqual(mac.adoption.map(\.key),
                       ["macOS 26", "macOS 15", "macOS 14", "macOS 13", "Other"])
        XCTAssertEqual(mac.versionsSeen, 6)
        XCTAssertEqual(mac.versionsPooled, 2)
        XCTAssertEqual(percents(mac, "Other").last ?? 0, 2.0 / 16 * 100, accuracy: 1e-9)
        for index in 0..<2 {
            let sum = mac.adoption.reduce(0) { $0 + $1.points[index].percent }
            XCTAssertEqual(sum, 100, accuracy: 1e-9)
        }
        // The bars end in one "macOS 12 or older" bar pooling the chart's Other majors.
        XCTAssertEqual(mac.versions.map(\.key),
                       ["macOS 26", "macOS 15", "macOS 14", "macOS 13", "Other"])
        XCTAssertEqual(mac.versions.map(\.orOlder), [nil, nil, nil, nil, "macOS 12"])
        XCTAssertEqual(mac.versions.last?.count, 2)
        XCTAssertEqual(mac.versions.last?.percent ?? 0, 2.0 / 16 * 100, accuracy: 1e-9)
    }

    func testThePooledBarFollowsTheChartsMajorsNotTheNewestDays() throws {
        // macOS 27 was seen earlier in the window, so 27, 26, 15 and 14 are drawn and the
        // newest day's 13 and 12 pool; 13 names the bar.
        let overview = PlatformOverview.build([
            day("2026-11-01", ["macOS 27": 1, "macOS 26": 1]),
            day("2026-11-08", ["macOS 26": 4, "macOS 15": 3, "macOS 14": 1, "macOS 13": 1,
                               "macOS 12": 1]),
        ])
        let mac = try XCTUnwrap(overview.platforms.first)
        XCTAssertEqual(mac.adoption.map(\.key),
                       ["macOS 27", "macOS 26", "macOS 15", "macOS 14", "Other"])
        XCTAssertEqual(mac.versions.map(\.key), ["macOS 26", "macOS 15", "macOS 14", "Other"])
        XCTAssertEqual(mac.versions.last?.orOlder, "macOS 13")
        XCTAssertEqual(mac.versions.last?.count, 2)
        XCTAssertEqual(mac.versions.map(\.percent).reduce(0, +), 100, accuracy: 1e-9)
    }

    func testFourMajorsNeedNoOther() throws {
        let overview = PlatformOverview.build([
            day("2026-11-01", ["iOS 26": 1, "iOS 18": 1, "iOS 17": 1, "iOS 16": 1]),
        ])
        let iOS = try XCTUnwrap(overview.platforms.first)
        XCTAssertEqual(iOS.adoption.count, 4)
        XCTAssertEqual(iOS.versionsPooled, 0)
    }

    func testTheWindowIsTwelveWeeksBeforeTheNewestDay() throws {
        let overview = PlatformOverview.build([
            day("2026-08-01", ["macOS 15": 1]),
            day("2026-09-01", ["macOS 15": 1]),
            day("2026-11-20", ["macOS 26": 1]),
        ])
        let mac = try XCTUnwrap(overview.platforms.first)
        XCTAssertEqual(mac.adoption.first?.points.count, 2)
    }

    /// Summaries are peer-writable: a count at or below 0 and a key with no major are skipped.
    func testBadKeysAndCountsAreIgnored() throws {
        let overview = PlatformOverview.build([
            day("2026-11-20", ["macOS 26": 3, "macOS 15": 0, "iOS 18": -4, "Unknown": 2,
                               "macOS beta": 1]),
        ])
        XCTAssertEqual(overview.platforms.map(\.name), ["macOS"])
        XCTAssertEqual(overview.platforms.first?.devices, 3)
    }

    /// A count past `maxSummaryNumber` is skipped like a bad one, so the sums cannot overflow
    /// for a summary built in memory that never passed the decoder's range check.
    func testCountsPastTheSummaryLimitAreIgnored() throws {
        let overview = PlatformOverview.build([
            day("2026-11-19", ["macOS 26": Int.max, "macOS 15": Int.max]),
            day("2026-11-20", ["macOS 26": Int.max, "macOS 15": 5, "iOS 26": Int.max]),
        ])
        XCTAssertEqual(overview.platforms.map(\.name), ["macOS"])
        let mac = try XCTUnwrap(overview.platforms.first)
        XCTAssertEqual(mac.devices, 5)
        XCTAssertEqual(mac.versions.map(\.key), ["macOS 15"])
        XCTAssertEqual(percents(mac, "macOS 15"), [100])
    }

    /// Peer-written Mac figures out of their range are left out, never shown: a family map of
    /// "Other" alone, a current-release share outside 0 to 100, a negative gap count.
    func testMacFiguresOutOfRangeAreLeftOut() throws {
        let cases: [([String: Int], Double, Int)] = [
            (["Other": 4], 100.5, -1), (["Other": 4, "Mac mini": 0], -2, Int.max),
        ]
        for (models, current, p0) in cases {
            let mac = try XCTUnwrap(PlatformOverview.build([
                day("2026-11-20", ["macOS 26": 2], models: models, osCurrent: current, p0: p0),
            ]).platforms.first)
            XCTAssertNil(mac.modelFamilies)
            XCTAssertNil(mac.onCurrentRelease)
            XCTAssertNil(mac.securityGaps)
        }
        let edges = try XCTUnwrap(PlatformOverview.build([
            day("2026-11-20", ["macOS 26": 2], models: ["Mac mini": 1], osCurrent: 0, p0: 0),
        ]).platforms.first)
        XCTAssertEqual(edges.modelFamilies, 1)
        XCTAssertEqual(edges.onCurrentRelease, 0)
        XCTAssertEqual(edges.securityGaps, 0)
    }

    func testNoMapOnTheNewestDayDrawsNothing() {
        XCTAssertTrue(PlatformOverview.build([]).isEmpty)
        XCTAssertTrue(PlatformOverview.build([
            day("2026-11-01", ["macOS 26": 1]), day("2026-11-02", nil),
        ]).isEmpty)
        XCTAssertTrue(PlatformOverview.build([day("2026-11-02", ["macOS 26": 0])]).isEmpty)
    }

    func testOneDayDrawsOnePointPerSeries() throws {
        let mac = try XCTUnwrap(PlatformOverview.build([day("2026-11-20", ["macOS 26": 2])])
            .platforms.first)
        XCTAssertEqual(mac.adoption.map(\.points.count), [1])
    }

    func testMacFiguresAreTheSummarysAndLeftOutWhenAbsent() throws {
        let measured = PlatformOverview.build([
            day("2026-11-20", ["macOS 26": 2, "iOS 18": 1],
                models: ["MacBook Air": 1, "Mac mini": 1, "Other": 3], osCurrent: 81.5, p0: 4),
        ])
        let mac = try XCTUnwrap(measured.platforms.first)
        XCTAssertEqual(mac.modelFamilies, 2)
        XCTAssertEqual(mac.onCurrentRelease, 81.5)
        XCTAssertEqual(mac.securityGaps, 4)
        let iOS = try XCTUnwrap(measured.platforms.last)
        XCTAssertNil(iOS.modelFamilies)
        XCTAssertNil(iOS.onCurrentRelease)
        XCTAssertNil(iOS.securityGaps)

        let bare = try XCTUnwrap(PlatformOverview.build([day("2026-11-20", ["macOS 26": 2])])
            .platforms.first)
        XCTAssertNil(bare.modelFamilies)
        XCTAssertNil(bare.onCurrentRelease)
        XCTAssertNil(bare.securityGaps)
    }

    /// The mobile figures cover every non-Mac device; they show only beside a mobile section.
    func testCombinedMobileFiguresNeedAMobilePlatform() {
        let mobile = MobileSummary(managed: 3, unmanaged: 0,
                                   osCurrent: .init(met: 2, of: 3), jailbroken: 1)
        let mixed = PlatformOverview.build([
            day("2026-11-20", ["macOS 26": 2, "iPadOS 18": 3], mobile: mobile),
        ])
        XCTAssertEqual(mixed.mobileOSCurrent, .init(met: 2, of: 3))
        XCTAssertEqual(mixed.mobileJailbroken, 1)
        let macs = PlatformOverview.build([day("2026-11-20", ["macOS 26": 2], mobile: mobile)])
        XCTAssertNil(macs.mobileOSCurrent)
        XCTAssertNil(macs.mobileJailbroken)
    }

    /// A School summary carries only `osMajorCounts` (with Macs, iPads and Apple TVs together)
    /// and the Mac `osCurrentPct`.
    func testASchoolSummaryWorks() throws {
        let overview = PlatformOverview.build([
            day("2026-11-20", ["macOS 15": 12, "iPadOS 18": 300, "tvOS 18": 4], osCurrent: 75),
        ])
        XCTAssertEqual(overview.platforms.map(\.name), ["macOS", "iPadOS", "tvOS"])
        XCTAssertEqual(overview.platforms.first?.onCurrentRelease, 75)
        XCTAssertNil(overview.platforms.first?.modelFamilies)
        XCTAssertNil(overview.mobileOSCurrent)
    }

    /// Demo mode draws moving lines from the demo fleet's own counts, never a workspace's.
    func testTheDemoOverviewHasHistory() throws {
        let overview = DemoData.platformOverview(for: DemoData.org.profile)
        let mac = try XCTUnwrap(overview.platforms.first)
        XCTAssertTrue(mac.isMac)
        XCTAssertEqual(mac.devices, DemoData.totalDevices)
        let newest = try XCTUnwrap(mac.adoption.first?.points)
        XCTAssertEqual(newest.count, 13)
        XCTAssertLessThan(try XCTUnwrap(newest.first?.percent), try XCTUnwrap(newest.last?.percent))
    }

    /// Every demo workspace's history ends on its own newest summary, one point per date.
    func testEveryDemoWorkspaceEndsOnItsNewestSummary() throws {
        for profile in DemoData.cliProfiles.map(\.name) + [DemoData.schoolWorkspace] {
            let summaries = DemoData.fleetSummaries(for: profile)
            let overview = DemoData.platformOverview(for: profile)
            let newest = try XCTUnwrap(summaries.last)
            for platform in overview.platforms {
                for series in platform.adoption {
                    let dates = series.points.map(\.date)
                    XCTAssertEqual(Set(dates).count, dates.count, profile)
                    XCTAssertEqual(dates.last, newest.parsedDate, profile)
                }
            }
            if let mac = overview.platforms.first(where: \.isMac) {
                XCTAssertEqual(mac.modelFamilies.map { _ in true }, newest.modelFamilyCounts.map { _ in true })
            }
        }
    }

    func testKeyParts() {
        XCTAssertEqual(PlatformOverview.parts("macOS 26")?.platform, "macOS")
        XCTAssertEqual(PlatformOverview.parts("Apple TV OS 18")?.platform, "Apple TV OS")
        XCTAssertEqual(PlatformOverview.parts("iOS 9")?.major, 9)
        XCTAssertNil(PlatformOverview.parts("macOS"))
        XCTAssertNil(PlatformOverview.parts("macOS 26.1"))
        XCTAssertNil(PlatformOverview.parts("Other"))
    }
}
