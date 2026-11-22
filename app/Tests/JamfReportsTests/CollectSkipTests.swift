import XCTest
@testable import JamfReports

/// `jamf_cli.collect_skip`, the on-prem stall guard: which names it accepts and
/// what the health strip expects once a kind is listed. The collect-side skip
/// itself is pinned against a stub jamf-cli in `DeviceScanCollectTests`.
final class CollectSkipTests: XCTestCase {

    // MARK: - Normalization

    func testUnderscoresCaseAndWhitespaceAreForgiven() {
        XCTAssertEqual(
            ReportEngine.collectSkipKinds([" Update_Status ", "PATCH_DEVICE_FAILURES"]),
            ["update-status", "patch-device-failures"]
        )
    }

    /// Every source but the core ones can be turned off; turning off `patch-status` also skips
    /// the release-date walk and the failures scan, which start from it.
    func testEveryOptionalSourceCanBeTurnedOff() {
        let all = ["patch-status", "profile-status", "update-status", "dashboard", "sofa",
                   "security-risk", "school-device-detail", "ea-results", "policies",
                   "school-users", "protect-alerts", "protect-computers", "ddm-device-status"]
        XCTAssertEqual(
            ReportEngine.collectSkipKinds(all),
            Set(all + ["patch-release-dates", "patch-device-failures"]))
        XCTAssertEqual(
            ReportEngine.collectSkipKinds(["patch-status"]),
            ["patch-status", "patch-release-dates", "patch-device-failures"])
        XCTAssertFalse(
            ReportEngine.collectSkipKinds(["update-status"]).contains("patch-release-dates"))
        XCTAssertEqual(
            ReportEngine.sourcesAfterMatrix(
                tiers: [.refresh], collectSkip: ReportEngine.collectSkipKinds(["patch_status"])),
            ["sofa"])
        XCTAssertEqual(ReportEngine.listedSkipKinds(["patch-status"]), ["patch-status"],
                       "the dependents are added at read time, never listed")
    }

    /// The core set on an unknown or mixed fleet is locked: the daily summary is built from it.
    /// The mobile list is core only on a mobile-only fleet (`FleetSidesTests`).
    func testTheCoreSourcesAreLocked() {
        let core = ["overview", "security", "inventory-summary", "device-compliance",
                    "computers", "school-devices"]
        XCTAssertTrue(ReportEngine.collectSkipKinds(core).isEmpty)
        for kind in core { XCTAssertTrue(ReportEngine.isCoreKind(kind), kind) }
        XCTAssertEqual(
            ReportEngine.optionalKinds(),
            ReportEngine.allSourceKinds.subtracting(core))
    }

    /// Beside an MDM every Protect source is optional; alone, its computer list is the summary.
    func testAProtectOnlyEnvironmentKeepsItsComputerList() {
        XCTAssertEqual(ReportEngine.collectSkipKinds(["protect-computers"]), ["protect-computers"])
        XCTAssertTrue(
            ReportEngine.collectSkipKinds(["protect-computers"], protectOnly: true).isEmpty)
        XCTAssertTrue(ReportEngine.isCoreKind("protect-computers", protectOnly: true))
        XCTAssertEqual(
            ReportEngine.collectSkipKinds(["protect-alerts"], protectOnly: true), ["protect-alerts"])
    }

    /// Core inventory always runs: a typo or an over-eager list cannot remove it.
    func testUnknownAndCoreKindsAreIgnored() {
        let skipped = ReportEngine.collectSkipKinds(
            ["computers", "security", "overview", "not-a-kind", "", "update-status"])
        XCTAssertEqual(skipped, ["update-status"])
    }

    func testAnAbsentOrEmptyListSkipsNothing() {
        XCTAssertTrue(ReportEngine.collectSkipKinds(nil).isEmpty)
        XCTAssertTrue(ReportEngine.collectSkipKinds([]).isEmpty)
    }

    /// Every source the planners name is known here, so none escapes the switches.
    func testEverySourceIsKnown() {
        let named = Set(ReportEngine.knownCollectKinds)
            .union(ReportEngine.schoolCommandMatrix(profile: "").map(\.kind))
            .union(DataFreshnessHealth.protectKinds)
            .union(DataFreshnessHealth.securityCloudKinds)
            .union([ReportEngine.schoolDeviceDetailKind])
        XCTAssertEqual(ReportEngine.allSourceKinds, named)
    }

    func testTheListIsReadFromConfigYAML() throws {
        let config = try ConfigLoader.loadFromString(
            "jamf_cli:\n  collect_skip: [update_status, Profile-Status]\n")
        XCTAssertEqual(
            ReportEngine.collectSkipKinds(config.jamfCli?.collectSkip),
            ["update-status", "profile-status"]
        )
    }

    // MARK: - Freshness

    /// `collect` never runs a listed kind, so the health strip must not wait for it.
    func testFreshnessDoesNotExpectAListedKind() {
        let kinds = Set(WorkspaceStore.expectedKinds(
            skipExpensive: false, authMethod: "oauth2", collectSkip: ["update-status"]))
        XCTAssertFalse(kinds.contains("update-status"))
        XCTAssertTrue(kinds.contains("update-device-failures"), "only the listed kind drops")
        XCTAssertTrue(kinds.contains("computers"))
    }

    func testFreshnessWithNoListIsUnchanged() {
        XCTAssertEqual(
            WorkspaceStore.expectedKinds(skipExpensive: false, authMethod: "oauth2"),
            WorkspaceStore.expectedKinds(
                skipExpensive: false, authMethod: "oauth2", collectSkip: [])
        )
    }
}
