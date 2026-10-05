import XCTest
@testable import JamfReports

/// `sofa` in `jamf_cli.collect_skip`: the SOFA feed is the one fetch `collect` makes from a
/// third-party host, so a network that must not reach it needs a way to turn it off, including
/// for headless scheduled runs. Drives `collect(tiers: [.refresh])` against a stub that is NOT
/// named `jamf-cli` (codesign gate) and a stub SOFA refresh, so nothing reaches the network.
final class CollectSOFASkipTests: XCTestCase {

    private var root: URL!
    private let profile = "sofaskip"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-SOFASkip-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Pure rules

    func testSOFACanBeSkippedAndPatchReleaseDatesCannot() {
        XCTAssertEqual(ReportEngine.collectSkipKinds(["SOFA", " sofa "]), ["sofa"])
        XCTAssertTrue(
            ReportEngine.collectSkipKinds(["patch_release_dates"]).isEmpty,
            "patch-release-dates asks the Jamf server through jamf-cli, not a third party")
    }

    func testFreshnessDoesNotExpectASkippedSOFA() {
        func expected(_ skip: Set<String>) -> Set<String> {
            Set(WorkspaceStore.expectedKinds(
                skipExpensive: false, authMethod: "oauth2", collectSkip: skip))
        }
        XCTAssertTrue(expected([]).contains("sofa"))
        XCTAssertFalse(expected(["sofa"]).contains("sofa"))
        XCTAssertTrue(expected(["sofa"]).contains("patch-release-dates"))
    }

    func testSourcesAfterTheMatrixLoseOnlyTheSkippedOne() {
        XCTAssertEqual(
            ReportEngine.sourcesAfterMatrix(tiers: [.refresh], collectSkip: ["sofa"]),
            ["patch-release-dates"])
        XCTAssertEqual(
            ReportEngine.skippedAfterMatrix(tiers: [.refresh], collectSkip: ["sofa"]), ["sofa"])
        XCTAssertEqual(
            ReportEngine.skippedAfterMatrix(tiers: [.inventory], collectSkip: ["sofa"]), [],
            "a tier that is not selected is not a skip")
    }

    func testThePlanNamesTheSkippedSourceUnderTheCollectSkipGroup() {
        let lines = ReportEngine.collectPlanLines(
            profile: profile, plan: [], afterMatrix: ["patch-release-dates"],
            afterMatrixSkipped: ["sofa"], deviceScan: .tierNotSelected)
        XCTAssertTrue(lines.contains("[plan] skipping 1 source (jamf_cli.collect_skip): sofa"),
                      "\(lines)")
        XCTAssertTrue(lines.contains("[plan] profile \(profile) — collecting 1 source: "
            + "patch-release-dates"), "\(lines)")
    }

    // MARK: - A real run

    func testASkippedSOFAMakesNoFetchAndLeavesTheCacheAlone() async throws {
        try writeConfig("jamf_cli:\n  profile: \"\(profile)\"\n  collect_skip: [sofa]\n")
        let cache = try writeSOFACache()
        let fetches = FetchCounter()

        let lines = try await run(fetches: fetches)

        XCTAssertEqual(fetches.count, 0, "collect_skip: [sofa] must not reach the SOFA host")
        XCTAssertTrue(lines.contains("[skip] sofa: listed in jamf_cli.collect_skip"), "\(lines)")
        XCTAssertFalse(lines.contains("[info] collecting sofa for \(profile)"))
        XCTAssertTrue(
            lines.contains { $0.hasPrefix("[plan] skipping 1 source (jamf_cli.collect_skip)") },
            "\(lines)")
        XCTAssertEqual(try Data(contentsOf: cache.url), cache.data, "the cached feed is kept")
        let state = StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
        XCTAssertNil(state.lastRun(report: "sofa"), "a skipped source records nothing")
        XCTAssertNil(state.failures(report: "sofa"))
    }

    func testPatchReleaseDatesStillRunsWhenSOFAIsSkipped() async throws {
        try writeConfig("jamf_cli:\n  profile: \"\(profile)\"\n  collect_skip: [sofa]\n")

        let lines = try await run(fetches: FetchCounter())

        XCTAssertTrue(lines.contains("[info] collecting patch-release-dates for \(profile)"),
                      "\(lines)")
    }

    /// The control: without the entry the same run fetches, so the test above is not passing
    /// because the stub or the tier never reached the fetch.
    func testSOFAIsFetchedWhenNothingSkipsIt() async throws {
        try writeConfig("jamf_cli:\n  profile: \"\(profile)\"\n")
        let fetches = FetchCounter()

        let lines = try await run(fetches: fetches)

        XCTAssertEqual(fetches.count, 1)
        XCTAssertTrue(lines.contains("[info] collecting sofa for \(profile)"), "\(lines)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("[skip] sofa") })
    }

    /// Without a cache the currency numbers have no source: absent, never 0.
    func testASkippedSOFAWithNoCacheLeavesTheCurrencyFactorsWithoutData() async throws {
        try writeConfig("jamf_cli:\n  profile: \"\(profile)\"\n  collect_skip: [sofa]\n")

        _ = try await run(fetches: FetchCounter())

        let dataDir = try WorkspacePaths.dataDir(for: profile)
        XCTAssertNil(SOFAScoreFeed.load(dataDir: dataDir))
        XCTAssertTrue(SOFAFeedService.load(dataDir: dataDir).rows.isEmpty)
        XCTAssertNil(ReportEngine.osCurrentPercent(
            macOSRows: [], osCounts: ["26.0": 10], totalDevices: 10))
    }

    // MARK: - Helpers

    private func writeConfig(_ yaml: String) throws {
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try yaml.write(to: workspace.appendingPathComponent("config.yaml"),
                       atomically: true, encoding: .utf8)
    }

    /// A feed on disk, as an earlier collect left it.
    private func writeSOFACache() throws -> (url: URL, data: Data) {
        let dir = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent("sofa", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("macos_data_feed.json")
        let data = Data(#"{"OSVersions": [], "XProtectPayloads": {}}"#.utf8)
        try data.write(to: url)
        return (url, data)
    }

    /// A stub jamf-cli that answers every command with an empty list.
    private func makeStub() throws -> URL {
        let stub = root.appendingPathComponent("bin/stub-cli")
        try "#!/bin/sh\nprintf '[]'\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    private func run(fetches: FetchCounter) async throws -> [String] {
        let lines = SOFASkipLineCollector()
        let stub = try makeStub()
        _ = try await ReportEngine.collect(
            profile: profile, workspacePaths: WorkspacePaths.self, tiers: [.refresh],
            force: true, authConfirmationProbe: { _, _ in false },
            locateJamfCLI: { stub },
            refreshSOFA: { _ in fetches.record(); return (.empty, []) },
            onLine: lines.append)
        return lines.texts
    }
}

private final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int { lock.withLock { calls } }
    func record() { lock.withLock { calls += 1 } }
}

private final class SOFASkipLineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var texts: [String] { lock.withLock { storage } }
    func append(_ line: CLIBridge.LogLine) { lock.withLock { storage.append(line.text) } }
}
