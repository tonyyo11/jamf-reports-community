import XCTest
@testable import JamfReports

/// One inventory collect against a stub that answers the opt-in admin-hygiene commands from the
/// captured fixtures: nothing runs until `collect_opt_in` lists the source, and what lands is
/// counts only.
final class AdminHygieneCollectTests: XCTestCase {

    private var root: URL!
    private let profile = "hygienecapture"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Hygiene-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        ProfileAuthMethod.invalidateCache()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func writeConfig(optIn: String?) throws {
        let list = optIn.map { "\n  collect_opt_in: \($0)" } ?? ""
        let ws = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try "jamf_cli:\n  profile: \"\(profile)\"\(list)\n".write(
            to: ws.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
    }

    private func fixture(_ name: String) -> String {
        TestFixtures.dir("server-health/\(name)").path
    }

    /// Returns the argument lines the stub saw for the three opt-in commands.
    private func collect() async throws -> [String] {
        let calls = root.appendingPathComponent("calls")
        let stub = root.appendingPathComponent("stub-cli")
        let script = """
        #!/bin/sh
        [ "$1" = "--version" ] && { echo "jamf-cli version 1.38.0"; exit 0; }
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
        case "$*" in
          *pending-rotations*) echo laps >> "\(calls.path)"; cat "\(fixture("laps-pending-rotations-list.json"))" ;;
          *"pro accounts list"*) echo accounts >> "\(calls.path)"; cat "\(fixture("admin-accounts-list.json"))" ;;
          *api-integrations*) echo api >> "\(calls.path)"; cat "\(fixture("api-integrations-list.json"))" ;;
          *) printf '[]' ;;
        esac
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        _ = try await ReportEngine.collect(
            workspace: WorkspaceID(validating: profile), profile: profile,
            workspacePaths: WorkspacePaths.self, tiers: [.inventory], force: true,
            locateJamfCLI: { stub }, onLine: { _ in })
        return ((try? String(contentsOf: calls, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private func saved(_ kind: String) throws -> String? {
        let dir = try WorkspacePaths.dataDir(for: profile).appendingPathComponent(kind)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return nil }
        return try names
            .filter { $0.hasSuffix(".json") && $0 != "manifest.json" }.first
            .map { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }
    }

    func testNothingRunsUntilTheSourceIsListed() async throws {
        try writeConfig(optIn: nil)
        let seen = try await collect()
        XCTAssertEqual(seen, [])
        for kind in ReportEngine.serverHealthOptInKinds { XCTAssertNil(try saved(kind), kind) }
    }

    func testAListedSourceRunsAndLandsCountsOnly() async throws {
        try writeConfig(optIn: "[admin-accounts, api-integrations, laps-pending-rotations]")
        let seen = try await collect()
        XCTAssertEqual(Set(seen), ["accounts", "api", "laps"])
        let accounts = try XCTUnwrap(try saved("admin-accounts"))
        let api = try XCTUnwrap(try saved("api-integrations"))
        let laps = try XCTUnwrap(try saved("laps-pending-rotations"))
        XCTAssertTrue(accounts.contains("\"fullAccessLocal\":1"), accounts)
        XCTAssertTrue(api.contains("\"enabledWithTokenOverOneDay\":1"), api)
        XCTAssertTrue(laps.contains("\"totalCount\":1"), laps)
        for text in [accounts, api, laps] {
            for leaked in ["example", "Example", "clientId", "000000"] {
                XCTAssertFalse(text.contains(leaked), "\(leaked) in \(text)")
            }
        }
    }

    func testOnlyTheListedSourceRuns() async throws {
        try writeConfig(optIn: "[api-integrations]")
        let seen = try await collect()
        XCTAssertEqual(seen, ["api"])
        XCTAssertNil(try saved("admin-accounts"))
    }
}
