import Foundation
import XCTest
@testable import JamfReports

/// #207 G16, #226 5b: the Overview's heavy-tier prompt judged each tier by one probe
/// kind. It now reads every kind of the tier the profile is expected to collect.
final class HeavyTierStalenessTests: XCTestCase {

    private let profile = "acme"
    private let week: TimeInterval = 7 * 86_400
    private let scanKinds = [
        "patch-device-failures", "update-device-failures", "ddm-device-status",
        "mdm-command-health",
    ]

    /// A workspace under a temporary root; returns its data directory.
    private func makeWorkspace(config: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeavyTierStaleness-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent(profile, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        if let config {
            try Data(config.utf8).write(to: workspace.appendingPathComponent("config.yaml"))
        }
        setenv("JRC_TEST_WORKSPACES_ROOT", root.path, 1)
        addTeardownBlock {
            unsetenv("JRC_TEST_WORKSPACES_ROOT")
            try? FileManager.default.removeItem(at: root)
        }
        return workspace.appendingPathComponent("jamf-cli-data", isDirectory: true)
    }

    /// One snapshot of `kind`, `age` seconds old.
    private func snapshot(
        _ kind: String, in dataDir: URL, age: TimeInterval = 0, ext: String = "json"
    ) throws {
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(kind)_20260930T120000.\(ext)")
        try Data("[]".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: file.path)
    }

    /// The scan prompt probed update-device-failures, so listing that kind in collect_skip
    /// kept the prompt up for good.
    func testAKindInCollectSkipCannotHoldTheScanPromptUp() throws {
        let dataDir = try makeWorkspace()
        for kind in scanKinds where kind != "update-device-failures" {
            try snapshot(kind, in: dataDir)
        }
        let expected = WorkspaceStore.expectedKinds(
            skipExpensive: false, authMethod: "oauth2", collectSkip: ["update-device-failures"])

        let stale = WorkspaceStore.staleTiers(
            profile: profile, olderThan: week, expectedKinds: expected)

        XCTAssertFalse(stale.contains(.scan))
    }

    /// The prompt cleared while ddm-device-status was old, because only the probe kind landed.
    func testAnyExpectedKindPastTheThresholdMakesItsTierStale() throws {
        let dataDir = try makeWorkspace()
        for kind in scanKinds {
            try snapshot(kind, in: dataDir, age: kind == "ddm-device-status" ? 8 * 86_400 : 0)
        }

        let stale = WorkspaceStore.staleTiers(
            profile: profile, olderThan: week, expectedKinds: scanKinds)

        XCTAssertEqual(stale, [.scan], "inventory expects nothing here, so it is never stale")
    }

    func testATierWithNoExpectedKindsIsNeverStale() throws {
        _ = try makeWorkspace()
        let expected = WorkspaceStore.expectedKinds(skipExpensive: true, authMethod: "oauth2")

        let stale = WorkspaceStore.staleTiers(
            profile: profile, olderThan: week, expectedKinds: expected)

        XCTAssertEqual(stale, [.inventory],
                       "the skip-expensive toggle leaves the scan tier nothing to collect")
    }

    /// jamf-cli's dashboard is the one kind saved as a page, not JSON.
    func testTheDashboardCountsByItsHTMLPage() throws {
        let dataDir = try makeWorkspace()
        try snapshot("computers", in: dataDir)
        try snapshot("dashboard", in: dataDir, ext: "html")

        let stale = WorkspaceStore.staleTiers(
            profile: profile, olderThan: week, expectedKinds: ["computers", "dashboard"])

        XCTAssertEqual(stale, [])
    }

    /// "Couldn't be collected" is said of a tier only when what makes it stale is kinds
    /// that never landed; a kind that merely aged out reads as old data.
    func testNoDataOnlyWhenEveryStaleKindNeverLanded() throws {
        let dataDir = try makeWorkspace()
        try snapshot("computers", in: dataDir)
        try snapshot("patch-device-failures", in: dataDir, age: 8 * 86_400)
        let expected = [
            "computers", "update-status", "patch-device-failures", "update-device-failures",
        ]

        let noData = WorkspaceStore.tiersWithNoData(
            profile: profile, among: [.inventory, .scan], expectedKinds: expected,
            olderThan: week)

        XCTAssertEqual(noData, [.inventory])
    }

    /// A failure recorded for `kind` the way collect records one.
    private func recordFailure(
        _ kind: String, exitCode: Int32, cause: FailureCause? = nil
    ) throws {
        StateFileStore(directory: try WorkspacePaths.stateDir(for: profile))
            .record(.failed(exitCode: exitCode), report: kind, at: Date(), cause: cause)
    }

    /// A retry cannot fix Managed Software Update Plans turned off, so update-status never
    /// lands; the health banner names it with its cause, and the prompt's button would only
    /// force the inventory tier again.
    func testAKindThatFailsForAPermanentCauseDoesNotKeepItsTierStale() throws {
        let dataDir = try makeWorkspace()
        try snapshot("computers", in: dataDir)
        try recordFailure("update-status", exitCode: 0, cause: FailureCause(
            kind: .softwareUpdatePlansOff, names: [], hint: nil, exitCode: 0))

        let stale = WorkspaceStore.staleTiers(
            profile: profile, olderThan: week, expectedKinds: ["computers", "update-status"])

        XCTAssertEqual(stale, [])
    }

    func testARetryableFailureStillKeepsItsTierStale() throws {
        let dataDir = try makeWorkspace()
        try snapshot("computers", in: dataDir)
        try recordFailure("update-status", exitCode: 1, cause: FailureCause(
            kind: .other, names: [], hint: nil, exitCode: 1))

        let stale = WorkspaceStore.staleTiers(
            profile: profile, olderThan: week, expectedKinds: ["computers", "update-status"])

        XCTAssertEqual(stale, [.inventory])
    }

    /// A first collect landed computers and the server refused one kind for a missing
    /// privilege: the prompt must not read "couldn't be collected" over it.
    func testAKindRefusedOnTheFirstCollectDoesNotReadAsCouldntBeCollected() throws {
        let dataDir = try makeWorkspace()
        try snapshot("computers", in: dataDir)
        try recordFailure("profile-status", exitCode: 5, cause: FailureCause(
            kind: .missingPermission, names: ["Read Computers"], hint: nil, exitCode: 5))
        try recordFailure("policy-status", exitCode: 8)
        let expected = ["computers", "profile-status", "policy-status"]

        let stale = WorkspaceStore.staleTiers(
            profile: profile, olderThan: week, expectedKinds: expected)
        let noData = WorkspaceStore.tiersWithNoData(
            profile: profile, among: [.inventory], expectedKinds: expected, olderThan: week)

        XCTAssertEqual(stale, [])
        XCTAssertEqual(noData, [])
    }

    /// The resolver behind the prompt reads the same inputs as the health strip.
    func testTheProfileResolverAppliesCollectSkipAndTheAuthMethod() throws {
        _ = try makeWorkspace(config: """
            jamf_cli:
              collect_skip:
                - update_device_failures
            """)
        pinSkipExpensiveCollectionsOff(self)

        let expected = WorkspaceStore.expectedKinds(
            profile: profile, jamfCLIVersion: nil,
            auth: .init(authMethod: "oauth2", isTenantLevel: false))

        XCTAssertFalse(expected.contains("update-device-failures"))
        XCTAssertFalse(expected.contains("ddm-status"), "Platform-only on an oauth2 profile")
        XCTAssertFalse(expected.contains("dashboard"), "unknown jamf-cli version")
        XCTAssertTrue(expected.contains("ddm-device-status"))
    }
}

/// Fresh snapshots for every inventory- and scan-tier kind but `skipping`, the
/// dashboard as its page: what a heavy-tier refresh that landed everything leaves.
func landHeavyTierSnapshots(in dataDir: URL, skipping: Set<String> = []) throws {
    for kind in CollectionTier.mappedKinds where !skipping.contains(kind) {
        guard let tier = CollectionTier.tier(forReport: kind), tier != .refresh else { continue }
        let dir = dataDir.appendingPathComponent(kind, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = kind == ReportEngine.dashboardKind ? "html" : "json"
        try Data("[]".utf8).write(to: dir.appendingPathComponent("\(kind)_fresh.\(ext)"))
    }
}

/// Turns the Settings skip-expensive toggle off for one test, so the scan tier
/// expects its kinds whatever an earlier run left in the defaults.
func pinSkipExpensiveCollectionsOff(_ test: XCTestCase) {
    let key = "skipExpensiveCollections"
    let saved = UserDefaults.standard.object(forKey: key) as? Bool
    UserDefaults.standard.set(false, forKey: key)
    test.addTeardownBlock {
        if let saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
