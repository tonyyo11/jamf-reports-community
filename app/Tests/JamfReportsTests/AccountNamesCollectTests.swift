import XCTest
@testable import JamfReports

/// `collect` resolves `jamf_cli.keep_account_names` through the shared-config pin: on a shared
/// workspace an unconfirmed `true` removes names, a confirmed one keeps them. The stub is not
/// named `jamf-cli` (codesign gate) and answers `computers list` with one row.
final class AccountNamesCollectTests: XCTestCase {

    private var root: URL!
    private let profile = "namesprof"
    private let row = #"[{"id":"1","general":{"name":"Mac-A","#
        + #""lastLoggedInUsernameMdm":"placeholder"}}]"#

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-Names-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
        let workspace = try XCTUnwrap(ProfileService.workspaceURL(for: profile))
        try """
        shared_workspace:
          enabled: true
          min_collect_interval_hours: 0
        jamf_cli:
          profile: "\(profile)"
          keep_account_names: true
        """.write(to: workspace.appendingPathComponent("config.yaml"),
                  atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testAnUnconfirmedTrueOnASharedWorkspaceStillRemovesNames() async throws {
        try await collect()
        XCTAssertFalse(try savedComputers().contains("lastLoggedInUsernameMdm"))
    }

    func testAConfirmedTrueKeepsThem() async throws {
        _ = SharedConfigPin.check(profile: profile)
        try SharedConfigPin.confirm(profile: profile, keys: [.keepAccountNames])
        try await collect()
        XCTAssertTrue(try savedComputers().contains("lastLoggedInUsernameMdm"))
    }

    private func savedComputers() throws -> String {
        let dir = try WorkspacePaths.dataDir(for: profile)
            .appendingPathComponent("computers", isDirectory: true)
        let file = try XCTUnwrap(FileManager.newestJSONFile(in: dir), "no computers snapshot")
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func collect() async throws {
        let stub = root.appendingPathComponent("stub-cli")
        try """
        #!/bin/sh
        [ "$1 $2" = "config list" ] && { printf '%s' '[{"name":"\(profile)"}]'; exit 0; }
        case "$*" in
          --version) echo "jamf-cli version 1.31.1"; exit 0 ;;
          *"computers list"*) printf '%s' '\(row)'; exit 0 ;;
          *) printf '[]'; exit 0 ;;
        esac
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        try await ReportEngine.collect(
            workspace: WorkspaceID(validating: profile), profile: profile,
            workspacePaths: WorkspacePaths.self, tiers: [.inventory], force: true,
            locateJamfCLI: { stub }, onLine: { _ in })
    }
}
