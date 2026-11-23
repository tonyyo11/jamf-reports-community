import XCTest
@testable import JamfReports

/// The Jamf School daily summary (`ReportEngine.writeSchoolSummary`): written from the newest
/// `school-devices` snapshot, in jamf-cli's flattened row shape, when a collect landed it.
@MainActor
final class SchoolSummaryTests: XCTestCase {
    private nonisolated(unsafe) var root: URL!
    private nonisolated(unsafe) var dataDir: URL!
    private nonisolated(unsafe) var summariesDir: URL!
    private let landed: Set<String> = [SchoolFleetService.devicesKind]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("school-summary-\(UUID().uuidString)", isDirectory: true)
        dataDir = root.appendingPathComponent("data", isDirectory: true)
        summariesDir = root.appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func day(_ text: String) -> Date { DateParser().parse(text)! }

    private func writeDevices(_ rows: [[String: Any]], stamp: String = "20261019T080000") throws {
        try SchoolRows.write(
            rows, kind: SchoolFleetService.devicesKind, into: dataDir, stamp: stamp)
    }

    @discardableResult
    private func write(
        landed kinds: Set<String>? = nil, staleDays: Int = 30, at now: String = "2026-10-19 09:00:00"
    ) -> ReportEngine.SummaryEmitOutcome {
        ReportEngine.writeSchoolSummary(
            dataDir: dataDir, summariesDir: summariesDir, landedKinds: kinds ?? landed,
            staleDays: staleDays, day: day(now), onLine: { _ in })
    }

    private func summary(_ date: String = "2026-10-19") throws -> DailySummary {
        let file = summariesDir.appendingPathComponent("summary_\(date).json")
        return try SummaryJSONParser.decode(Data(contentsOf: file))
    }

    private let fleet: [[String: Any]] = [
        SchoolRows.device(1, [
            "name": "Lab Mac 01", "model": "MacBook Air", "os": "macOS 14.3",
            "isSupervised": false, "lastCheckin": "2026-10-18 09:00:00",
        ]),
        SchoolRows.device(2, [
            "name": "Lab Mac 02", "model": "MacBook Air", "os": "macOS 26.6.2",
            "isSupervised": false, "lastCheckin": "2026-08-01 09:00:00",
        ]),
        SchoolRows.device(3, ["name": "Cart iPad 01", "lastCheckin": "2026-10-19 08:00:00"]),
        SchoolRows.device(4, [
            "name": "Cart iPad 02", "model": "iPad (9th generation)", "os": "iPadOS 18.1",
            "lastCheckin": "2026-07-01 09:00:00",
        ]),
        SchoolRows.device(5, [
            "name": "Office iPhone", "os": "iOS 27.0", "lastCheckin": "2026-10-17 09:00:00",
        ], omitting: ["isSupervised"]),
        SchoolRows.device(6, ["name": "Front Desk TV", "os": "tvOS 18.0"],
                          omitting: ["isSupervised", "lastCheckin"]),
        SchoolRows.device(7, [
            "name": "Retired iPad", "os": "iPadOS 17.0", "inTrash": true,
            "lastCheckin": "2025-01-01 09:00:00",
        ], omitting: ["isManaged", "isSupervised"]),
    ]

    func testCollectThatLandedDevicesWritesCountsAndLeavesMacSecurityNil() throws {
        try writeDevices(fleet)
        XCTAssertEqual(write(), .wrote)

        let s = try summary()
        XCTAssertEqual(s.totalDevices, 2, "Macs only")
        XCTAssertEqual(s.mobileDeviceCount, 4, "iPadOS, iOS and tvOS; the trashed iPad is left out")
        XCTAssertEqual(s.staleCount, 1, "Mac 02 only; the stale iPad is not counted")
        XCTAssertEqual(s.source, "jamf-cli")
        XCTAssertEqual(s.collectionSources, [SchoolFleetService.devicesKind: "live"])
        let macFigures: [Double?] = [
            s.fileVaultPct, s.compliancePct, s.osCurrentPct, s.crowdstrikePct, s.patchPct,
            s.sipPct, s.firewallPct, s.gatekeeperPct, s.secureBootPct, s.bootstrapPct,
            s.xprotectPct, s.securityScore,
        ]
        XCTAssertTrue(macFigures.allSatisfy { $0 == nil }, "unmeasured is nil, never 0")
    }

    func testRunThatLandedNoDevicesWritesNothing() throws {
        try writeDevices(fleet)
        XCTAssertEqual(write(landed: ["school-users"]), .nothingToSummarize)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: summariesDir.appendingPathComponent("summary_2026-10-19.json").path),
            "a cached snapshot is not dated today")
    }

    /// A devices source that landed empty is a warning, not a `[partial]`: the source did land.
    func testLandedEmptyDeviceListWarnsAndWritesNothing() throws {
        try writeDevices([])
        let lines = LineBox()
        let outcome = ReportEngine.writeSchoolSummary(
            dataDir: dataDir, summariesDir: summariesDir, landedKinds: landed, staleDays: 30,
            day: day("2026-10-19 09:00:00"), onLine: lines.append)

        XCTAssertEqual(outcome, .nothingToSummarize)
        let warns = lines.texts.filter { $0.hasPrefix("[warn] Jamf School returned 0 devices") }
        XCTAssertEqual(warns.count, 1, "\(lines.texts)")
        XCTAssertFalse(lines.texts.contains { $0.contains("[partial]") })
    }

    func testZeroDevicesNeedAttentionAndALandedFleetClearsIt() throws {
        func changes() -> [AttentionCode: AttentionChange] {
            let log = AttentionLog(profile: "p", usesAppRecord: false)
            AttentionLog.$current.withValue(log) { write() }
            return log.changes
        }
        try writeDevices([])
        XCTAssertEqual(changes(), [.schoolZeroDevices: .raised("Jamf School returned 0 devices")])
        try writeDevices(fleet, stamp: "20261019T090000")
        XCTAssertEqual(changes(), [.schoolZeroDevices: .cleared])
        XCTAssertEqual({ () -> [AttentionCode: AttentionChange] in
            let log = AttentionLog(profile: "p", usesAppRecord: false)
            AttentionLog.$current.withValue(log) { write(landed: []) }
            return log.changes
        }(), [:], "a run that did not land the devices did not check")
    }

    func testRunThatLandedNoDevicesLeavesTodaysSummary() throws {
        try writeDevices(fleet)
        write()
        try writeDevices([], stamp: "20261019T100000")
        XCTAssertEqual(write(landed: [], at: "2026-10-19 10:00:00"), .nothingToSummarize)
        XCTAssertEqual(try summary().totalDevices, 2)
    }

    func testLaterSameDayCollectRebuildsTheSummary() throws {
        try writeDevices(fleet)
        write()
        try writeDevices([
            SchoolRows.device(3, ["name": "Cart iPad 01", "lastCheckin": "2026-10-19 11:00:00"]),
        ], stamp: "20261019T120000")
        XCTAssertEqual(write(at: "2026-10-19 12:00:00"), .wrote)

        let s = try summary()
        XCTAssertEqual(s.totalDevices, 0)
        XCTAssertEqual(s.mobileDeviceCount, 1)
        XCTAssertNil(s.staleCount, "no Macs: mobile staleness is not recorded")
    }

    func testIPadOnlyFleetRecordsNoStaleCountEvenWhenIPadsAreStale() throws {
        try writeDevices([
            SchoolRows.device(3, [
                "name": "Cart iPad 01", "os": "iPadOS 18.1", "lastCheckin": "2026-01-01 09:00:00",
            ], omitting: ["isManaged", "isSupervised"]),
        ])
        write()
        let s = try summary()
        XCTAssertEqual(s.totalDevices, 0)
        XCTAssertNil(s.staleCount)
        XCTAssertTrue(TrendStore(summaries: [s], range: .all).points(metric: .stale).isEmpty,
                      "Trends has no stale series to offer")
    }

    func testStaleIsMoreThanTheThresholdInWholeDays() throws {
        try writeDevices([
            SchoolRows.device(1, [
                "name": "Lab Mac", "os": "macOS 14.3", "lastCheckin": "2026-10-01 09:00:00",
            ], omitting: ["isSupervised"]),
        ])
        write(staleDays: 30, at: "2026-10-31 09:00:00")
        XCTAssertEqual(try summary("2026-10-31").staleCount, 0, "exactly 30 days is not stale")
        write(staleDays: 29, at: "2026-10-31 09:00:00")
        XCTAssertEqual(try summary("2026-10-31").staleCount, 1)
    }

    func testMacOnlyFleetRecordsNoMobileCount() throws {
        try writeDevices([
            SchoolRows.device(1, ["name": "Lab Mac", "os": "macOS 14.3"],
                              omitting: ["isManaged", "isSupervised", "lastCheckin"]),
        ])
        write()
        let s = try summary()
        XCTAssertEqual(s.totalDevices, 1)
        XCTAssertNil(s.mobileDeviceCount)
    }

    func testEmptyFleetWritesNothing() throws {
        try writeDevices([
            SchoolRows.device(7, ["name": "Retired iPad", "os": "iPadOS 17.0", "inTrash": true],
                              omitting: ["isManaged", "isSupervised", "lastCheckin"]),
        ])
        XCTAssertEqual(write(), .nothingToSummarize)
        XCTAssertFalse(FileManager.default.fileExists(atPath: summariesDir.path))
    }

    // MARK: - Trends

    func testSchoolTrendsOffersOnlyTheMetricsASchoolSummaryMeasures() throws {
        try writeDevices(fleet)
        write()
        let store = TrendStore(summaries: [try summary()], range: .all)

        XCTAssertEqual(TrendSeries.Metric.schoolMetrics, [
            .managedDevices, .stale, .osCurrent,
            .mobileManaged, .mobileSupervised, .mobileStale, .mobileOSCurrent,
        ])
        // OS currency needs a cached SOFA feed, which this workspace has not.
        for metric in TrendSeries.Metric.schoolMetrics where ![.osCurrent, .mobileOSCurrent]
            .contains(metric) {
            XCTAssertFalse(store.points(metric: metric).isEmpty, "\(metric.rawValue)")
        }
        let others = (TrendSeries.Metric.allCases + TrendSeries.Metric.mobileMetrics).filter {
            !TrendSeries.Metric.schoolMetrics.contains($0) && $0 != .activeDevices
        }
        for metric in others {
            XCTAssertTrue(store.points(metric: metric).isEmpty, "\(metric.rawValue)")
        }
    }

    /// Managed Computers counts Macs only, so an iPad-only day is counted by the mobile metric.
    func testIPadOnlyDayIsCountedAsMobileNotAsComputers() throws {
        try writeDevices([
            SchoolRows.device(3, ["name": "Cart iPad 01"],
                              omitting: ["isSupervised", "lastCheckin"]),
            SchoolRows.device(4, ["name": "Cart iPad 02", "os": "iPadOS 27.0.1"],
                              omitting: ["isSupervised", "lastCheckin"]),
        ])
        write()
        let store = TrendStore(summaries: [try summary()], range: .all)
        XCTAssertTrue(store.points(metric: .managedDevices).isEmpty)
        XCTAssertEqual(store.points(metric: .mobileManaged).map(\.value), [2])
    }

    private func cacheSOFA() throws {
        let sofa = dataDir.appendingPathComponent("sofa", isDirectory: true)
        try FileManager.default.createDirectory(at: sofa, withIntermediateDirectories: true)
        for name in ["macos_data_feed.json", "ios_data_feed.json"] {
            try FileManager.default.copyItem(
                at: TestFixtures.dir("sofa").appendingPathComponent(name),
                to: sofa.appendingPathComponent(name))
        }
    }

    /// Macs fill the Mac fields and everything else the `mobile` object: nothing is counted
    /// across the two. School rows carry no passcode, data protection, Activation Lock or
    /// jailbreak field, so those are absent, never 0.
    func testAMixedFleetRecordsMacAndMobileFiguresApart() throws {
        try writeDevices(fleet)
        write()
        let s = try summary()
        XCTAssertEqual(s.totalDevices, 2)
        XCTAssertEqual(s.staleCount, 1)
        let mobile = try XCTUnwrap(s.mobile)
        XCTAssertEqual(mobile.managed, 4, "the trashed iPad is left out")
        XCTAssertEqual(mobile.unmanaged, 0)
        XCTAssertEqual(mobile.supervised, .init(met: 2, of: 2), "the iPhone reports no flag")
        XCTAssertEqual(mobile.stale, 1, "Cart iPad 02; the TV has no check-in")
        XCTAssertNil(mobile.osCurrent, "no SOFA feed cached")
        XCTAssertNil(s.osCurrentPct)
        for absent in [mobile.passcode, mobile.dataProtection, mobile.activationLock] {
            XCTAssertNil(absent)
        }
        XCTAssertNil(mobile.jailbroken)
        XCTAssertNil(mobile.updateErrors)
    }

    /// Mac OS currency is the Pro definition against the macOS feed (an untracked major is not
    /// current); mobile OS currency is over the iOS and iPadOS devices whose major the iOS feed
    /// covers (27 is untracked, tvOS is never judged).
    func testOSCurrencyIsJudgedPerTypeAgainstItsOwnFeed() throws {
        try writeDevices(fleet)
        try cacheSOFA()
        write()
        let s = try summary()
        XCTAssertEqual(s.osCurrentPct, 50.0, "26.6.2 is current, 14.3 is a major SOFA drops")
        XCTAssertEqual(s.mobile?.osCurrent, .init(met: 0, of: 1), "only iPadOS 18.1 is judged")
    }

    func testAMacOnlyFleetWritesNoMobileObject() throws {
        try writeDevices([
            SchoolRows.device(1, [
                "name": "Lab Mac 01", "os": "macOS 26.6.2", "lastCheckin": "2026-10-18 09:00:00",
            ]),
        ])
        write()
        let s = try summary()
        XCTAssertEqual(s.totalDevices, 1)
        XCTAssertNil(s.mobileDeviceCount)
        XCTAssertNil(s.mobile)
    }

    func testAMobileOnlyFleetWritesNoMacFigures() throws {
        try writeDevices([
            SchoolRows.device(3, [
                "name": "Cart iPad 01", "os": "iPadOS 18.1", "isManaged": false,
                "lastCheckin": "2026-10-18 09:00:00",
            ], omitting: ["isSupervised"]),
        ])
        try cacheSOFA()
        write()
        let s = try summary()
        XCTAssertEqual(s.totalDevices, 0)
        XCTAssertNil(s.staleCount)
        XCTAssertNil(s.osCurrentPct)
        XCTAssertEqual(s.mobile?.managed, 0)
        XCTAssertEqual(s.mobile?.unmanaged, 1)
        XCTAssertNil(s.mobile?.supervised, "supervision is counted over managed devices")
        XCTAssertEqual(s.mobile?.stale, 0)
    }

    @MainActor
    func testAJamfSchoolWorkspaceKeepsTrendsAndOffersSchoolMetrics() {
        XCTAssertTrue(Tab.schoolTabs.contains(.trends))
        let store = WorkspaceStore(demoMode: false)
        store.profiles = [
            JamfCLIProfile(name: "campus", url: "", schedules: 0, status: .ok, product: .school),
            JamfCLIProfile(name: "prod", url: "", schedules: 0, status: .ok, product: .pro),
        ]
        store.profile = "campus"
        XCTAssertEqual(store.availableMetrics, TrendSeries.Metric.schoolMetrics)
        store.profile = "prod"
        XCTAssertTrue(store.availableMetrics.contains(.fileVault))
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var append: @Sendable (CLIBridge.LogLine) -> Void {
        { line in
            self.lock.lock(); defer { self.lock.unlock() }
            self.lines.append(line.text)
        }
    }

    var texts: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
