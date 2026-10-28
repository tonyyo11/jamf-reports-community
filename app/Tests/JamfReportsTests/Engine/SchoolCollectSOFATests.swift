import XCTest
@testable import JamfReports

/// A Jamf School collect fetches the SOFA feed as the Jamf Pro collect does, before it writes
/// the daily summary, so the summary's OS currency has a source. Stubs: a jamf-cli not named
/// `jamf-cli` (codesign gate) and an injected SOFA fetch, so nothing reaches the network.
final class SchoolCollectSOFATests: XCTestCase {
    private var root: URL!
    private let profile = "school-sofa"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-SchoolSOFA-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testTheFeedIsFetchedBeforeTheSummaryAndFeedsItsOSCurrency() async throws {
        let fetches = Counter()
        let lines = try await run(fetch: { dataDir in
            fetches.record()
            return Self.installFeed(into: dataDir)
        })

        XCTAssertEqual(fetches.count, 1)
        XCTAssertTrue(lines.contains("[info] collecting sofa for \(profile)"), "\(lines)")
        XCTAssertTrue(lines.contains("[ok] sofa: feeds refreshed"), "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("[plan] profile \(profile) — collecting")
            && $0.contains("sofa") }, "\(lines)")
        let state = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNotNil(state.lastRun(report: "sofa"))
        let summary = try todaysSummary()
        XCTAssertEqual(summary.osCurrentPct, 50.0)
        XCTAssertEqual(summary.mobile?.osCurrent, .init(met: 0, of: 1))
    }

    func testCollectSkipSOFAFetchesNothingAndLeavesTheCurrencyAbsent() async throws {
        try writeConfig("jamf_cli:\n  profile: \"\(profile)\"\n  collect_skip: [sofa]\n")
        let fetches = Counter()
        let lines = try await run(fetch: { _ in fetches.record(); return (.empty, []) })

        XCTAssertEqual(fetches.count, 0)
        XCTAssertTrue(lines.contains("[skip] sofa: listed in jamf_cli.collect_skip"), "\(lines)")
        XCTAssertTrue(
            lines.contains("[plan] skipping 1 source (jamf_cli.collect_skip): sofa"), "\(lines)")
        XCTAssertFalse(lines.contains("[info] collecting sofa for \(profile)"))
        let state = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNil(state.lastRun(report: "sofa"))
        let summary = try todaysSummary()
        XCTAssertNil(summary.osCurrentPct)
        XCTAssertNil(summary.mobile?.osCurrent)
    }

    /// A failed fetch warns and records a failure; the collect still succeeds and is not Partial.
    func testAFailedFetchKeepsTheCollectSuccessful() async throws {
        let lines = try await run(fetch: { _ in (.empty, ["SOFA: macos unreachable"]) })

        XCTAssertTrue(lines.contains("[warn] sofa: no feed data — kept the previous cache"),
                      "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("[partial]") }, "\(lines)")
        let state = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNotNil(state.failures(report: "sofa"))
        XCTAssertEqual(try todaysSummary().totalDevices, 2)
    }

    func testTheSourcesPlanListsSOFAForASchoolWorkspace() {
        func sofa(skip: Set<String>) -> CollectSourcesPlan.Source? {
            var inputs = CollectSourcesPlan.Inputs(product: .jamfSchool, profile: profile)
            inputs.collectSkip = skip
            return CollectSourcesPlan.build(inputs).sources.first { $0.kind == "sofa" }
        }
        XCTAssertNil(sofa(skip: [])?.skipReason)
        XCTAssertEqual(sofa(skip: ["sofa"])?.skipReason, "listed in jamf_cli.collect_skip")
    }

    // MARK: - Helpers

    private static let devices = """
    [{"name":"Lab Mac 01","serialNumber":"M1","os":"macOS 14.3","isManaged":true,
      "lastCheckin":"2026-10-18 09:00:00","inTrash":false,"udid":"u1"},
     {"name":"Lab Mac 02","serialNumber":"M2","os":"macOS 26.6.2","isManaged":true,
      "lastCheckin":"2026-10-18 09:00:00","inTrash":false,"udid":"u2"},
     {"name":"Cart iPad 01","serialNumber":"I1","os":"iPadOS 27.0.1","isManaged":true,
      "lastCheckin":"2026-10-18 09:00:00","inTrash":false,"udid":"u3"},
     {"name":"Cart iPad 02","serialNumber":"I2","os":"iPadOS 18.1","isManaged":true,
      "lastCheckin":"2026-10-18 09:00:00","inTrash":false,"udid":"u4"}]
    """

    private static func installFeed(
        into dataDir: URL
    ) -> (SOFAFeedService.Snapshot, [String]) {
        let sofa = dataDir.appendingPathComponent("sofa", isDirectory: true)
        try? FileManager.default.createDirectory(at: sofa, withIntermediateDirectories: true)
        for name in ["macos_data_feed.json", "ios_data_feed.json"] {
            try? FileManager.default.copyItem(
                at: TestFixtures.dir("sofa").appendingPathComponent(name),
                to: sofa.appendingPathComponent(name))
        }
        return (SOFAFeedService.load(dataDir: dataDir), [])
    }

    private func writeConfig(_ yaml: String) throws {
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try yaml.write(to: workspace.appendingPathComponent("config.yaml"),
                       atomically: true, encoding: .utf8)
    }

    /// Answers `--version` as a current jamf-cli, the School device list with `devices`, and
    /// every other command with an empty list.
    private func makeStub() throws -> URL {
        let fleet = root.appendingPathComponent("bin/devices.json")
        try Self.devices.write(to: fleet, atomically: true, encoding: .utf8)
        let stub = root.appendingPathComponent("bin/stub-cli")
        try """
        #!/bin/sh
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
        case "$*" in
          *--version*) echo "jamf-cli version 1.31.1" ;;
          *"school devices list"*) cat "\(fleet.path)" ;;
          *) printf '[]' ;;
        esac
        exit 0
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    private func run(
        fetch: @escaping ReportEngine.SOFARefresh
    ) async throws -> [String] {
        let lines = LineBox()
        let stub = try makeStub()
        try await ReportEngine.schoolCollect(
            profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.refresh],
            force: true, locateJamfCLI: { stub }, refreshSOFA: fetch, now: .testNoon,
            onLine: lines.append)
        return lines.texts
    }

    private func todaysSummary() throws -> DailySummary {
        let dir = try WorkspacePaths.summariesDir(for: profile)
        let name = "summary_\(SummaryJSONParser.dateFormatter.string(from: .testNoon)).json"
        return try SummaryJSONParser.decode(Data(contentsOf: dir.appendingPathComponent(name)))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func record() { lock.withLock { calls += 1 } }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var texts: [String] { lock.withLock { storage } }
    func append(_ line: CLIBridge.LogLine) { lock.withLock { storage.append(line.text) } }
}
