import XCTest
@testable import JamfReports

/// The Trends mobile metrics (mobile spec 4.1): read from each day's `mobile` object, offered by
/// the device types the history carries, and backfilled from same-day `mobile-devices-list`
/// snapshots for days summarized without them (4.3).
@MainActor
final class TrendStoreMobileMetricsTests: XCTestCase {

    private var root: URL!
    private var dataDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = GoldenFleetWorkspace.freshRoot()
        dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dataDir.appendingPathComponent(MobileFleetService.deviceKind),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func day(_ date: String, macs: Int, mobile: MobileSummary? = nil) -> DailySummary {
        DailySummary(
            date: date, totalDevices: macs, fileVaultPct: macs > 0 ? 90 : nil,
            compliancePct: nil, staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil,
            patchPct: nil, source: "jamf-cli", mobileDeviceCount: mobile.map(\.managed),
            mobile: mobile)
    }

    private let schoolMobile = MobileSummary(
        managed: 4, unmanaged: 0, supervised: .init(met: 3, of: 4), stale: 1)

    // MARK: - Metrics

    func testRawValuesPolaritiesAndUnitsFollowTheSpec() {
        let expected: [(TrendSeries.Metric, String, FleetInsightInput.Polarity, String)] = [
            (.mobileManaged, "mobileManaged", .neutral, ""),
            (.mobileOSCurrent, "mobileOSCurrent", .higherIsBetter, "%"),
            (.mobilePasscode, "mobilePasscode", .higherIsBetter, "%"),
            (.mobileSupervised, "mobileSupervised", .higherIsBetter, "%"),
            (.mobileDataProtection, "mobileDataProtection", .higherIsBetter, "%"),
            (.mobileStale, "mobileStale", .lowerIsBetter, ""),
            (.mobileJailbroken, "mobileJailbroken", .lowerIsBetter, ""),
        ]
        XCTAssertEqual(TrendSeries.Metric.mobileMetrics, expected.map(\.0))
        for (metric, raw, polarity, unit) in expected {
            XCTAssertEqual(metric.rawValue, raw)
            XCTAssertEqual(TrendSeries.Metric(rawValue: raw), metric)
            XCTAssertEqual(metric.polarity, polarity, raw)
            XCTAssertEqual(metric.unit, unit, raw)
            XCTAssertTrue(metric.displayLabel.localizedCaseInsensitiveContains("mobile"))
        }
        XCTAssertTrue(TrendSeries.Metric.allCases.allSatisfy { !$0.isMobile },
                      "the Overview's score cards are M4")
    }

    func testPointsReadTheMobileObjectAndSkipAnAbsentPair() {
        let store = TrendStore(summaries: [day("2026-10-19", macs: 0, mobile: schoolMobile)])
        XCTAssertEqual(store.points(metric: .mobileSupervised).map(\.value), [75])
        XCTAssertEqual(store.points(metric: .mobileStale).map(\.value), [1])
        XCTAssertEqual(store.points(metric: .mobileManaged).map(\.value), [4])
        XCTAssertTrue(store.points(metric: .mobilePasscode).isEmpty, "School carries no passcode")
    }

    // MARK: - Offered by composition

    func testAMacOnlyHistoryOffersNoMobileMetric() {
        let store = TrendStore(summaries: [day("2026-10-19", macs: 10)])
        XCTAssertTrue(TrendSeries.Metric.mobileMetrics.allSatisfy { !store.offers($0) })
        XCTAssertTrue(store.offers(.fileVault))
        XCTAssertTrue(store.offers(.managedDevices))
    }

    func testAMobileOnlyHistoryOffersNoMacMetricAndOnlyTheMobileFiguresItCarries() {
        let store = TrendStore(summaries: [day("2026-10-19", macs: 0, mobile: schoolMobile)])
        for mac in [TrendSeries.Metric.fileVault, .stale, .osCurrent, .patch] {
            XCTAssertFalse(store.offers(mac), mac.rawValue)
        }
        XCTAssertFalse(store.offers(.managedDevices), "no Macs, so no Managed Computers figure")
        XCTAssertEqual(TrendSeries.Metric.mobileMetrics.filter(store.offers),
                       [.mobileManaged, .mobileSupervised, .mobileStale])
    }

    func testAMixedHistoryOffersBothAndAnEmptyOneKeepsTheMacMetrics() {
        let mixed = TrendStore(summaries: [
            day("2026-10-18", macs: 10), day("2026-10-19", macs: 10, mobile: schoolMobile),
        ])
        XCTAssertTrue(mixed.offers(.fileVault))
        XCTAssertTrue(mixed.offers(.mobileSupervised))
        let empty = TrendStore(summaries: [])
        XCTAssertTrue(empty.offers(.fileVault), "a load in flight keeps the selection")
        XCTAssertFalse(empty.offers(.mobileManaged))
    }

    func testASchoolWorkspaceListsOnlyTheMobileFiguresSchoolCanFill() {
        let school = TrendSeries.Metric.schoolMetrics.filter(\.isMobile)
        XCTAssertEqual(school, [.mobileManaged, .mobileSupervised, .mobileStale, .mobileOSCurrent])
    }

    // MARK: - Backfill

    private func instant(_ day: String, hour: Double) throws -> Date {
        let midnight = try XCTUnwrap(SummaryJSONParser.dateFormatter.date(from: day))
        return midnight.addingTimeInterval(hour * 3600)
    }

    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        return formatter.string(from: date)
    }

    /// One managed device per `passcode` value, all reporting an iOS version the feed tracks.
    private func writeSnapshot(
        passcode: [Bool], at date: Date, suffix: String = ""
    ) throws {
        let rows: [[String: Any]] = passcode.enumerated().map { index, compliant in
            ["mobileDeviceId": "\(index)", "deviceType": "iOS",
             "general": ["managed": true, "supervised": true, "osVersion": "18.7.8",
                         "lastInventoryUpdateDate": "2026-10-01T09:00:00.000Z"],
             "security": ["passcodeCompliant": compliant]]
        }
        let url = dataDir.appendingPathComponent(MobileFleetService.deviceKind)
            .appendingPathComponent("\(MobileFleetService.deviceKind)_\(stamp(date))\(suffix).json")
        try JSONSerialization.data(withJSONObject: rows).write(to: url)
    }

    private func backfill(_ summaries: [DailySummary]) -> [String: MobileSummary] {
        let resolved = TrendStore.resolvingMobile(summaries, dataDir: dataDir, staleDays: 30)
        return Dictionary(uniqueKeysWithValues: resolved.compactMap { s in
            s.mobile.map { (s.date, $0) }
        })
    }

    func testADayTakesTheNewestSnapshotOfThatDayAndNeverOSCurrency() throws {
        let sofa = dataDir.appendingPathComponent("sofa", isDirectory: true)
        try FileManager.default.createDirectory(at: sofa, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: TestFixtures.dir("sofa").appendingPathComponent("ios_data_feed.json"),
            to: sofa.appendingPathComponent("ios_data_feed.json"))
        try writeSnapshot(passcode: [false, false], at: instant("2026-10-10", hour: 8))
        try writeSnapshot(passcode: [true, false], at: instant("2026-10-10", hour: 20))

        let figures = try XCTUnwrap(backfill([day("2026-10-10", macs: 5)])["2026-10-10"])
        XCTAssertEqual(figures.passcode, .init(met: 1, of: 2))
        XCTAssertNil(figures.osCurrent, "judged against today's feed it would read as behind")
        XCTAssertNil(figures.updateErrors)
        XCTAssertEqual(figures.stale, 0, "judged as of the snapshot's own stamp")
    }

    func testAFIFOSnapshotFillsNothingAndDoesNotBlock() throws {
        let kind = MobileFleetService.deviceKind
        let pipe = dataDir.appendingPathComponent(kind)
            .appendingPathComponent("\(kind)_\(stamp(try instant("2026-10-10", hour: 8))).json")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let done = expectation(description: "backfill returned")
        let dir: URL = dataDir
        let summary = day("2026-10-10", macs: 5)
        DispatchQueue.global().async {
            XCTAssertNil(TrendStore.resolvingMobile([summary], dataDir: dir, staleDays: 30)
                .first?.mobile)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testOnlyASameDaySnapshotFillsADay() throws {
        try writeSnapshot(passcode: [true], at: instant("2026-10-09", hour: 12))
        try writeSnapshot(passcode: [true], at: instant("2026-10-11", hour: 0.5))
        XCTAssertTrue(backfill([day("2026-10-10", macs: 5)]).isEmpty)
    }

    func testAConflictCopyIsSkippedAndARecordedObjectWins() throws {
        try writeSnapshot(passcode: [true], at: instant("2026-10-10", hour: 9))
        try writeSnapshot(passcode: [false], at: instant("2026-10-10", hour: 21), suffix: " 2")
        let recorded = MobileSummary(managed: 9, unmanaged: 0)
        let resolved = backfill([day("2026-10-10", macs: 5), day("2026-10-11", macs: 5,
                                                                   mobile: recorded)])
        XCTAssertEqual(resolved["2026-10-10"]?.passcode, .init(met: 1, of: 1))
        XCTAssertEqual(resolved["2026-10-11"], recorded)
    }

    func testOnlyTheNewestTwentyOneDaysAreRead() throws {
        var summaries: [DailySummary] = []
        for offset in 0..<22 {
            let date = try instant("2026-09-01", hour: 12 + Double(offset) * 24)
            try writeSnapshot(passcode: [true], at: date)
            summaries.append(day(SummaryJSONParser.dateFormatter.string(from: date), macs: 5))
        }
        let filled = backfill(summaries)
        XCTAssertEqual(filled.count, TrendStore.mobileBackfillMaxDays)
        XCTAssertNil(filled["2026-09-01"], "the oldest day stays absent")
    }
}
