import XCTest
@testable import JamfReports

/// The included CLI's `collect` records Needs attention items into its own run record, the way a
/// scheduled run does.
final class CLIAttentionTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private let profile = "cliattn"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-attention-\(UUID().uuidString)", isDirectory: true)
        let workspaces = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaces.appendingPathComponent(profile).appendingPathComponent("automation"),
            withIntermediateDirectories: true)
        setenv("JRC_TEST_WORKSPACES_ROOT", workspaces.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("JRC_TEST_WORKSPACES_ROOT")
        try? FileManager.default.removeItem(at: root)
    }

    private func collect(_ body: @escaping @Sendable () -> Void) async throws {
        try await Collect.perform(
            profile: profile, tiers: [.refresh], force: true, config: nil,
            proCollect: { _, _, _, _, _, _ in body(); return .collected })
    }

    private func automationFile(_ name: String) throws -> URL {
        try XCTUnwrap(ProfileService.workspaceURL(for: profile))
            .appendingPathComponent("automation").appendingPathComponent(name)
    }

    func testACollectRaisesItsItemIntoTheCLIRunRecordAndALaterPassingCheckClearsIt() async throws {
        try await collect { AttentionLog.raise(.eaSnapshotUnreadable, "ea-results unreadable") }
        XCTAssertEqual(AttentionLog.openItems(profile: profile).map(\.code), [.eaSnapshotUnreadable])

        let label = CLIRunSignals.cliLabel(profile: profile, kind: .collect)
        let status = try automationFile("\(label)_status.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: status)) as? [String: Any]
        XCTAssertEqual((json?["attention"] as? [[String: Any]])?.count, 1)
        XCTAssertNotNil(json?["exit_code"], "the run record is still the CLI run's own")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try automationFile(
            "\(WorkspaceStore.appCollectRunLabel)_status.json").path))

        try await collect { AttentionLog.clear(.eaSnapshotUnreadable) }
        XCTAssertEqual(AttentionLog.openItems(profile: profile), [])
    }
}
