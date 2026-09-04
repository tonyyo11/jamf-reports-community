import XCTest
@testable import JamfReports

/// `ConfigDoctorService.cloudStorageInputs` and `.workspaceContinuityInputs` are the
/// disk-scanning assemblers behind the pure `evaluateCloudStorage`/
/// `evaluateWorkspaceContinuity` rules — `ConfigDoctorCloudStorageTests` and
/// `WorkspaceContinuityTests` already pin the rules against hand-built input structs,
/// but nothing calls the assemblers themselves. These tests exercise the real
/// filesystem wiring under `JRC_TEST_WORKSPACES_ROOT`: a peer's activity/claim files
/// on disk reaching `otherHosts`/`claim`, and the active root's summaries reaching
/// `activeSummaryCount`. `workspaceContinuityInputs`'s second candidate root
/// (`WorkspaceRootStore.defaultRoot`) has no test seam — it is hardcoded to the real
/// `~/Jamf-Reports` — so its `elsewhere` population is intentionally left to
/// `WorkspaceContinuityTests`'s pure-evaluator coverage rather than exercised here.
final class ConfigDoctorAssemblerTests: XCTestCase {

    private var root: URL!
    private let profile = "doctorassembler"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JRC-DoctorAssembler-\(UUID().uuidString)", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("Jamf-Reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspacesRoot.appendingPathComponent(profile, isDirectory: true),
            withIntermediateDirectories: true
        )
        setenv("JRC_TEST_WORKSPACES_ROOT", workspacesRoot.path, 1)
        addTeardownBlock { unsetenv("JRC_TEST_WORKSPACES_ROOT") }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Helpers (mirroring SharedWorkspaceCollectGateTests)

    /// Writes a peer's activity file directly — `SharedWorkspace.recordActivity`
    /// can only ever write *this* machine's.
    private func writePeerActivity(id: String, name: String, collectedAt: Date) throws {
        let dir = ProfileService.workspaceURL(for: profile)!
            .appendingPathComponent("automation/hosts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let activity = SharedWorkspace.HostActivity(
            host: SharedWorkspace.Host(id: id, name: name),
            lastCollectAt: collectedAt,
            appVersion: SharedWorkspace.appVersion
        )
        try encoder.encode(activity)
            .write(to: dir.appendingPathComponent("\(id).json"))
    }

    private func writePeerClaim(hostId: String, expiresIn: TimeInterval) throws {
        let dir = ProfileService.workspaceURL(for: profile)!
            .appendingPathComponent("automation", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let claim = SharedWorkspace.Claim(
            host: SharedWorkspace.Host(id: hostId, name: "busy-mac"),
            operation: "collect",
            startedAt: Date().addingTimeInterval(-60),
            expiresAt: Date().addingTimeInterval(expiresIn),
            pid: 99, appVersion: "2.7.0"
        )
        try encoder.encode(claim).write(to: dir.appendingPathComponent(".workspace-claim.json"))
    }

    private func writeSummaries(count: Int, under root: URL, profile: String) throws {
        let dir = root.appendingPathComponent(profile, isDirectory: true)
            .appendingPathComponent("snapshots/summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<count {
            let name = "summary_2026-01-\(String(format: "%02d", i + 1)).json"
            try Data("{}".utf8).write(to: dir.appendingPathComponent(name))
        }
    }

    // MARK: - cloudStorageInputs: peer activity + claim reach the assembled struct

    func testCloudStorageInputsReadsPeerActivityAndClaimFromDisk() throws {
        try writePeerActivity(id: "PEER-1", name: "their-mac", collectedAt: Date())
        try writePeerClaim(hostId: "PEER-BUSY", expiresIn: 900)

        let config = ReportConfig(sharedWorkspace: SharedWorkspaceConfig(enabled: true))
        let inputs = ConfigDoctorService.cloudStorageInputs(profile: profile, config: config)

        XCTAssertTrue(inputs.coordinationEnabled, "enabled:true must force coordination on")
        XCTAssertEqual(inputs.otherHosts.map(\.host.id), ["PEER-1"],
                        "otherHosts must be populated from the on-disk activity file")
        XCTAssertEqual(inputs.claim?.host.id, "PEER-BUSY",
                        "claim must be populated from the on-disk claim file")
    }

    /// With coordination off, the assembler must not surface disk state that
    /// exists but is not in play — it gates on `coordinationEnabled` before
    /// reading `otherHosts`/`claim` at all.
    func testCloudStorageInputsIgnoresPeerFilesWhenCoordinationIsOff() throws {
        try writePeerActivity(id: "PEER-1", name: "their-mac", collectedAt: Date())
        try writePeerClaim(hostId: "PEER-BUSY", expiresIn: 900)

        let inputs = ConfigDoctorService.cloudStorageInputs(profile: profile, config: nil)

        XCTAssertFalse(inputs.coordinationEnabled)
        XCTAssertTrue(inputs.otherHosts.isEmpty)
        XCTAssertNil(inputs.claim)
    }

    // MARK: - workspaceContinuityInputs: active-root summary count from disk

    func testWorkspaceContinuityInputsCountsActiveRootSummariesFromDisk() throws {
        try writeSummaries(count: 3, under: root.appendingPathComponent("Jamf-Reports"),
                            profile: profile)

        let inputs = ConfigDoctorService.workspaceContinuityInputs(profile: profile, config: nil)

        XCTAssertEqual(inputs.activeSummaryCount, 3)
    }
}
