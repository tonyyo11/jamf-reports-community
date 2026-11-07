import XCTest
@testable import JamfReports

/// A `profiles:` block with only `protect` is a workspace that collects Protect, writes a
/// daily summary, and still refuses every Jamf Pro command.
final class ProtectOnlyCollectTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private struct Boom: Error {}

    private let ws = "protectws"
    private var config: ReportConfig {
        get throws { try ConfigLoader.loadFromString("profiles:\n  protect: \(ws)\n") }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectOnly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(ws, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func run(
        landed: Int = 1, throwing: Bool = false, calls: Box, lines: Box? = nil,
        gate: @escaping CollectRouter.Gate = CollectRouter.realGate
    ) async throws {
        try await CollectRouter.run(
            workspace: WorkspaceID(validating: ws), config: try config, now: .testNoon,
            proCollect: { _, _, _, _, _, _, _ in calls.add("pro"); return .collected },
            schoolCollect: { _, _, _, _, _, _ in calls.add("school") },
            protectCollect: { profile, dataDir, _ in
                calls.add("protect \(profile)")
                if throwing { throw Boom() }
                if landed > 0 {
                    StateFileStore(directory: dataDir.appendingPathComponent("state"))
                        .record(.landed, report: "protect-alerts", at: Date())
                }
                return landed
            },
            resolved: { _ in nil }, gate: gate, onLine: { lines?.add($0.text) })
    }

    private func summary() throws -> [String: Any] {
        let dir = try WorkspacePaths.summariesDir(for: ws)
        let day = SummaryJSONParser.dateFormatter.string(from: .testNoon)
        let data = try Data(contentsOf: dir.appendingPathComponent("summary_\(day).json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testProtectOnlyCollectsProtectAndWritesASummary() async throws {
        _ = try makeRoot()
        let calls = Box(), lines = Box()
        try await run(calls: calls, lines: lines)
        XCTAssertEqual(calls.all, ["protect \(ws)"])
        XCTAssertTrue(lines.all.contains { $0.contains("routing \(ws) → Jamf Protect collect") })
        let obj = try summary()
        XCTAssertEqual(obj["totalDevices"] as? Int, 0)
        XCTAssertEqual(obj["source"] as? String, "jamf-cli")
        XCTAssertNil(obj["mobileDeviceCount"])
        XCTAssertNil(obj["mobile"])
        XCTAssertNil(obj["fileVaultPct"])
        XCTAssertEqual((obj["collectionSources"] as? [String: String])?["protect-alerts"], "live")
    }

    func testASecondFullCollectTheSameDayIsStoppedByTheDayGuard() async throws {
        _ = try makeRoot()
        let calls = Box()
        try await run(calls: calls)
        try await run(calls: calls)
        XCTAssertEqual(calls.all, ["protect \(ws)"])
    }

    func testAThrowingProtectCollectFailsTheRun() async throws {
        _ = try makeRoot()
        do {
            try await run(throwing: true, calls: Box())
            XCTFail("expected a throw")
        } catch is Boom {}
    }

    func testNoLandedSourceIsADeadRunWithNoSummary() async throws {
        _ = try makeRoot()
        do {
            try await run(landed: 0, calls: Box())
            XCTFail("expected collectDead")
        } catch let error as ReportEngineError {
            guard case .collectDead = error else { return XCTFail("got \(error)") }
        }
        XCTAssertThrowsError(try summary())
    }

    func testASummaryThatCountedMacsIsNotReplaced() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectOnlySummary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let day = SummaryJSONParser.dateFormatter.string(from: .testNoon)
        let file = dir.appendingPathComponent("summary_\(day).json")
        let counted = DailySummary(
            date: day, totalDevices: 5, fileVaultPct: nil, compliancePct: nil, staleCount: nil,
            osCurrentPct: nil, crowdstrikePct: nil, patchPct: nil, source: "jamf-cli")
        XCTAssertTrue(ReportEngine.writeSummaryFile(counted, to: file, onLine: nil))
        let outcome = ReportEngine.writeProtectOnlySummary(
            summariesDir: dir, dataDir: dir, landedKinds: ["protect-alerts"], day: .testNoon,
            onLine: { _ in })
        XCTAssertEqual(outcome, .keptExisting)
    }

    func testProCommandsRefuseAProtectOnlyEnvironment() async throws {
        let config = try config
        let sentence = "'\(ws)' holds only a Jamf Protect profile; "
        XCTAssertEqual(
            CollectRouter.backupRefusal(profile: ws, config: config),
            sentence + "Backup needs Jamf Pro.")
        let audit = await CLIBridge.refusesProCommand(
            profile: ws, operation: "Audit", onLine: nil,
            environment: EnvironmentProfiles.resolve(config: config, workspace: ws),
            resolved: { _ in nil })
        XCTAssertEqual(audit, sentence + "Audit needs Jamf Pro.")
        XCTAssertThrowsError(try CLIBridge.backupProfile(
            for: ws, environment: EnvironmentProfiles.resolve(config: config, workspace: ws),
            onLine: { _ in }))
        XCTAssertNil(CollectRouter.proRunRefusal(profile: ws, operation: "Collect", config: config))
    }
}
