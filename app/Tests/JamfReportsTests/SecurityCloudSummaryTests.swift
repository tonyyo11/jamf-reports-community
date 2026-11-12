import Synchronization
import XCTest
@testable import JamfReports

/// Jamf Security Cloud in the daily summary (environment model P12): the device match, the
/// summary fields, the alert keys and the Trends metrics.
@MainActor
final class SecurityCloudSummaryTests: XCTestCase {
    private let ws = "scws"
    private let proFile = "profiles:\n  jamf_pro: scws\n  security_cloud: scws-sc\n"
    private let schoolFile = "profiles:\n  jamf_school: scws\n  security_cloud: scws-sc\n"
    private let up1 = "A1B2C3D4-0001-4AAA-8BBB-000000000001"
    private let up2 = "A1B2C3D4-0002-4AAA-8BBB-000000000002"

    private func makeRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SCSummary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(ws), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static var day: String { SummaryJSONParser.dateFormatter.string(from: .testNoon) }

    private func dataDir() throws -> URL { try WorkspacePaths.dataDir(for: ws) }

    private func summariesDir() throws -> URL { try WorkspacePaths.summariesDir(for: ws) }

    private func summary() throws -> DailySummary {
        let file = try summariesDir().appendingPathComponent("summary_\(Self.day).json")
        return try SummaryJSONParser.decode(Data(contentsOf: file))
    }

    private func writeMDMSummary() throws {
        let dir = try summariesDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = DailySummary(
            date: Self.day, totalDevices: 5, fileVaultPct: nil, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli")
        ReportEngine.writeSummaryFile(
            base, to: dir.appendingPathComponent("summary_\(Self.day).json"), onLine: nil)
    }

    /// Slice 1's fixture through slice 1's reducer: what a collect saves.
    private func reducedFixture() throws -> Data {
        let raw = try Data(contentsOf: TestFixtures.dir("security-cloud/risk-list.json"))
        return try XCTUnwrap(ReportEngine.reducingSecurityRisk(raw))
    }

    private func rows() throws -> [SecurityRiskRow] {
        try JSONDecoder().decode([SecurityRiskRow].self, from: reducedFixture())
    }

    private func save(_ text: String, _ kind: String, stamp: String? = nil) throws {
        let dir = try dataDir()
        if let stamp {
            let folder = dir.appendingPathComponent(kind, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appendingPathComponent("\(kind)_\(stamp).json"))
        } else {
            try ReportEngine.saveSnapshot(data: Data(text.utf8), kind: kind, dataDir: dir)
        }
    }

    private func computers(stamp: String? = nil) throws {
        try save(#"[{"general":{"id":"1","name":"A"},"udid":"\#(up1)"}]"#, "computers",
                 stamp: stamp)
    }

    private func mobile(stamp: String? = nil) throws {
        try save(#"[{"mobileDeviceId":"1","deviceType":"iOS","general":{"udid":"\#(up2)"}}]"#,
                 MobileFleetService.deviceKind, stamp: stamp)
    }

    private func finalize(
        _ yaml: String, landed: [EnvironmentProducts.Product: Set<String>], maxAge: Int = 168
    ) throws {
        let environment = EnvironmentProfiles.resolve(
            config: try ConfigLoader.loadFromString(yaml), workspace: ws)
        ReportEngine.finalizeEnvironmentSummary(
            summariesDir: try summariesDir(), dataDir: try dataDir(), environment: environment,
            workspace: try WorkspaceID(validating: ws), landed: landed, day: .testNoon,
            maxCacheAgeHours: maxAge, onLine: { _ in })
    }

    private let both: [EnvironmentProducts.Product: Set<String>] = [
        .jamfPro: ["computers"], .securityCloud: ["security-risk"],
    ]

    // MARK: - Correlation

    private func record(_ udid: String?, serial: String = "") -> DeviceInventoryRecord {
        var record = DeviceInventoryRecord.empty(id: "r", source: "test")
        record.udid = udid
        record.serial = serial
        return record
    }

    func testAComputerMatchesAcrossTheCaseDifference() throws {
        let result = SecurityCloudCorrelation.build(
            rows: [.init(externalId: up1.lowercased())], inventory: [record(up1)])
        XCTAssertEqual(result.matchedShare, .init(met: 1, of: 1))
    }

    func testARowWithNoExternalIdIsCountedApartAndLeavesTheDenominator() {
        let result = SecurityCloudCorrelation.build(
            rows: [.init(externalId: "aaa"), .init(externalId: nil), .init(externalId: " ")],
            inventory: [record("AAA")])
        XCTAssertEqual([result.matched, result.noIdentifier, result.identified], [1, 2, 1])
        XCTAssertEqual(result.matchedShare, .init(met: 1, of: 1))
    }

    func testAmbiguousRowsAreNotCountedAndANameNeverJoins() {
        var named = record(nil)
        named.name = "Lab-1"
        let result = SecurityCloudCorrelation.build(
            rows: [.init(externalId: "dup"), .init(externalId: "Lab-1")],
            inventory: [record("DUP"), record("DUP"), named])
        XCTAssertEqual([result.matched, result.ambiguous], [0, 1])
        XCTAssertEqual(result.matchedShare, .init(met: 0, of: 2))
    }

    /// Two rows for one device count it once, as Protect's match does.
    func testARepeatRowOnAClaimedDeviceIsADuplicate() {
        let result = SecurityCloudCorrelation.build(
            rows: [.init(externalId: "aaa"), .init(externalId: "AAA"), .init(externalId: "bbb")],
            inventory: [record("AAA"), record("CCC")])
        XCTAssertEqual([result.matched, result.duplicates], [1, 1])
        XCTAssertEqual(result.matchedShare, .init(met: 1, of: 2))
    }

    func testNoInventoryOrNoIdentifiedRowGivesNoShare() {
        XCTAssertNil(SecurityCloudCorrelation.build(
            rows: [.init(externalId: "a")], inventory: []).matchedShare)
        XCTAssertNil(SecurityCloudCorrelation.build(
            rows: [.init(externalId: nil)], inventory: [record("A")]).matchedShare)
    }

    func testAMobileDeviceMatchesThroughItsGeneralUDID() throws {
        try makeRoot()
        try computers()
        try mobile()
        let match = try XCTUnwrap(SecurityCloudCorrelation.load(
            rows: rows(), profile: ws, mobile: MobileFleetService.load(dataDir: dataDir())))
        XCTAssertEqual(match.matchedShare, .init(met: 2, of: 3))
        XCTAssertEqual(match.inventorySize, 2)
    }

    func testRecordsWithoutAUDIDAreNotInventoryToMatchAgainst() throws {
        let noUDID = SecurityCloudCorrelation.build(
            rows: [.init(externalId: "a")], inventory: [record(nil), record("")])
        XCTAssertEqual(noUDID.inventorySize, 0)
        XCTAssertNil(noUDID.matchedShare, "a list with no UDIDs gives no share, not 0 of N")
        let mixed = SecurityCloudCorrelation.build(
            rows: [.init(externalId: "a")], inventory: [record(nil), record("A")])
        XCTAssertEqual(mixed.inventorySize, 1)
        let protect = try JSONDecoder().decode(
            [ProtectComputerRow].self, from: Data(#"[{"uuid":"aaa"}]"#.utf8))
        let bare = ProtectProCorrelation.build(protect: protect, pro: [record(nil)])
        XCTAssertNil(bare.matchedShare)
        let serialOnly = ProtectProCorrelation.build(
            protect: protect, pro: [record(nil, serial: "C02")])
        XCTAssertEqual(serialOnly.matchedShare, .init(met: 0, of: 1))
    }

    func testProtectsMatchIgnoresMobileRecords() throws {
        let protect = try JSONDecoder().decode(
            [ProtectComputerRow].self, from: Data(#"[{"uuid":"\#(up2.lowercased())"}]"#.utf8))
        let computersOnly = ProtectProCorrelation.build(protect: protect, pro: [record(up1)])
        XCTAssertEqual(computersOnly.matched, 0)
        try makeRoot()
        try mobile()
        XCTAssertNil(ProtectProCorrelation.load(protect: protect, profile: ws, demoMode: false),
                     "no computers snapshot, so no Protect match, whatever mobile holds")
    }

    // MARK: - Summary

    func testWrittenOnlyWhenSecurityRiskLanded() async throws {
        try makeRoot()
        try writeMDMSummary()
        try computers()
        try save(String(decoding: reducedFixture(), as: UTF8.self), "security-risk")
        try finalize(proFile, landed: [.jamfPro: ["computers"]])
        var s = try summary()
        XCTAssertNil(s.securityCloudDeviceCount)
        XCTAssertNil(s.securityCloudMatched)
        XCTAssertNil(s.securityCloudRiskCounts)
        XCTAssertEqual(s.products, ["jamf_pro"])
        try finalize(proFile, landed: both)
        s = try summary()
        XCTAssertEqual(s.products, ["jamf_pro", "security_cloud"])
        XCTAssertEqual(s.securityCloudDeviceCount, 3)
        XCTAssertEqual(s.securityCloudMatched, .init(met: 1, of: 3))
        XCTAssertEqual(s.securityCloudRiskCounts, ["high": 1, "medium": 1, "secure": 1])
    }

    func testAnUnmeasuredGroupKeepsTheEarlierValue() throws {
        try makeRoot()
        try writeMDMSummary()
        try computers()
        try mobile()
        try save(String(decoding: reducedFixture(), as: UTF8.self), "security-risk")
        try finalize(proFile, landed: both)
        try finalize(proFile, landed: [.jamfPro: ["computers"]])
        let s = try summary()
        XCTAssertEqual(s.securityCloudDeviceCount, 3)
        XCTAssertEqual(s.securityCloudMatched, .init(met: 2, of: 3))
        XCTAssertEqual(s.securityCloudHighRiskCount, 1)
    }

    func testAnUnreadableSnapshotLeavesTheFieldsAbsent() throws {
        try makeRoot()
        try writeMDMSummary()
        try save("not json", "security-risk")
        try finalize(proFile, landed: both)
        let s = try summary()
        XCTAssertNil(s.securityCloudDeviceCount)
        XCTAssertEqual(s.products, ["jamf_pro", "security_cloud"])
    }

    func testAStaleInventoryLeavesNoMatchButKeepsTheCounts() throws {
        try makeRoot()
        try writeMDMSummary()
        try computers(stamp: "20200101T080000")
        try save(String(decoding: reducedFixture(), as: UTF8.self), "security-risk")
        try finalize(proFile, landed: both)
        var s = try summary()
        XCTAssertEqual(s.securityCloudDeviceCount, 3)
        XCTAssertNil(s.securityCloudMatched)
        // A fresh computers snapshot beside a stale mobile one is no match either.
        try computers()
        try mobile(stamp: "20200101T080000")
        try finalize(proFile, landed: both)
        s = try summary()
        XCTAssertNil(s.securityCloudMatched)
        try mobile()
        try finalize(proFile, landed: both)
        XCTAssertEqual(try summary().securityCloudMatched, .init(met: 2, of: 3))
    }

    private final class Lines: Sendable {
        private let items = Mutex<[String]>([])
        func add(_ text: String) { items.withLock { $0.append(text) } }
        var all: [String] { items.withLock { $0 } }
    }

    func testAWithheldMatchLogsOneInfoLineNamingTheStaleKind() throws {
        try makeRoot()
        try computers()
        try mobile(stamp: "20200101T080000")
        try save(String(decoding: reducedFixture(), as: UTF8.self), "security-risk")
        let lines = Lines()
        let figures = ReportEngine.securityCloudSummaryFigures(
            dataDir: try dataDir(), workspace: try WorkspaceID(validating: ws),
            landed: ["security-risk"], onLine: { lines.add($0.text) })
        XCTAssertNil(figures?.matched)
        XCTAssertEqual(lines.all, [
            "[info] Security Cloud match left out: mobile-devices-list is older than 168 hours",
        ])
        let fresh = Lines()
        try mobile()
        _ = ReportEngine.securityCloudSummaryFigures(
            dataDir: try dataDir(), workspace: try WorkspaceID(validating: ws),
            landed: ["security-risk"], onLine: { fresh.add($0.text) })
        XCTAssertEqual(fresh.all, [])
    }

    func testAWithheldProtectMatchLogsTheSameLine() throws {
        try makeRoot()
        try computers(stamp: "20200101T080000")
        let rows = try String(
            contentsOf: TestFixtures.dir("jamf-cli-data/protect-computers/computers_happy.json"),
            encoding: .utf8)
        try save(rows, "protect-computers")
        let lines = Lines()
        let figures = ReportEngine.protectSummaryFigures(
            dataDir: try dataDir(), workspace: try WorkspaceID(validating: ws),
            landed: ["protect-computers"], onLine: { lines.add($0.text) })
        XCTAssertNotNil(figures?.computers)
        XCTAssertNil(figures?.computers?.matched)
        XCTAssertEqual(lines.all, [
            "[info] Jamf Protect match left out: computers is older than 168 hours",
        ])
    }

    func testTheAgeCheckFollowsTheMobileKindTheReaderPicks() throws {
        try makeRoot()
        try computers()
        try save(String(decoding: reducedFixture(), as: UTF8.self), "security-risk")
        // A stale list and a fresher legacy snapshot: the reader uses the legacy rows.
        try mobile(stamp: "20200101T080000")
        try save(#"[{"mobileDeviceId":"1","deviceType":"iOS","general":{"udid":"\#(up2)"}}]"#,
                 MobileFleetService.legacyInventoryKind)
        let lines = Lines()
        let figures = ReportEngine.securityCloudSummaryFigures(
            dataDir: try dataDir(), workspace: try WorkspaceID(validating: ws),
            landed: ["security-risk"], onLine: { lines.add($0.text) })
        XCTAssertEqual(MobileFleetService.load(dataDir: try dataDir()).inventoryKind,
                       MobileFleetService.legacyInventoryKind)
        XCTAssertEqual(figures?.matched, .init(met: 2, of: 3))
        XCTAssertEqual(lines.all, [])
    }

    func testAnEmptyRiskListIsAMeasuredZeroWithNoMatchOrCategories() throws {
        try makeRoot()
        try writeMDMSummary()
        try computers()
        try save("[]", "security-risk")
        try finalize(proFile, landed: both)
        let s = try summary()
        XCTAssertEqual(s.securityCloudDeviceCount, 0)
        XCTAssertNil(s.securityCloudMatched)
        XCTAssertNil(s.securityCloudRiskCounts)
        XCTAssertNil(s.securityCloudHighRiskCount)
    }

    func testAStaleSchoolInventoryLeavesNoMatch() throws {
        try makeRoot()
        try writeMDMSummary()
        try SchoolRows.write(
            [SchoolRows.device(1, ["udid": up1])], kind: "school-devices", into: dataDir(),
            stamp: "20200101T080000")
        try save(String(decoding: reducedFixture(), as: UTF8.self), "security-risk")
        try finalize(schoolFile, landed: [.jamfSchool: ["school-devices"],
                                          .securityCloud: ["security-risk"]])
        let s = try summary()
        XCTAssertEqual(s.securityCloudDeviceCount, 3)
        XCTAssertNil(s.securityCloudMatched)
    }

    /// School devices reach Security Cloud by management ID, not UDID (spec "Identity keys"),
    /// so a UDID that happens to line up is not a match and the share is left out.
    func testJamfSchoolGetsNoMatchEvenWhenAUDIDLinesUp() throws {
        try makeRoot()
        try writeMDMSummary()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd'T'HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        try SchoolRows.write(
            [SchoolRows.device(1, ["udid": up1])], kind: "school-devices", into: dataDir(),
            stamp: stamp.string(from: Date()))
        try save(String(decoding: reducedFixture(), as: UTF8.self), "security-risk")
        try finalize(schoolFile, landed: [.jamfSchool: ["school-devices"],
                                          .securityCloud: ["security-risk"]])
        let s = try summary()
        XCTAssertEqual(s.products, ["jamf_school", "security_cloud"])
        XCTAssertEqual(s.securityCloudDeviceCount, 3)
        XCTAssertNotNil(s.securityCloudRiskCounts)
        XCTAssertNil(s.securityCloudMatched)
    }

    func testTheRouterRecordsWhatSecurityCloudLanded() async throws {
        try makeRoot()
        try computers()
        let ws = ws
        let today = Self.day
        let dir = try dataDir()
        let reduced = try reducedFixture()
        try await CollectRouter.run(
            workspace: WorkspaceID(validating: ws),
            config: try ConfigLoader.loadFromString(proFile), now: .testNoon,
            proCollect: { _, _, _, _, _, _, _ in
                ReportEngine.landedSources?.record(.jamfPro, ["computers"])
                let dir = try WorkspacePaths.summariesDir(for: ws)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                ReportEngine.writeSummaryFile(
                    DailySummary(
                        date: today, totalDevices: 5, fileVaultPct: nil, compliancePct: nil,
                        staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
                        source: "jamf-cli"),
                    to: dir.appendingPathComponent("summary_\(today).json"), onLine: nil)
                return .collected
            },
            schoolCollect: { _, _, _, _, _, _ in },
            protectCollect: { _, _, _ in [] },
            securityCollect: { _, _, _, _ in
                try ReportEngine.saveSnapshot(data: reduced, kind: "security-risk", dataDir: dir)
                return ["security-risk"]
            },
            resolved: { _ in nil },
            gate: { _, _, _, _, _, _ in .proceed(holdsClaim: false, coordinating: false) },
            onLine: { _ in })
        let s = try summary()
        XCTAssertEqual(s.products, ["jamf_pro", "security_cloud"])
        XCTAssertEqual(s.securityCloudDeviceCount, 3)
    }

    // MARK: - Summary value rules

    private func day(
        count: Int? = nil, matched: MobileSummary.Share? = nil, risk: [String: Int]? = nil
    ) -> DailySummary {
        DailySummary(
            date: "2026-11-07", totalDevices: 10, fileVaultPct: 90, compliancePct: nil,
            staleCount: nil, osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil,
            source: "jamf-cli", securityCloudDeviceCount: count, securityCloudMatched: matched,
            securityCloudRiskCounts: risk)
    }

    func testRoundTripFillingAndRangeCheck() throws {
        let full = day(count: 8, matched: .init(met: 6, of: 7), risk: ["high": 2, "low": 6])
        let decoded = try SummaryJSONParser.decode(JSONEncoder().encode(full))
        XCTAssertEqual(decoded.securityCloudMatched, .init(met: 6, of: 7))
        XCTAssertEqual(decoded.securityCloudRiskCounts, ["high": 2, "low": 6])
        let filled = day(count: 9).filling(from: full)
        XCTAssertEqual(filled.securityCloudDeviceCount, 9)
        XCTAssertEqual(filled.securityCloudMatched, .init(met: 6, of: 7))
        // The risk counts belong to the count they were measured with: filling the older ones
        // beside a smaller count would leave a day the range check rejects.
        XCTAssertNil(filled.securityCloudRiskCounts)
        let smaller = day(count: 5).filling(from: full)
        XCTAssertTrue(smaller.numbersAreInRange)
        XCTAssertTrue(full.numbersAreInRange)
        XCTAssertFalse(day(matched: .init(met: 6, of: 5)).numbersAreInRange)
        XCTAssertFalse(day(matched: .init(met: -1, of: 5)).numbersAreInRange)
        XCTAssertFalse(day(count: -1).numbersAreInRange)
        XCTAssertFalse(day(count: 2, risk: ["high": 3]).numbersAreInRange)
        XCTAssertFalse(day(risk: ["high": -1]).numbersAreInRange)
    }

    func testANewlyMeasuredFieldIsAnUpgradeForTheSameDayRebuild() {
        XCTAssertTrue(ReportEngine.freshSummaryIsBetter(
            existing: day(), fresh: day(count: 3)))
        XCTAssertTrue(ReportEngine.freshSummaryIsBetter(
            existing: day(count: 3), fresh: day(count: 3, matched: .init(met: 1, of: 3))))
        XCTAssertTrue(ReportEngine.freshSummaryIsBetter(
            existing: day(count: 3), fresh: day(count: 3, risk: ["high": 1])))
    }

    // MARK: - Alert keys and Trends

    func testAlertKeysFireOnAValueNeverWhenAbsentAndHighReadsZero() {
        let current = day(count: 40, matched: .init(met: 30, of: 100), risk: ["high": 4])
        let cases: [(String, String, Double)] = [
            ("security_cloud_device_count", "above", 39),
            ("security_cloud_matched_pct", "below", 50),
            ("security_cloud_high_risk_count", "above", 3),
        ]
        for (key, when, threshold) in cases {
            let rule = AlertRule(metric: key, when: when, threshold: threshold, lookbackDays: nil)
            XCTAssertEqual(
                MetricAlertEvaluator.evaluate(rules: [rule], current: current, prior: nil).count,
                1, key)
            XCTAssertTrue(MetricAlertEvaluator.evaluate(
                rules: [rule], current: day(), prior: nil).isEmpty, key)
        }
        XCTAssertEqual(AlertMetric.securityCloudHighRiskCount.value(in: day(risk: ["low": 2])), 0)
        XCTAssertNil(AlertMetric.securityCloudHighRiskCount.value(in: day(count: 2)))
        XCTAssertEqual(
            AlertMetric.securityCloudMatchedPct.value(in: day(matched: .init(met: 999, of: 2000))),
            50.0)
        XCTAssertNil(
            AlertMetric.securityCloudMatchedPct.value(in: day(matched: .init(met: 0, of: 0))))
    }

    func testThePickerListsSecurityCloudCardsOnlyWhereTheEnvironmentHasIt() throws {
        try makeRoot()
        let workspace = try WorkspacePaths.workspaceURL(for: WorkspaceID(validating: ws))
        let config = workspace.appendingPathComponent("config.yaml")
        try Data("profiles:\n  jamf_pro: scws\n".utf8).write(to: config)
        let store = WorkspaceStore(demoMode: false)
        store.profile = ws
        store.refreshEnvironmentProducts()
        func rows() -> [TrendSeries.Metric] {
            OverviewCustomizeSheet.scoreCardRows(
                selected: [], policy: .default, mobile: store.scoreCardExtraMetrics,
                composition: .mixed)
        }
        let all = TrendSeries.Metric.securityCloudMetrics
        XCTAssertTrue(all.allSatisfy { !rows().contains($0) })
        try Data(proFile.utf8).write(to: config)
        store.refreshEnvironmentProducts()
        XCTAssertTrue(all.allSatisfy { rows().contains($0) })
        XCTAssertTrue(WorkspaceStore(demoMode: true).scoreCardExtraMetrics.isEmpty)
    }

    func testAlertKeyUnitsAndTheOverviewOfferOnAMobileOnlyEnvironment() {
        XCTAssertTrue(AlertMetric.securityCloudMatchedPct.isPercentage)
        XCTAssertFalse(AlertMetric.securityCloudDeviceCount.isPercentage)
        XCTAssertFalse(AlertMetric.securityCloudHighRiskCount.isPercentage)
        for metric in TrendSeries.Metric.securityCloudMetrics {
            XCTAssertTrue(metric.isOffered(under: .default, in: .mobileOnly), "\(metric)")
        }
    }

    func testMetricsPolarityUnitsAndStoreOffering() {
        let expected: [(TrendSeries.Metric, String, FleetInsightInput.Polarity, String, Bool)] = [
            (.securityCloudDevices, "securityCloudDevices", .neutral, "", true),
            (.securityCloudMatched, "securityCloudMatched", .higherIsBetter, "%", false),
            (.securityCloudHighRisk, "securityCloudHighRisk", .lowerIsBetter, "", true),
        ]
        XCTAssertEqual(TrendSeries.Metric.securityCloudMetrics, expected.map(\.0))
        for (metric, raw, polarity, unit, isCount) in expected {
            XCTAssertEqual(metric.rawValue, raw)
            XCTAssertEqual(TrendSeries.Metric(rawValue: raw), metric)
            XCTAssertEqual(metric.polarity, polarity)
            XCTAssertEqual(metric.unit, unit)
            XCTAssertEqual(metric.isDeviceCount, isCount)
            XCTAssertTrue(metric.isSecurityCloud)
            XCTAssertFalse(metric.isProtect)
        }
        XCTAssertTrue(TrendSeries.Metric.allCases.allSatisfy { !$0.isSecurityCloud })
        let store = TrendStore(summaries: [day(count: 3, risk: ["low": 3])])
        XCTAssertTrue(store.offers(.securityCloudDevices))
        XCTAssertTrue(store.offers(.securityCloudHighRisk))
        XCTAssertFalse(store.offers(.securityCloudMatched))
        XCTAssertEqual(store.points(metric: .securityCloudHighRisk).map(\.value), [0])
        XCTAssertFalse(TrendStore(summaries: [day()]).offers(.securityCloudDevices))
    }

    func testOfferedOnlyWithSecurityCloudInTheEnvironmentAndNeverInDemoMode() throws {
        try makeRoot()
        let workspace = try WorkspacePaths.workspaceURL(for: WorkspaceID(validating: ws))
        let config = workspace.appendingPathComponent("config.yaml")
        try Data("profiles:\n  jamf_pro: scws\n".utf8).write(to: config)
        let store = WorkspaceStore(demoMode: false)
        store.profile = ws
        store.refreshEnvironmentProducts()
        let all = TrendSeries.Metric.securityCloudMetrics
        XCTAssertTrue(all.allSatisfy { !store.isOffered($0) })
        XCTAssertTrue(Set(store.availableMetrics).isDisjoint(with: all))
        try Data(proFile.utf8).write(to: config)
        store.refreshEnvironmentProducts()
        XCTAssertTrue(all.allSatisfy { store.isOffered($0) && store.availableMetrics.contains($0) })
        XCTAssertTrue(TrendSeries.Metric.protectMetrics.allSatisfy { !store.isOffered($0) })
        let demo = WorkspaceStore(demoMode: true)
        XCTAssertTrue(all.allSatisfy { !demo.isOffered($0) })
        XCTAssertTrue(Set(demo.availableMetrics).isDisjoint(with: all))
    }
}
