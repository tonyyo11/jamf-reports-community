import Synchronization
import XCTest
@testable import JamfReports

/// One finalize per routed run writes `products` and the Protect figures into today's summary.
final class EnvironmentFinalizeTests: XCTestCase {
    private struct Boom: Error {}

    private final class Counter: Sendable {
        private let value = Mutex(0)
        func bump() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    private final class Lines: Sendable {
        private let items = Mutex<[String]>([])
        func add(_ text: String) { items.withLock { $0.append(text) } }
        var all: [String] { items.withLock { $0 } }
    }

    private static let ws = "finws"
    private let ws = EnvironmentFinalizeTests.ws
    private let proFile = "profiles:\n  jamf_pro: finws\n  protect: finws-protect\n"
    private let schoolFile = "profiles:\n  jamf_school: finws\n  protect: finws-protect\n"
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/jamf-cli-data")

    private func makeRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnvFinalize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(ws), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static var day: String { SummaryJSONParser.dateFormatter.string(from: .testNoon) }

    private func file() throws -> URL {
        try WorkspacePaths.summariesDir(for: ws).appendingPathComponent("summary_\(Self.day).json")
    }

    private func summary() throws -> DailySummary {
        try SummaryJSONParser.decode(Data(contentsOf: file()))
    }

    private static func writeMDMSummary() throws {
        let dir = try WorkspacePaths.summariesDir(for: ws)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = DailySummary(
            date: day, totalDevices: 5, fileVaultPct: nil, compliancePct: nil, staleCount: nil,
            osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil, source: "jamf-cli")
        ReportEngine.writeSummaryFile(
            base, to: dir.appendingPathComponent("summary_\(day).json"), onLine: nil)
    }

    private enum Inventory { case none, computers, empty, school }

    private static func save(_ text: String, _ kind: String, _ dataDir: URL) throws {
        try ReportEngine.saveSnapshot(data: Data(text.utf8), kind: kind, dataDir: dataDir)
    }

    private static func fixture(_ kind: String, _ name: String) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent("\(kind)/\(name)"), encoding: .utf8)
    }

    private static func landProtect(
        _ dataDir: URL, inventory: Inventory, alerts: String? = nil,
        kinds: Set<String> = ["protect-computers", "protect-alerts"]
    ) throws -> [String] {
        if kinds.contains("protect-computers") {
            try save(fixture("protect-computers", "computers_happy.json"),
                     "protect-computers", dataDir)
        }
        if kinds.contains("protect-alerts") {
            try save(try alerts ?? fixture("protect-alerts", "alerts_happy.json"),
                     "protect-alerts", dataDir)
        }
        let serials = [
            #"{"general":{"id":"1","name":"A"},"hardware":{"serialNumber":"SYNTH0000001"}}"#,
            #"{"general":{"id":"2","name":"B"},"hardware":{"serialNumber":"SYNTH0000002"}}"#,
        ]
        switch inventory {
        case .none: break
        case .computers: try save("[" + serials.joined(separator: ",") + "]", "computers", dataDir)
        case .empty: try save("[]", "computers", dataDir)
        case .school:
            let udids = ["00000000-0000-4000-8000-00000000c001",
                         "00000000-0000-4000-8000-00000000c002",
                         "00000000-0000-4000-8000-0000000000ff"]
            let rows = udids.enumerated().map {
                SchoolRows.device(
                    $0.offset + 1,
                    ["udid": $0.element, "serialNumber": "SYNTH000000\($0.offset + 1)"])
            }
            // Stamped now: an older snapshot is past max_cache_age_hours and gives no match.
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd'T'HHmmss"
            stamp.locale = Locale(identifier: "en_US_POSIX")
            try SchoolRows.write(
                rows, kind: "school-devices", into: dataDir, stamp: stamp.string(from: Date()))
        }
        return kinds.sorted()
    }

    private let open: CollectRouter.Gate = { _, _, _, _, _, _ in
        .proceed(holdsClaim: false, coordinating: false)
    }

    private struct Options {
        var writesMDMSummary = true
        var proError: (any Error)?
        var protect = true
        var inventory = Inventory.computers
        var alerts: String?
        var landedKinds: Set<String> = ["protect-computers", "protect-alerts"]
        var gate: CollectRouter.Gate?
        var logsUnwrittenMarker = false
        var protectCalls = Counter()
        var lines = Lines()
    }

    private func run(_ yaml: String, _ o: Options = Options()) async throws {
        let ws = ws
        try await CollectRouter.run(
            workspace: WorkspaceID(validating: ws),
            config: try ConfigLoader.loadFromString(yaml), now: .testNoon,
            proCollect: { _, _, _, _, _, _, onLine in
                if o.logsUnwrittenMarker {
                    onLine(.init(timestamp: Date(), level: .warn, text:
                        "\(ReportEngine.summaryNotWrittenMarker) test"))
                }
                if let error = o.proError { throw error }
                ReportEngine.landedSources?.record(.jamfPro, ["computers"])
                if o.writesMDMSummary { try Self.writeMDMSummary() }
                return .collected
            },
            schoolCollect: { _, _, _, _, _, _ in
                ReportEngine.landedSources?.record(.jamfSchool, ["school-devices"])
                if o.writesMDMSummary { try Self.writeMDMSummary() }
            },
            protectCollect: { _, dataDir, _ in
                o.protectCalls.bump()
                return o.protect
                    ? try Self.landProtect(
                        dataDir, inventory: o.inventory, alerts: o.alerts, kinds: o.landedKinds)
                    : []
            },
            resolved: { _ in nil }, gate: o.gate ?? open, onLine: { o.lines.add($0.text) })
    }

    func testProPlusProtectRecordsProductsAndFigures() async throws {
        try makeRoot()
        try await run(proFile)
        let s = try summary()
        XCTAssertEqual(s.products, ["jamf_pro", "protect"])
        XCTAssertEqual(s.protectComputerCount, 3)
        XCTAssertEqual(s.protectOpenAlerts, 2)
        XCTAssertEqual(s.protectAlertCounts, ["high": 1, "medium": 1])
        XCTAssertEqual(s.protectMatched, .init(met: 2, of: 3))
        XCTAssertNil(s.collectionSources?["protect-alerts"])
    }

    func testFailedMDMWithProtectAndNoSummaryWritesNone() async throws {
        try makeRoot()
        var o = Options()
        o.writesMDMSummary = false
        o.proError = ReportEngineError.collectDead(profile: ws, failedCount: 3)
        do {
            try await run(proFile, o)
            XCTFail("expected the verdict")
        } catch let error as ReportEngineError {
            guard case .collectDead = error else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(o.protectCalls.count, 1)
        XCTAssertThrowsError(try summary())
    }

    func testFailedMDMKeepsAnExistingSummaryAndAddsProtectFigures() async throws {
        try makeRoot()
        try Self.writeMDMSummary()
        var o = Options()
        o.proError = ReportEngineError.collectDead(profile: ws, failedCount: 3)
        do {
            try await run(proFile, o)
            XCTFail("expected the verdict")
        } catch let error as ReportEngineError {
            guard case .collectDead = error else { return XCTFail("got \(error)") }
        }
        let s = try summary()
        XCTAssertEqual(s.products, ["protect"])
        XCTAssertEqual(s.totalDevices, 5)
        XCTAssertEqual(s.protectComputerCount, 3)
    }

    func testANonVerdictErrorPropagatesWithNoFinalize() async throws {
        try makeRoot()
        try Self.writeMDMSummary()
        var o = Options()
        o.proError = Boom()
        do {
            try await run(proFile, o)
            XCTFail("expected Boom")
        } catch is Boom {}
        XCTAssertNil(try summary().products)
    }

    func testProtectOnlyWritesAMacLessSummaryWithFigures() async throws {
        try makeRoot()
        var o = Options()
        o.writesMDMSummary = false
        o.inventory = .none
        try await run("profiles:\n  protect: \(ws)\n", o)
        let s = try summary()
        XCTAssertEqual(s.totalDevices, 0)
        XCTAssertNil(s.mobile)
        XCTAssertEqual(s.products, ["protect"])
        XCTAssertEqual(s.protectComputerCount, 3)
        XCTAssertNil(s.protectMatched)
        XCTAssertEqual(s.collectionSources?["protect-alerts"], "live")
    }

    /// Every Pro and School collect logged "[ok] wrote summary_…json" twice: once for the MDM
    /// write and again for this rewrite. Only a summary this step creates is announced.
    func testOnlyASummaryThisStepCreatesIsAnnounced() async throws {
        let announced = { (o: Options) in
            o.lines.all.filter { $0.contains("will reflect this run") }.count
        }
        try makeRoot()
        let rewrite = Options()
        try await run(proFile, rewrite)
        XCTAssertEqual(announced(rewrite), 0)
        XCTAssertTrue(rewrite.lines.all.contains { $0.contains("added environment fields") })

        try makeRoot()
        var create = Options()
        create.writesMDMSummary = false
        create.inventory = .none
        try await run("profiles:\n  protect: \(ws)\n", create)
        XCTAssertEqual(announced(create), 1)
    }

    func testASecondRunTheSameDayUnionsProducts() async throws {
        try makeRoot()
        var o = Options()
        o.protect = false
        try await run(proFile, o)
        XCTAssertEqual(try summary().products, ["jamf_pro"])
        try await run(proFile)
        XCTAssertEqual(try summary().products, ["jamf_pro", "protect"])
    }

    func testAGateStopLeavesTheSummaryBytesAndCollectsNothing() async throws {
        try makeRoot()
        try Self.writeMDMSummary()
        let before = try Data(contentsOf: file())
        var o = Options()
        o.gate = { _, _, _, _, _, _ in .stop(.alreadyCollected) }
        try await run(proFile, o)
        XCTAssertEqual(try Data(contentsOf: file()), before)
        XCTAssertEqual(o.protectCalls.count, 0)
    }

    func testSchoolPlusProtectMatchesAgainstSchoolDevices() async throws {
        try makeRoot()
        var o = Options()
        o.inventory = .school
        try await run(schoolFile, o)
        let s = try summary()
        XCTAssertEqual(s.products, ["jamf_school", "protect"])
        XCTAssertEqual(s.protectMatched, .init(met: 2, of: 3))
    }

    func testAnEmptyInventoryGivesNoMatchedShare() async throws {
        try makeRoot()
        var o = Options()
        o.inventory = .empty
        try await run(proFile, o)
        let s = try summary()
        XCTAssertEqual(s.protectComputerCount, 3)
        XCTAssertNil(s.protectMatched)
    }

    private func dataDir() throws -> URL { try WorkspacePaths.dataDir(for: ws) }

    func testOnlyComputersLandedIgnoresAnOlderAlertsSnapshot() async throws {
        try makeRoot()
        try Self.save(Self.fixture("protect-alerts", "alerts_happy.json"), "protect-alerts",
                      try dataDir())
        var o = Options()
        o.landedKinds = ["protect-computers"]
        try await run(proFile, o)
        let s = try summary()
        XCTAssertEqual(s.protectComputerCount, 3)
        XCTAssertNil(s.protectOpenAlerts)
        XCTAssertNil(s.protectAlertCounts)
    }

    func testALaterRunKeepsTheMorningsAlertsAndReplacesComputers() async throws {
        try makeRoot()
        var morning = Options()
        morning.inventory = .empty
        try await run(proFile, morning)
        XCTAssertNil(try summary().protectMatched)
        var afternoon = Options()
        afternoon.writesMDMSummary = false
        afternoon.landedKinds = ["protect-computers"]
        try await run(proFile, afternoon)
        let s = try summary()
        XCTAssertEqual(s.protectMatched, .init(met: 2, of: 3))
        XCTAssertEqual(s.protectOpenAlerts, 2)
        XCTAssertEqual(s.protectAlertCounts, ["high": 1, "medium": 1])
    }

    func testARunThatLandsNoProtectKeepsEveryFigure() async throws {
        try makeRoot()
        try await run(proFile)
        let before = try summary()
        var o = Options()
        o.writesMDMSummary = false
        o.landedKinds = []
        try await run(proFile, o)
        let s = try summary()
        XCTAssertEqual(s.protectComputerCount, before.protectComputerCount)
        XCTAssertEqual(s.protectMatched, before.protectMatched)
        XCTAssertEqual(s.protectOpenAlerts, before.protectOpenAlerts)
        XCTAssertEqual(s.protectAlertCounts, before.protectAlertCounts)
    }

    func testProtectOnlyWithALeftoverComputersSnapshotHasNoMatch() async throws {
        try makeRoot()
        try Self.save("[]", "computers", try dataDir())
        var o = Options()
        o.writesMDMSummary = false
        o.inventory = .computers
        try await run("profiles:\n  protect: \(ws)\n", o)
        XCTAssertEqual(try summary().protectComputerCount, 3)
        XCTAssertNil(try summary().protectMatched)
    }

    func testAnExpiredInventorySnapshotGivesNoMatch() async throws {
        try makeRoot()
        let dir = try dataDir().appendingPathComponent("computers", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"[{"general":{"id":"1","name":"A"},"hardware":{"serialNumber":"SYNTH0000001"}}]"#.utf8)
            .write(to: dir.appendingPathComponent("computers_20200101T000000.json"))
        var o = Options()
        o.inventory = .none
        try await run(proFile, o)
        XCTAssertEqual(try summary().protectComputerCount, 3)
        XCTAssertNil(try summary().protectMatched)
    }

    func testAnUnreadableAlertsSnapshotLeavesTheAlertFiguresNil() async throws {
        try makeRoot()
        var o = Options()
        o.alerts = "{not json"
        try await run(proFile, o)
        let s = try summary()
        XCTAssertNil(s.protectOpenAlerts)
        XCTAssertNil(s.protectAlertCounts)
        XCTAssertEqual(s.protectComputerCount, 3)
    }

    func testAnAlertWithNoStatusOrAnOddOneCountsAsOpen() async throws {
        try makeRoot()
        var o = Options()
        o.alerts = #"[{"severity":"High"},{"severity":"Low","status":"Weird"},"#
            + #"{"severity":"Low","status":"Resolved"}]"#
        try await run(proFile, o)
        let s = try summary()
        XCTAssertEqual(s.protectOpenAlerts, 2)
        XCTAssertEqual(s.protectAlertCounts, ["high": 1, "low": 1])
    }

    func testNoOkLineWhenTheMDMSummaryWasNotWritten() async throws {
        try makeRoot()
        try Self.writeMDMSummary()
        var o = Options()
        o.writesMDMSummary = false
        o.logsUnwrittenMarker = true
        try await run(proFile, o)
        XCTAssertFalse(o.lines.all.contains { $0.contains("will reflect this run") })
        XCTAssertTrue(o.lines.all.contains { $0.contains("added environment fields") })
    }

    // MARK: platform slot (P9-R1)

    private func finalize(
        _ yaml: String, landed: [EnvironmentProducts.Product: Set<String>]
    ) throws -> [String]? {
        let dir = try WorkspacePaths.summariesDir(for: ws)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.writeMDMSummary()
        ReportEngine.finalizeEnvironmentSummary(
            summariesDir: dir, dataDir: dir,
            environment: EnvironmentProfiles.resolve(
                config: try ConfigLoader.loadFromString(yaml), workspace: ws),
            workspace: try WorkspaceID(validating: ws), landed: landed, day: .testNoon,
            onLine: { _ in })
        return try summary().products
    }

    func testFinalizeWritesTheSlotNamesOfWhatLanded() throws {
        try makeRoot()
        let products = try finalize(
            proFile, landed: [.jamfPro: ["computers"], .platform: ["ddm-status"], .protect: []])
        XCTAssertEqual(products, ["jamf_pro", "platform"])
    }

    func testPlatformSlotRule() {
        typealias R = ReportEngine
        XCTAssertTrue(R.platformSlotApplies(
            separateProfile: true, profileAuthIsPlatform: false, source: .profilesBlock))
        XCTAssertTrue(R.platformSlotApplies(
            separateProfile: false, profileAuthIsPlatform: true, source: .legacyKeys))
        XCTAssertFalse(R.platformSlotApplies(
            separateProfile: false, profileAuthIsPlatform: true, source: .profilesBlock))
        XCTAssertFalse(R.platformSlotApplies(
            separateProfile: false, profileAuthIsPlatform: false, source: .legacyKeys))
    }
}
