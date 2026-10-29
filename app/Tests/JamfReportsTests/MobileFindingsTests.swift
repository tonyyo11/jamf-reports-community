import XCTest
@testable import JamfReports

/// The Health Audit's Mobile Devices findings, the Mobile Devices filters and the HTML
/// report's mobile "Needs attention" lines (mobile spec 5): one rule per finding, read from
/// the real `mobile-devices-list` row shape, so the card, the filter and the summary count the
/// same devices.
final class MobileFindingsTests: XCTestCase {

    private var root: URL!
    private var dataDir: URL!

    /// A fixed "now" that keeps an hour clear of a day boundary from the recent inventory dates.
    private let now = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z") ?? Date()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = GoldenFleetWorkspace.freshRoot()
        dataDir = root.appendingPathComponent("jamf-cli-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func fixtureRows() throws -> [[String: Any]] {
        let dir = TestFixtures.dir("jamf-cli-data-mobile-sections/mobile-devices-list")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil).first)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
    }

    /// The dummy tenant's six devices (iOS 7 and 8, all managed, all inventoried in 2020), with
    /// states the rules tell apart:
    /// 1 current OS, 2 behind and serial of the scan's iPad, 3 unmanaged and data protection off,
    /// 4 jailbroken on an untracked major, 5 behind with no passcode compliance, 6 reports no
    /// SECURITY section and no OS. Devices 1, 2, 3 and 5 were inventoried yesterday; 4 and 6
    /// keep the fixture's 2020 date.
    private func rows() throws -> [[String: Any]] {
        let recent = "2026-10-18T10:00:00.000Z"
        return try fixtureRows().map { row in
            var row = row
            var general = row["general"] as? [String: Any] ?? [:]
            var hardware = row["hardware"] as? [String: Any] ?? [:]
            switch row["mobileDeviceId"] as? String {
            case "1": general["osVersion"] = "18.7.8"; general["lastInventoryUpdateDate"] = recent
            case "2":
                general["osVersion"] = "18.1"; general["lastInventoryUpdateDate"] = recent
                hardware["serialNumber"] = "TEST-IPAD0101"
            case "3":
                general["osVersion"] = "26.5"; general["managed"] = false
                general["lastInventoryUpdateDate"] = recent
            case "4": general["osVersion"] = "17.5"
            case "5": general["osVersion"] = "18.2"; general["lastInventoryUpdateDate"] = recent
            case "6": general["osVersion"] = NSNull(); row["security"] = NSNull()
            default: break
            }
            row["general"] = general
            row["hardware"] = hardware
            return row
        }
    }

    private func write(_ rows: [[String: Any]], scan: Bool = false) throws {
        try GoldenFleetWorkspace.writeJSON(
            rows, to: dataDir.appendingPathComponent(
                "mobile-devices-list/mobile-devices-list_2026-10-18T120000000000.json"))
        try FileManager.default.createDirectory(
            at: dataDir.appendingPathComponent("sofa"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: TestFixtures.dir("sofa/ios_data_feed.json"),
            to: dataDir.appendingPathComponent("sofa/ios_data_feed.json"))
        if scan {
            try FileManager.default.createDirectory(
                at: dataDir.appendingPathComponent("update-device-failures"),
                withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: TestFixtures.dir(
                    "jamf-cli-data/update-device-failures/update-device-failures.json"),
                to: dataDir.appendingPathComponent(
                    "update-device-failures/update-device-failures_2026-10-18T120000000000.json"))
        }
    }

    private func loaded(scan: Bool = true) throws
        -> (MobileFleetService.Snapshot, MobileFinding.Context) {
        try write(try rows(), scan: scan)
        let snapshot = MobileFleetService.load(dataDir: dataDir)
        return (snapshot, snapshot.findingContext(staleDays: 30, now: now))
    }

    private func finding(_ f: MobileFinding, in list: [AuditFinding]) -> AuditFinding? {
        list.first { $0.mobileFilter == f.rawValue }
    }

    // MARK: - Each finding

    func testEachFindingCountsTheDevicesThatReportTheFieldAndShowIt() throws {
        let (snapshot, context) = try loaded()
        let counts = snapshot.findingCounts(context)
        XCTAssertEqual(counts[.jailbreak], 1, "device 4")
        XCTAssertEqual(counts[.unmanaged], 1, "device 3")
        XCTAssertEqual(counts[.passcode], 2, "devices 2 and 5; 6 reports no SECURITY")
        XCTAssertEqual(counts[.dataProtection], 1, "device 3")
        XCTAssertEqual(counts[.osBehind], 2, "18.1 and 18.2; 17 and 7 are untracked majors")
        XCTAssertEqual(counts[.updateErrors], 1, "the scan's iPad serial is device 2's")
        XCTAssertEqual(counts[.stale], 2, "devices 4 and 6 keep their 2020 inventory date")
    }

    func testTheCardCarriesSeverityNameRecommendationAndTheDevicesBehindEachCount() throws {
        let (snapshot, context) = try loaded()
        let list = mobileDevicesFindings(snapshot, context: context)
        XCTAssertEqual(list.count, 7)
        XCTAssertEqual(list.map(\.category), Array(repeating: "Mobile devices", count: 7))
        let jailbreak = try XCTUnwrap(finding(.jailbreak, in: list))
        XCTAssertEqual(jailbreak.severity, "CRITICAL")
        XCTAssertEqual(jailbreak.devices.count, 1)
        XCTAssertTrue(jailbreak.devices[0].hasSuffix("(CA44E17060A3)"), "\(jailbreak.devices)")
        XCTAssertEqual(finding(.stale, in: list)?.severity, "INFO")
        XCTAssertEqual(finding(.stale, in: list)?.name,
                       "No inventory update in more than 30 days")
        XCTAssertEqual(finding(.osBehind, in: list)?.severity, "WARNING")
        let updateErrors = try XCTUnwrap(finding(.updateErrors, in: list))
        XCTAssertEqual(updateErrors.devices.count, 1)
        XCTAssertTrue(updateErrors.devices[0].hasSuffix("(TEST-IPAD0101)"))
        XCTAssertTrue(list.allSatisfy { !$0.recommendation.isEmpty })
        XCTAssertEqual(list.map(\.deviceNoun), Array(repeating: "Devices", count: 7))
    }

    /// One calculator: the card's count, the number of devices the filter lists and the figure
    /// the daily summary writes are the same number for every finding.
    func testTheCardTheFilterAndTheSummaryCountTheSameDevices() throws {
        let (snapshot, context) = try loaded()
        let list = mobileDevicesFindings(snapshot, context: context)
        let scan = try Data(contentsOf: dataDir.appendingPathComponent(
            "update-device-failures/update-device-failures_2026-10-18T120000000000.json"))
        let data = try Data(contentsOf: try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: dataDir.appendingPathComponent("mobile-devices-list"),
                includingPropertiesForKeys: nil).first))
        let summary = try XCTUnwrap(MobileSummary.fromMobileDevicesList(
            data, latestByMajor: context.latestByMajor, staleDays: context.staleDays, now: now,
            updateErrors: ReportEngine.mobileUpdateErrorCount(scan)))
        for kind in MobileFinding.allCases {
            let card = try XCTUnwrap(finding(kind, in: list)).affected
            let filtered = snapshot.devices(
                snapshot.richDevices, affectedBy: kind, context: context).count
            XCTAssertEqual(card, filtered, "\(kind) card vs filter")
            XCTAssertEqual(card, kind.count(in: summary), "\(kind) card vs summary")
        }
    }

    // MARK: - Absent is not failing

    func testADeviceThatDoesNotReportAFieldIsNeverInItsFilter() throws {
        let (snapshot, context) = try loaded()
        let ids = { (kind: MobileFinding) in
            snapshot.devices(snapshot.richDevices, affectedBy: kind, context: context)
                .compactMap(\.mobileDeviceId)
        }
        for kind in [MobileFinding.jailbreak, .passcode, .dataProtection, .osBehind] {
            XCTAssertFalse(ids(kind).contains("6"), "\(kind): device 6 reports nothing for it")
        }
        XCTAssertEqual(Set(ids(.stale)), ["4", "6"], "6's general section still dates it")
    }

    func testAFindingNoDeviceReportsIsLeftOutNotShownAsZero() throws {
        let stripped = try rows().map { row -> [String: Any] in
            var row = row
            row["security"] = NSNull()
            return row
        }
        try write(stripped)
        let snapshot = MobileFleetService.load(dataDir: dataDir)
        let list = mobileDevicesFindings(
            snapshot, context: snapshot.findingContext(staleDays: 30, now: now))
        XCTAssertNil(finding(.jailbreak, in: list))
        XCTAssertNil(finding(.passcode, in: list))
        XCTAssertNil(finding(.dataProtection, in: list))
        XCTAssertNil(finding(.updateErrors, in: list), "no scan has run")
        XCTAssertNotNil(finding(.unmanaged, in: list), "GENERAL still reports management")
        XCTAssertEqual(finding(.unmanaged, in: list)?.affected, 1)
    }

    func testAFeedWithNoIOSMajorsLeavesOSBehindOut() throws {
        try write(try rows(), scan: true)
        try FileManager.default.removeItem(at: dataDir.appendingPathComponent("sofa"))
        let snapshot = MobileFleetService.load(dataDir: dataDir)
        let list = mobileDevicesFindings(
            snapshot, context: snapshot.findingContext(staleDays: 30, now: now))
        XCTAssertNil(finding(.osBehind, in: list), "no feed: behind and current are unknown")
    }

    func testAScanWithNoMobileErrorRowsIsOKNotMissing() throws {
        try write(try rows())
        let dir = dataDir.appendingPathComponent("update-device-failures")
        try GoldenFleetWorkspace.writeJSON(
            [["total": 1, "status_summary": [], "error_devices": [[
                "name": "Mac", "serial": "C02X", "device_type": "COMPUTER", "os_version": "26.0",
                "username": "u", "status": "FAILED", "product_key": "k", "updated": "2026-10-18",
            ]], "failed_plans": NSNull()] as [String: Any]],
            to: dir.appendingPathComponent("update-device-failures_2026-10-18T120000000000.json"))
        let snapshot = MobileFleetService.load(dataDir: dataDir)
        let list = mobileDevicesFindings(
            snapshot, context: snapshot.findingContext(staleDays: 30, now: now))
        XCTAssertEqual(finding(.updateErrors, in: list)?.affected, 0)
        XCTAssertEqual(finding(.updateErrors, in: list)?.severity, "OK")
    }

    // MARK: - Hidden

    func testNoMobileDevicesGiveNoFindings() throws {
        XCTAssertTrue(mobileDevicesFindings(
            .empty, context: MobileFinding.Context(staleDays: 30, now: now)).isEmpty)
        try write([])
        let snapshot = MobileFleetService.load(dataDir: dataDir)
        XCTAssertEqual(snapshot.totalDevices, 0)
        XCTAssertTrue(mobileDevicesFindings(
            snapshot, context: snapshot.findingContext(staleDays: 30, now: now)).isEmpty)
    }

    // MARK: - Change against the previous summary

    func testTheChangeComparesWithTheNewestEarlierSummaryThatCarriesMobileFigures() throws {
        let (snapshot, context) = try loaded()
        func summary(_ day: String, jailbroken: Int?, stale: Int?, mobile: Bool = true)
            -> DailySummary {
            ReportEngine.mobileOnlySummary(
                date: day, mobileDeviceCount: 6,
                mobile: mobile ? MobileSummary(
                    managed: 6, unmanaged: 0, stale: stale, jailbroken: jailbroken) : nil,
                collectionSources: nil, collectedByHost: nil)
        }
        let summaries = [
            summary("2026-10-16", jailbroken: 5, stale: 9),
            summary("2026-10-17", jailbroken: 3, stale: 2),
            summary("2026-10-18", jailbroken: 0, stale: 0, mobile: false),
            summary("2026-10-19", jailbroken: 1, stale: 2),
        ]
        let previous = try XCTUnwrap(MobileFinding.previous(in: summaries, before: "2026-10-19"))
        XCTAssertEqual(previous.date, "2026-10-17", "10-18 has no mobile figures; 10-19 is today")
        let list = mobileDevicesFindings(snapshot, context: context, previous: previous)
        XCTAssertEqual(finding(.jailbreak, in: list)?.change, "2 fewer than on 2026-10-17")
        XCTAssertEqual(finding(.stale, in: list)?.change, "No change since 2026-10-17")
        XCTAssertNil(finding(.passcode, in: list)?.change,
                     "the earlier summary has no passcode share: no comparison")
        XCTAssertEqual(MobileFinding.changeText(current: 4, previous: 1, since: "d"),
                       "3 more than on d")
        XCTAssertNil(MobileFinding.previous(in: summaries, before: "2026-10-16"))
        XCTAssertNil(finding(.jailbreak, in: mobileDevicesFindings(snapshot, context: context))?
            .change)
    }

    // MARK: - Navigation and actions

    func testACountOpensMobileDevicesWithItsFilter() {
        for kind in MobileFinding.allCases {
            let info = kind.navigationUserInfo()
            XCTAssertEqual(info["tab"], Tab.mobileFleet.rawValue)
            XCTAssertEqual(
                MobileFinding.pending(from: info, destination: .mobileFleet), kind.rawValue)
            XCTAssertEqual(MobileFinding(rawValue: kind.rawValue), kind)
            XCTAssertNil(MobileFinding.pending(from: info, destination: .devices),
                         "a request is held only for Mobile Devices")
        }
        XCTAssertNil(MobileFinding.pending(from: ["tab": "mobileFleet"], destination: .mobileFleet))
    }

    func testEveryMobileFindingRoutesToMobileDevicesWhateverItsWords() throws {
        let (snapshot, context) = try loaded()
        let list = mobileDevicesFindings(snapshot, context: context)
        for item in list {
            XCTAssertEqual(auditActionDestination(for: item)?.tab, .mobileFleet, item.name)
        }
        XCTAssertEqual(
            auditActionDestination(for: AuditFinding(
                name: "Software update errors", affected: 1, category: "hygiene",
                recommendation: "", severity: "WARNING"))?.tab, .updates)
    }

    // MARK: - HTML "Needs attention"

    private func report() throws -> HtmlReport {
        HtmlReport(config: try ConfigLoader.loadFromString(""), dataDir: dataDir)
    }

    func testHTMLSentencesComeFromTheSummaryAndSkipAbsentSharesAndZeroCounts() throws {
        var inputs = HtmlReport.Inputs()
        inputs.summaries = [ReportEngine.mobileOnlySummary(
            date: "2026-10-19", mobileDeviceCount: 20,
            mobile: MobileSummary(
                managed: 18, unmanaged: 2, supervised: .init(met: 10, of: 18),
                passcode: .init(met: 15, of: 20), dataProtection: nil,
                osCurrent: .init(met: 19, of: 20), stale: 1, jailbroken: 0, updateErrors: nil),
            collectionSources: nil, collectedByHost: nil)]
        let items = try report().attentionItems(inputs, shown: [.mobileFleet])
            .filter { $0.text.contains("mobile") }
        XCTAssertEqual(items.map(\.text), [
            "2 mobile devices are not managed.",
            "5 mobile devices do not meet the passcode requirement.",
            "1 mobile device is behind the current iOS or iPadOS release.",
            "1 mobile device has not updated inventory for more than 30 days.",
        ], "no data protection share, no update scan and no jailbreak: no lines")
        XCTAssertTrue(items.allSatisfy { $0.anchor == "mobile-fleet" })
        let unlinked = try report().attentionItems(inputs, shown: [])
            .filter { $0.text.contains("mobile") }
        XCTAssertTrue(unlinked.allSatisfy { $0.anchor == nil }, "a link never points at nothing")
    }

    func testTheSentencesAndTheCardCountTheSameDevices() throws {
        let (snapshot, context) = try loaded()
        let data = try Data(contentsOf: try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: dataDir.appendingPathComponent("mobile-devices-list"),
                includingPropertiesForKeys: nil).first))
        let mobile = try XCTUnwrap(MobileSummary.fromMobileDevicesList(
            data, latestByMajor: context.latestByMajor, staleDays: 30, now: now,
            updateErrors: snapshot.updateErrors?.count))
        var inputs = HtmlReport.Inputs()
        inputs.summaries = [ReportEngine.mobileOnlySummary(
            date: "2026-10-19", mobileDeviceCount: 6, mobile: mobile,
            collectionSources: nil, collectedByHost: nil)]
        let lines = try report().attentionItems(inputs, shown: [.mobileFleet]).map(\.text)
        let card = mobileDevicesFindings(snapshot, context: context)
        for kind in MobileFinding.allCases {
            let count = try XCTUnwrap(finding(kind, in: card)).affected
            let expected = count > 0 ? kind.sentence(count: count, staleDays: 30) : nil
            XCTAssertEqual(lines.contains { $0 == expected }, expected != nil, "\(kind)")
        }
        XCTAssertFalse(lines.isEmpty)
    }

    func testASummaryWithoutMobileFiguresAddsNoMobileLines() throws {
        var inputs = HtmlReport.Inputs()
        inputs.summaries = [ReportEngine.mobileOnlySummary(
            date: "2026-10-19", mobileDeviceCount: 0, mobile: nil,
            collectionSources: nil, collectedByHost: nil)]
        XCTAssertTrue(try report().attentionItems(inputs, shown: [.mobileFleet])
            .allSatisfy { !$0.text.contains("mobile device") })
    }

    // MARK: - Update scan rows

    func testOneDeviceWithErrorsForTwoProductsIsOneDevice() throws {
        func row(_ product: String) -> [String: Any] {
            ["name": "iPad", "serial": "sn-1", "device_type": "MOBILE_DEVICE",
             "os_version": "18", "username": "u", "status": "FAILED", "product_key": product,
             "updated": "2026-10-18"]
        }
        let data = try JSONSerialization.data(withJSONObject: [[
            "total": 2, "status_summary": [], "error_devices": [row("a"), row("b")],
            "failed_plans": NSNull(),
        ] as [String: Any]])
        XCTAssertEqual(MobileFinding.updateErrors(in: data)?.count, 1)
        XCTAssertEqual(ReportEngine.mobileUpdateErrorCount(data), 1)
        XCTAssertNil(MobileFinding.updateErrors(in: Data("[{\"total\":1}]".utf8)),
                     "a summary-only snapshot says nothing about errors")
    }

    /// A scan row with a name and no serial names its device by that name, even when the
    /// listed device has a serial; a row with a serial is not pulled in by a shared name.
    func testAScanRowWithNoSerialMatchesTheDeviceByName() throws {
        try write(try rows())
        let named = try XCTUnwrap(try rows().first { ($0["mobileDeviceId"] as? String) == "5" })
        let name = try XCTUnwrap((named["general"] as? [String: Any])?["displayName"] as? String)
        func row(_ name: String, serial: String) -> [String: Any] {
            ["name": name, "serial": serial, "device_type": "MOBILE_DEVICE", "os_version": "18",
             "username": "u", "status": "FAILED", "product_key": "k", "updated": "2026-10-18"]
        }
        try GoldenFleetWorkspace.writeJSON(
            [["total": 2, "status_summary": [], "error_devices": [
                row(name, serial: ""), row("Device 83", serial: "NOT-A-LISTED-SERIAL"),
            ], "failed_plans": NSNull()] as [String: Any]],
            to: dataDir.appendingPathComponent(
                "update-device-failures/update-device-failures_2026-10-18T120000000000.json"))
        let snapshot = MobileFleetService.load(dataDir: dataDir)
        XCTAssertEqual(snapshot.updateErrors?.count, 2)
        let hit = snapshot.devices(
            snapshot.richDevices, affectedBy: .updateErrors,
            context: snapshot.findingContext(staleDays: 30, now: now))
        XCTAssertEqual(hit.compactMap(\.mobileDeviceId), ["5"],
                       "device 1 is named Device 83, but its row has a serial that matches nothing")
    }

    // MARK: - Demo

    func testTheDemoFindingsAreTheDemoFleetsCounts() {
        let snapshot = MobileFleetView.makeDemoSnapshot()
        let context = DemoData.mobileFindingContext
        let list = DemoData.mobileAuditFindings
        XCTAssertNil(finding(.updateErrors, in: list), "the demo has no update scan")
        XCTAssertEqual(
            finding(.unmanaged, in: list)?.affected,
            (1...DemoData.mobileDeviceCount).filter { $0 % 10 == 0 }.count)
        for item in list {
            let kind = MobileFinding(rawValue: item.mobileFilter ?? "")
            XCTAssertNotNil(kind)
            XCTAssertEqual(
                item.affected,
                snapshot.devices(snapshot.richDevices, affectedBy: kind ?? .stale, context: context)
                    .count, item.name)
        }
    }
}
