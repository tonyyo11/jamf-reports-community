import XCTest
@testable import JamfReports

/// The Config Doctor's cloud-storage and shared-workspace family. Pure rules —
/// no synced volume and no second Mac required — so the guidance itself is
/// pinned.
final class ConfigDoctorCloudStorageTests: XCTestCase {

    private let home = NSString(string: "~").expandingTildeInPath
    private func local(_ path: String) -> URL {
        URL(fileURLWithPath: "\(home)/Jamf-Reports/\(path)")
    }
    private func cloud(_ path: String) -> URL {
        URL(fileURLWithPath: "\(home)/Library/CloudStorage/OneDrive-Contoso/\(path)")
    }

    private func host(_ name: String, id: String? = nil) -> SharedWorkspace.Host {
        SharedWorkspace.Host(id: id ?? "id-\(name)", name: name)
    }

    private func activity(
        _ name: String,
        collectedAt: Date?,
        version: String = SharedWorkspace.appVersion
    ) -> SharedWorkspace.HostActivity {
        SharedWorkspace.HostActivity(
            host: host(name), lastCollectAt: collectedAt, appVersion: version
        )
    }

    private func inputs(
        workspace: URL? = nil, output: URL? = nil, archive: URL? = nil,
        backups: URL? = nil, conflicts: [String] = [],
        rootValidation: WorkspaceRootStore.Validation = .ok,
        rootIsCustom: Bool = false,
        coordinationEnabled: Bool = false,
        coordinationExplicit: Bool = false,
        otherHosts: [SharedWorkspace.HostActivity] = [],
        claim: SharedWorkspace.Claim? = nil,
        now: Date = Date()
    ) -> CloudStorageInputs {
        CloudStorageInputs(
            workspaceRoot: workspace ?? local(""),
            rootValidation: rootValidation,
            rootIsCustom: rootIsCustom,
            workspace: workspace,
            outputDir: output, archiveDir: archive, backupsDir: backups,
            conflictCopies: conflicts,
            coordinationEnabled: coordinationEnabled,
            coordinationExplicit: coordinationExplicit,
            minCollectInterval: 12 * 3600,
            otherHosts: otherHosts,
            claim: claim,
            now: now
        )
    }

    // MARK: - Layout shapes

    func testFullyLocalWorkspaceEmitsNothing() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: local("prod"), output: local("prod/Generated Reports"),
            archive: local("prod/Generated Reports/archive"), backups: local("prod/backups")
        ))
        XCTAssertTrue(rows.isEmpty, "the default layout should be silent")
    }

    /// Replaces `testWorkspaceOnCloudWarnsAndRecommendsPublishingInstead`, which
    /// pinned the pre-2.7.0 rule that a synced workspace was always wrong.
    /// Hosting the workspace on a team folder is now a supported shape; the
    /// warning moved to the state that is actually dangerous — see the next
    /// test — so this fixture now asserts the opposite verdict deliberately.
    func testSharedWorkspaceWithCoordinationPasses() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: cloud("Team/Jamf Reports/prod"),
            output: cloud("Team/Jamf Reports/prod/Generated Reports"),
            coordinationEnabled: true
        ))
        let row = rows.first { $0.id == "cloud.workspace" }
        XCTAssertEqual(row?.severity, .pass)
        XCTAssertTrue(row?.title.contains("OneDrive") == true)
    }

    func testSharedWorkspaceWithoutCoordinationWarns() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: cloud("Team/Jamf Reports/prod"),
            coordinationEnabled: false
        ))
        let row = rows.first { $0.id == "cloud.workspace" }
        XCTAssertEqual(row?.severity, .warn, "a synced folder with no coordination is the risk")
        XCTAssertTrue(row?.hint?.contains("shared_workspace.enabled") == true)
    }

    /// An explicit `false` is a decision, not an oversight — the wording has to
    /// tell the operator which of the two they are looking at.
    func testExplicitlyDisabledCoordinationNamesTheSetting() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: cloud("Team/prod"),
            coordinationEnabled: false, coordinationExplicit: true
        ))
        XCTAssertTrue(
            rows.first { $0.id == "cloud.workspace" }?.detail
                .contains("set to false") == true
        )
    }

    /// Coordination fixes collisions. It does not decide who may read device
    /// serials, so that has to be surfaced separately every time.
    func testSharedWorkspaceAlwaysSurfacesTheReadAudience() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: cloud("Team/prod"), coordinationEnabled: true
        ))
        let row = rows.first { $0.id == "cloud.privacy" }
        XCTAssertEqual(row?.severity, .suggest)
        XCTAssertTrue(row?.detail.contains("serials") == true)
    }

    func testPublishOnlyLayoutPasses() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: local("prod"), output: cloud("Team/Jamf Reports"),
            backups: local("prod/backups")
        ))
        XCTAssertEqual(rows.first { $0.id == "cloud.output" }?.severity, .pass)
        XCTAssertNil(rows.first { $0.id == "cloud.workspace" })
    }

    func testArchiveOnCloudWithoutOutputIsFlagged() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: local("prod"), output: local("prod/Generated Reports"),
            archive: cloud("Team/Archive")
        ))
        XCTAssertEqual(rows.first { $0.id == "cloud.archive" }?.severity, .warn)
    }

    func testBackupsOnCloudExplainsHostScopedPruning() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: local("prod"), backups: cloud("Team/backups")
        ))
        let row = rows.first { $0.id == "cloud.backups" }
        XCTAssertEqual(row?.severity, .suggest, "host-scoped pruning is no longer a warning")
        XCTAssertTrue(row?.detail.contains("this Mac made") == true)
    }

    // MARK: - Workspace root

    func testUnreachableRootFailsLoudly() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: cloud("Team/prod"), rootValidation: .missing, rootIsCustom: true
        ))
        let row = rows.first { $0.id == "cloud.root" }
        XCTAssertEqual(row?.severity, .fail)
        XCTAssertTrue(row?.hint?.contains("Settings") == true)
    }

    func testReadOnlyRootExplainsSharePermissions() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: cloud("Team/prod"), rootValidation: .notWritable, rootIsCustom: true
        ))
        XCTAssertEqual(rows.first { $0.id == "cloud.root" }?.severity, .fail)
    }

    func testDefaultRootIsNotAnnounced() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: local("prod"), rootIsCustom: false
        ))
        XCTAssertNil(
            rows.first { $0.id == "cloud.root" }, "silence is the right report for a default"
        )
    }

    // MARK: - Coordination

    func testSoloMachineReportsThatCoordinationIsArmed() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: cloud("Team/prod"), coordinationEnabled: true
        ))
        let row = rows.first { $0.id == "cloud.peers" }
        XCTAssertEqual(row?.severity, .pass)
        XCTAssertTrue(row?.title.contains("only one") == true)
    }

    func testPeersAreListedWithTheirLastCollect() {
        let now = Date()
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: cloud("Team/prod"), coordinationEnabled: true,
            otherHosts: [
                activity("mac-a", collectedAt: now.addingTimeInterval(-3600)),
                activity("mac-b", collectedAt: now.addingTimeInterval(-7200)),
            ],
            now: now
        ))
        let row = rows.first { $0.id == "cloud.peers" }
        XCTAssertEqual(row?.severity, .pass)
        XCTAssertTrue(row?.title.contains("2 other") == true)
        XCTAssertTrue(row?.detail.contains("mac-a") == true)
    }

    /// A pre-2.7.0 build writing to the same folder still orders by mtime and
    /// prunes other machines' backups, so a mixed fleet has to be called out.
    func testMixedAppVersionsWarn() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: cloud("Team/prod"), coordinationEnabled: true,
            otherHosts: [activity("mac-old", collectedAt: Date(), version: "2.6.1")]
        ))
        let row = rows.first { $0.id == "cloud.peerversions" }
        XCTAssertEqual(row?.severity, .warn)
        XCTAssertTrue(row?.detail.contains("2.6.1") == true)
    }

    func testUnknownPeerVersionDoesNotWarn() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: cloud("Team/prod"), coordinationEnabled: true,
            otherHosts: [activity("mac-x", collectedAt: Date(), version: "unknown")]
        ))
        XCTAssertNil(
            rows.first { $0.id == "cloud.peerversions" },
            "an unreported version is not evidence of a mismatch"
        )
    }

    func testLiveClaimFromAnotherHostIsReportedAsNormal() {
        let now = Date()
        let claim = SharedWorkspace.Claim(
            host: host("mac-a"), operation: "collect", startedAt: now.addingTimeInterval(-120),
            expiresAt: now.addingTimeInterval(1800), pid: 42, appVersion: "2.7.0"
        )
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: cloud("Team/prod"), coordinationEnabled: true, claim: claim, now: now
        ))
        let row = rows.first { $0.id == "cloud.claim" }
        XCTAssertEqual(row?.severity, .pass, "a peer working is healthy, not a problem")
        XCTAssertTrue(row?.title.contains("mac-a") == true)
    }

    func testExpiredClaimSaysItSelfHeals() {
        let now = Date()
        let claim = SharedWorkspace.Claim(
            host: host("mac-a"), operation: "collect", startedAt: now.addingTimeInterval(-86_400),
            expiresAt: now.addingTimeInterval(-80_000), pid: 42, appVersion: "2.7.0"
        )
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: cloud("Team/prod"), coordinationEnabled: true, claim: claim, now: now
        ))
        let row = rows.first { $0.id == "cloud.claim" }
        XCTAssertEqual(row?.severity, .suggest)
        XCTAssertTrue(row?.detail.contains("takes it over") == true)
    }

    func testClockSkewOnAPeerIsWarned() {
        let now = Date()
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: cloud("Team/prod"), coordinationEnabled: true,
            otherHosts: [activity("mac-fast", collectedAt: now.addingTimeInterval(3600))],
            now: now
        ))
        let row = rows.first { $0.id == "cloud.clockskew" }
        XCTAssertEqual(row?.severity, .warn)
        XCTAssertTrue(row?.detail.contains("mac-fast") == true)
    }

    func testSmallClockDifferencesAreTolerated() {
        let now = Date()
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: cloud("Team/prod"), coordinationEnabled: true,
            otherHosts: [activity("mac-close", collectedAt: now.addingTimeInterval(60))],
            now: now
        ))
        XCTAssertNil(rows.first { $0.id == "cloud.clockskew" }, "a minute of drift is normal")
    }

    func testCoordinationRowsAreSilentWhenCoordinationIsOff() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: local("prod"), coordinationEnabled: false,
            otherHosts: [activity("mac-a", collectedAt: Date())]
        ))
        XCTAssertNil(rows.first { $0.id == "cloud.peers" })
        XCTAssertNil(rows.first { $0.id == "cloud.clockskew" })
    }

    // MARK: - Conflicts

    func testConflictCopiesAreReportedWithASample() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: local("prod"),
            conflicts: ["summary_2026-08-20 2.json", "computers (1).json",
                        "config copy.yaml", "extra 4.json"]
        ))
        let row = rows.first { $0.id == "cloud.conflicts" }
        XCTAssertEqual(row?.severity, .warn)
        XCTAssertTrue(row?.title.contains("4 sync-conflict") == true)
        XCTAssertTrue(row?.detail.contains("+1 more") == true)
    }

    /// With coordination on, an occasional conflict copy is expected overlap
    /// rather than evidence of an unknown writer — so it drops to a suggestion
    /// and the advice changes from "find the other writer" to "space the runs".
    func testConflictCopiesAreDownweightedWhenCoordinating() {
        let rows = ConfigDoctorService.evaluateCloudStorage(inputs(
            workspace: cloud("Team/prod"), conflicts: ["summary_2026-08-20 2.json"],
            coordinationEnabled: true
        ))
        let row = rows.first { $0.id == "cloud.conflicts" }
        XCTAssertEqual(row?.severity, .suggest)
        XCTAssertTrue(row?.hint?.contains("min_collect_interval_hours") == true)
    }
}
