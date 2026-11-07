import XCTest
@testable import JamfReports

/// One finalize per routed run writes `products` and the Protect figures into today's summary.
final class EnvironmentFinalizeTests: XCTestCase {
    private struct Boom: Error {}

    private let ws = "finws"
    private let proFile = "profiles:\n  jamf_pro: finws\n  protect: finws-protect\n"

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

    private var day: String { SummaryJSONParser.dateFormatter.string(from: .testNoon) }

    private func file() throws -> URL {
        try WorkspacePaths.summariesDir(for: ws).appendingPathComponent("summary_\(day).json")
    }

    private func summary() throws -> DailySummary {
        try SummaryJSONParser.decode(Data(contentsOf: file()))
    }

    private static func writeMDMSummary() throws {
        let ws = "finws"
        let day = SummaryJSONParser.dateFormatter.string(from: .testNoon)
        let dir = try WorkspacePaths.summariesDir(for: ws)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = DailySummary(
            date: day, totalDevices: 5, fileVaultPct: nil, compliancePct: nil, staleCount: nil,
            osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil, source: "jamf-cli")
        ReportEngine.writeSummaryFile(
            base, to: dir.appendingPathComponent("summary_\(day).json"), onLine: nil)
    }

    private static func landProtect(_ dataDir: URL, inventory: Bool) throws -> [String] {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/jamf-cli-data")
        for (kind, name) in [("protect-computers", "computers_happy.json"),
                             ("protect-alerts", "alerts_happy.json")] {
            let data = try Data(contentsOf: fixtures.appendingPathComponent("\(kind)/\(name)"))
            try ReportEngine.saveSnapshot(data: data, kind: kind, dataDir: dataDir)
        }
        guard inventory else { return ["protect-computers", "protect-alerts"] }
        let computers = #"[{"general":{"id":"1","name":"A"},"hardware":{"serialNumber":"SYNTH0000001"}},"#
            + #"{"general":{"id":"2","name":"B"},"hardware":{"serialNumber":"SYNTH0000002"}}]"#
        try ReportEngine.saveSnapshot(
            data: Data(computers.utf8), kind: "computers", dataDir: dataDir)
        return ["protect-computers", "protect-alerts"]
    }

    private let open: CollectRouter.Gate = { _, _, _, _, _, _ in
        .proceed(holdsClaim: false, coordinating: false)
    }

    private func run(
        _ yaml: String, pro: Bool = true, proThrows: Bool = false, protect: Bool = true,
        gate: CollectRouter.Gate? = nil
    ) async throws {
        let ws = ws
        let writer: @Sendable () throws -> Void = {
            if pro { try Self.writeMDMSummary() }
        }
        try await CollectRouter.run(
            workspace: WorkspaceID(validating: ws),
            config: try ConfigLoader.loadFromString(yaml), now: .testNoon,
            proCollect: { _, _, _, _, _, _, _ in
                if proThrows { throw ReportEngineError.collectDead(profile: ws, failedCount: 3) }
                ReportEngine.landedSources?.record(.jamfPro, ["computers"])
                try writer()
                return .collected
            },
            schoolCollect: { _, _, _, _, _, _ in
                ReportEngine.landedSources?.record(.jamfSchool, ["school-devices"])
                try writer()
            },
            protectCollect: { _, dataDir, _ in protect ? try Self.landProtect(dataDir, inventory: pro) : [] },
            resolved: { _ in nil }, gate: gate ?? open, onLine: { _ in })
    }

    func testProPlusProtectRecordsProductsAndFigures() async throws {
        try makeRoot()
        try await run(proFile)
        let s = try summary()
        XCTAssertEqual(s.products, ["jamf_pro", "protect"])
        XCTAssertEqual(s.protectComputerCount, 3)
        XCTAssertEqual(s.protectOpenAlerts, 2)
        XCTAssertEqual(s.protectAlertCounts, ["high": 1, "medium": 1])
        XCTAssertEqual(try XCTUnwrap(s.protectMatchedPct), 66.7, accuracy: 0.01)
    }

    func testFailedMDMWithProtectAndNoSummaryWritesNone() async throws {
        try makeRoot()
        do {
            try await run(proFile, pro: false, proThrows: true)
            XCTFail("expected the verdict")
        } catch let error as ReportEngineError {
            guard case .collectDead = error else { return XCTFail("got \(error)") }
        }
        XCTAssertThrowsError(try summary())
    }

    func testFailedMDMKeepsAnExistingSummaryAndAddsProtect() async throws {
        try makeRoot()
        try Self.writeMDMSummary()
        do { try await run(proFile, pro: false, proThrows: true) } catch {}
        XCTAssertEqual(try summary().products, ["protect"])
        XCTAssertEqual(try summary().totalDevices, 5)
    }

    func testProtectOnlyWritesAMacLessSummaryWithFigures() async throws {
        try makeRoot()
        try await run("profiles:\n  protect: \(ws)\n", pro: false)
        let s = try summary()
        XCTAssertEqual(s.totalDevices, 0)
        XCTAssertNil(s.mobile)
        XCTAssertEqual(s.products, ["protect"])
        XCTAssertEqual(s.protectComputerCount, 3)
        XCTAssertNil(s.protectMatchedPct)
    }

    func testASecondRunTheSameDayUnionsProducts() async throws {
        try makeRoot()
        try await run(proFile, protect: false)
        XCTAssertEqual(try summary().products, ["jamf_pro"])
        try await run(proFile)
        XCTAssertEqual(try summary().products, ["jamf_pro", "protect"])
    }

    func testAGateStopRunsNoFinalize() async throws {
        try makeRoot()
        try await run(proFile, gate: { _, _, _, _, _, _ in .stop(.alreadyCollected) })
        XCTAssertThrowsError(try summary())
    }

    func testSchoolPlusProtect() async throws {
        try makeRoot()
        try await run("profiles:\n  jamf_school: \(ws)\n  protect: finws-protect\n")
        XCTAssertEqual(try summary().products, ["jamf_school", "protect"])
    }
}
