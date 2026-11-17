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

    /// The four per-device-heavy kinds, plus jamf-cli's dashboard (2.9), which sweeps
    /// the whole inventory again for a page only the HTML report uses, and the SOFA feed
    /// fetch, the one call to a third-party host, the Security Cloud device list (P12) and the Jamf
    /// School per-device scan.
    func testTheHeavyKindsTheDashboardAndSOFACanBeSkipped() {
        let all = ["patch-status", "patch-device-failures", "profile-status", "update-status",
                   "update-device-failures", "dashboard", "sofa", "security-risk",
                   "school-device-detail"]
        XCTAssertEqual(
            ReportEngine.collectSkipKinds(all), Set(all + ["patch-release-dates"]),
            "skipping patch-status also skips the release-date walk that reads it")
        XCTAssertEqual(
            ReportEngine.collectSkipKinds(["patch-status"]),
            ["patch-status", "patch-release-dates", "patch-device-failures"],
            "and the failures scan, which starts with the same request")
        XCTAssertFalse(
            ReportEngine.collectSkipKinds(["update-status"]).contains("patch-release-dates"))
        XCTAssertEqual(
            ReportEngine.sourcesAfterMatrix(
                tiers: [.refresh], collectSkip: ReportEngine.collectSkipKinds(["patch_status"])),
            ["sofa"])
        XCTAssertEqual(ReportEngine.skippableKinds, Set(all))
    }

    /// Core inventory always runs: a typo or an over-eager list cannot remove it.
    func testUnknownAndCoreKindsAreIgnored() {
        let skipped = ReportEngine.collectSkipKinds(
            ["computers", "security", "overview", "ea-results", "not-a-kind", "", "update-status"])
        XCTAssertEqual(skipped, ["update-status"])
    }

    func testAnAbsentOrEmptyListSkipsNothing() {
        XCTAssertTrue(ReportEngine.collectSkipKinds(nil).isEmpty)
        XCTAssertTrue(ReportEngine.collectSkipKinds([]).isEmpty)
    }

    func testEverySkippableKindIsACollectKind() {
        for kind in ReportEngine.skippableKinds {
            // Security Cloud follows the MDM collect and the School scan follows the School
            // collect, so neither kind is a Pro matrix kind.
            XCTAssertTrue(ReportEngine.knownCollectKinds.contains(kind)
                || DataFreshnessHealth.securityCloudKinds.contains(kind)
                || kind == ReportEngine.schoolDeviceDetailKind, kind)
        }
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
