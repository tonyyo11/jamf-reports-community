import XCTest
@testable import JamfReports

/// `CollectRouter` hands every product the list this Mac confirmed, never the file's.
final class CollectSkipRouterTests: XCTestCase {
    private let profile = "routerskip"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jrc-routerskip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(profile), withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private var configURL: URL {
        root.appendingPathComponent(profile).appendingPathComponent("config.yaml")
    }

    /// Writes `body` with `skip` as the list, pins it on this Mac and confirms every key, then
    /// a peer rewrites the list to `peer`.
    private func pinned(_ body: String, skip: String, peer: String) throws -> ReportConfig {
        let text = { (list: String) in
            "shared_workspace:\n  enabled: true\n" + body + "jamf_cli:\n  collect_skip: \(list)\n"
        }
        try text(skip).write(to: configURL, atomically: true, encoding: .utf8)
        try SharedConfigPin.confirm(
            profile: profile, drifts: SharedConfigPin.check(profile: profile).drifts)
        try text(peer).write(to: configURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(SharedConfigPin.check(profile: profile).isDrifted(.collectSkip))
        return try ConfigLoader.load(from: configURL)
    }

    private let proceed: CollectRouter.Gate = { _, _, _, _, _, _ in
        .proceed(holdsClaim: false, coordinating: false)
    }

    func testProtectAndSecurityCloudGetThePinnedList() async throws {
        let config = try pinned(
            "profiles:\n  jamf_pro: \"\(profile)\"\n  protect: \"my-protect\"\n"
                + "  security_cloud: \"my-sc\"\n",
            skip: "[protect-alerts, security-risk]", peer: "[protect-plans]")
        let seen = SkipBox()
        try await CollectRouter.run(
            workspace: WorkspaceID(validating: profile), config: config, now: .testNoon,
            proCollect: { _, _, _, _, _, _, _ in .collected },
            schoolCollect: { _, _, _, _, _, _ in },
            protectCollect: { _, _, skip, _ in seen.add("protect", skip); return [] },
            securityCollect: { _, _, skip, _ in seen.add("security", skip); return [] },
            resolved: { _ in nil }, gate: proceed, onLine: { _ in })
        let expected: Set<String> = ["protect-alerts", "security-risk"]
        XCTAssertEqual(seen.value["protect"], expected)
        XCTAssertEqual(seen.value["security"], expected)
    }

    func testTheSchoolScanPlanTakesThePinnedList() async throws {
        let config = try pinned(
            "school_cli:\n  enabled: true\n", skip: "[school-device-detail]", peer: "[]")
        let plan = PlanBox()
        try await CollectRouter.run(
            workspace: WorkspaceID(validating: profile), config: config, now: .testNoon,
            proCollect: { _, _, _, _, _, _, _ in .collected },
            schoolCollect: { _, _, _, _, _, _ in plan.value = ReportEngine.landedSources?.schoolScanPlan },
            protectCollect: { _, _, _, _ in [] },
            securityCollect: { _, _, _, _ in [] },
            resolved: { _ in nil }, gate: proceed, onLine: { _ in })
        XCTAssertEqual(plan.value, .turnedOff)
    }

    /// A Protect-only environment always collects its computer list, even when it is listed.
    func testAProtectOnlyEnvironmentKeepsProtectComputers() async throws {
        try "profiles:\n  protect: \(profile)\njamf_cli:\n  collect_skip: [protect-computers, protect-alerts]\n"
            .write(to: configURL, atomically: true, encoding: .utf8)
        let seen = SkipBox()
        try await CollectRouter.run(
            workspace: WorkspaceID(validating: profile), config: try ConfigLoader.load(from: configURL),
            now: .testNoon,
            proCollect: { _, _, _, _, _, _, _ in .collected },
            schoolCollect: { _, _, _, _, _, _ in },
            protectCollect: { _, _, skip, _ in
                seen.add("protect", skip); return ["protect-computers"]
            },
            resolved: { _ in nil }, gate: proceed, onLine: { _ in })
        XCTAssertEqual(seen.value["protect"], ["protect-alerts"])
    }
}

private final class SkipBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Set<String>] = [:]
    func add(_ key: String, _ skip: Set<String>) { lock.lock(); stored[key] = skip; lock.unlock() }
    var value: [String: Set<String>] { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class PlanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ReportEngine.SchoolDeviceScanPlan?
    var value: ReportEngine.SchoolDeviceScanPlan? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
